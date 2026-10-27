//! Host status recovery through the production pipe loop and isolated CLI.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

#[derive(Default)]
struct RecoveryControl {
    stop: AtomicBool,
    fail_transport: AtomicBool,
    events: Mutex<VecDeque<RuntimeEventKind>>,
    quota_events: Mutex<VecDeque<RuntimeEventKind>>,
    refreshes: AtomicUsize,
}
struct RecoveryFactory(Arc<RecoveryControl>);
impl RuntimeTransportFactory for RecoveryFactory {
    fn connect(
        &self,
        target: TargetIdentity,
    ) -> std::result::Result<Box<dyn RuntimeTransport>, HostError> {
        Ok(Box::new(RecoveryTransport {
            inner: OwnedFactory.connect(target)?,
            control: self.0.clone(),
            sequence: 0,
            top_level_poll: false,
        }))
    }
}
struct RecoveryTransport {
    inner: Box<dyn RuntimeTransport>,
    control: Arc<RecoveryControl>,
    sequence: u64,
    top_level_poll: bool,
}
impl RuntimeTransport for RecoveryTransport {
    fn write_login(
        &mut self,
        id: CorrelationId,
        token: &str,
        principal: &str,
        plan: Option<&str>,
        deadline: Instant,
    ) -> WriteReceipt {
        self.inner.write_login(id, token, principal, plan, deadline)
    }
    fn write_refresh_response(
        &mut self,
        id: &RefreshRequestId,
        token: &str,
        principal: &str,
        plan: Option<&str>,
        deadline: Instant,
    ) -> Delivery {
        let delivery = self
            .inner
            .write_refresh_response(id, token, principal, plan, deadline);
        if delivery == Delivery::Written {
            self.control.refreshes.fetch_add(1, Ordering::SeqCst);
        }
        delivery
    }
    fn request_account_read(
        &mut self,
        id: CorrelationId,
        deadline: Instant,
    ) -> std::result::Result<(), TransportError> {
        self.inner.request_account_read(id, deadline)
    }
    fn poll_event(&mut self) -> std::result::Result<Option<RuntimeEvent>, TransportError> {
        if self.control.fail_transport.load(Ordering::SeqCst) {
            return Err(TransportError::Unavailable);
        }
        // A callback can arrive between the regular poll and the quota drain.
        // poll_once visits poll_live first; quota_provider directly polls auth.
        let kind = if self.top_level_poll {
            self.top_level_poll = false;
            self.control.events.lock().unwrap().pop_front()
        } else {
            self.control.quota_events.lock().unwrap().pop_front()
        };
        let kind = match kind {
            Some(kind) => Some(kind),
            None => self.inner.poll_event()?.map(|event| event.kind),
        };
        Ok(kind.map(|kind| {
            self.sequence += 1;
            RuntimeEvent {
                sequence: self.sequence,
                kind,
            }
        }))
    }
    fn target_alive(&self) -> bool {
        !self.control.stop.load(Ordering::SeqCst) && self.inner.target_alive()
    }
    fn poll_live(
        &mut self,
    ) -> std::result::Result<(Option<crate::global_live::LiveEvent>, u32), TransportError> {
        self.top_level_poll = true;
        Ok((None, 0))
    }
}
struct RunningHost {
    control: Arc<RecoveryControl>,
    thread: Option<thread::JoinHandle<std::result::Result<(), HostError>>>,
}
impl Drop for RunningHost {
    fn drop(&mut self) {
        self.control.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
fn wait_status(config: &HostConfig, predicate: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Ok(reply) = control(config, 90, ControlAction::Status) {
            if predicate(&reply["data"]) {
                return reply["data"].clone();
            }
        }
        assert!(
            Instant::now() < deadline,
            "host status did not reach expected state"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn helper_host_clears_recovered_auth_error_without_hiding_unresolved_transport() {
    // A missing host recovery update must leave source_mismatch visible after
    // the later correctly scoped response; idle ticks alone cannot clear it.
    let (_root, service) = service("desktop_auth");
    let source = create(&service);
    let (_, created, _) = process_info(std::process::id()).unwrap();
    let config = HostConfig {
        target: TargetIdentity {
            pid: std::process::id(),
            creation_file_time: created,
        },
        control_label: source.trim_start_matches("profile-").to_owned(),
    };
    let recovery = Arc::new(RecoveryControl::default());
    let worker_control = recovery.clone();
    let worker_config = config.clone();
    let _host = RunningHost {
        control: recovery.clone(),
        thread: Some(thread::spawn(move || {
            helper_host::run_with_factory(worker_config, &RecoveryFactory(worker_control))
        })),
    };
    wait_status(&config, |_| true);
    let reply = control(
        &config,
        91,
        ControlAction::Switch {
            source_id: source.clone(),
            profiles_root: service.root.clone(),
        },
    )
    .unwrap();
    assert_eq!(reply["ok"], true);
    let active = wait_status(&config, |value| value["phase"] == "active");
    assert_eq!(active["sourceId"], source);
    assert!(active["errorKind"].is_null());

    recovery
        .events
        .lock()
        .unwrap()
        .push_back(RuntimeEventKind::RefreshRequested {
            id: RefreshRequestId::Number(4001),
            previous_account_id: Some("synthetic-account-B".into()),
        });
    let bad = wait_status(&config, |value| value["errorKind"] == "source_mismatch");
    assert_eq!(bad["phase"], "active");
    assert_eq!(recovery.refreshes.load(Ordering::SeqCst), 0);
    let idle = control(&config, 92, ControlAction::Status).unwrap();
    assert_eq!(
        idle["data"]["errorKind"], "source_mismatch",
        "an idle tick is not proof of recovery"
    );

    recovery
        .events
        .lock()
        .unwrap()
        .push_back(RuntimeEventKind::RefreshRequested {
            id: RefreshRequestId::Number(4002),
            previous_account_id: Some("synthetic-account-A".into()),
        });
    let deadline = Instant::now() + Duration::from_secs(10);
    while recovery.refreshes.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        recovery.refreshes.load(Ordering::SeqCst),
        1,
        "the real provider must deliver the correctly scoped renewal"
    );
    let recovered = control(&config, 93, ControlAction::Status).unwrap();
    assert_eq!(recovered["data"]["phase"], "active");
    assert!(
        recovered["data"]["errorKind"].is_null(),
        "a successful auth response must clear the recovered host error"
    );

    recovery
        .events
        .lock()
        .unwrap()
        .push_back(RuntimeEventKind::RefreshRequested {
            id: RefreshRequestId::Number(4003),
            previous_account_id: Some("synthetic-account-B".into()),
        });
    wait_status(&config, |value| value["errorKind"] == "source_mismatch");
    recovery
        .quota_events
        .lock()
        .unwrap()
        .push_back(RuntimeEventKind::RefreshRequested {
            id: RefreshRequestId::Number(4004),
            previous_account_id: Some("synthetic-account-A".into()),
        });
    let quota = control(
        &config,
        94,
        ControlAction::Quota {
            source_id: source.clone(),
            profiles_root: service.root.clone(),
            details: false,
        },
    )
    .unwrap();
    assert_eq!(quota["ok"], true);
    assert_eq!(recovery.refreshes.load(Ordering::SeqCst), 2);
    let recovered_in_quota = control(&config, 95, ControlAction::Status).unwrap();
    assert!(
        recovered_in_quota["data"]["errorKind"].is_null(),
        "auth recovery inside the quota drain must clear the old host error"
    );

    recovery.fail_transport.store(true, Ordering::SeqCst);
    let failed = wait_status(&config, |value| value["phase"] == "unresolved");
    assert_eq!(failed["errorKind"], "transport_unavailable");
    assert_eq!(failed["sourceId"], source);
    assert_eq!(failed["activeSourceRetained"], true);
}
