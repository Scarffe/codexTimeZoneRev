use super::*;
use crate::task_execution::{Binding, Outcome, Registry, Route, State as TaskState};
use crate::task_process::{
    fixture_executable, CleanupReceipt, FixtureLaunch, FixtureMode, ProcessError, ProcessIdentity,
    TaskProcess,
};

type Check<T> = std::result::Result<T, &'static str>;
const WAIT: Duration = Duration::from_secs(3);

// Fixture-only ownership adapter. No production FFI, auth, principal inference,
// official executable or user task is admitted by this test module.
struct OwnedFixtureTask {
    process: TaskProcess,
    identity: ProcessIdentity,
    lease: Option<Lease>,
    binding: Binding,
    route: Route,
}
impl OwnedFixtureTask {
    fn launch(
        s: &Arc<Service>,
        source: &str,
        workspace: &Path,
        task: &str,
        registry: &mut Registry,
        mode: FixtureMode,
    ) -> Check<Self> {
        let lease = task_lease(s, source).map_err(|_| "source")?;
        if fs::canonicalize(fixed_cli(&lease.metadata).map_err(|_| "component")?)
            .map_err(|_| "component")?
            != fs::canonicalize(fixture_executable()).map_err(|_| "component")?
        {
            return Err("component");
        }
        let workspace = fs::canonicalize(workspace).map_err(|_| "workspace")?;
        let binding = Binding::fixture(
            source,
            &format!("fixture-identity-{source}"),
            &workspace.to_string_lossy(),
            task,
            1,
            1,
        )
        .map_err(|_| "binding")?;
        registry
            .prepare(binding.clone())
            .map_err(|_| "reservation")?;
        let spawned = lease.task_start(|| {
            TaskProcess::spawn_fixture(
                FixtureLaunch {
                    home: lease.home.clone(),
                    workspace,
                    mode,
                },
                lease.cancel.clone(),
            )
        });
        let process = match spawned {
            Ok(Ok(process)) => process,
            Ok(Err(ProcessError::Cleanup)) => {
                // No cleanup authority: keep both prepared reservation and file
                // guard. Real adapters need a retry/reconciliation owner.
                std::mem::forget(lease);
                return Err("cleanup_unconfirmed");
            }
            error => {
                registry
                    .abort_prepared(&binding, Outcome::Failed)
                    .map_err(|_| "state")?;
                registry
                    .release_after_cleanup(&binding)
                    .map_err(|_| "state")?;
                return Err(if error.is_err() {
                    "start_denied"
                } else {
                    "startup"
                });
            }
        };
        let identity = process.identity();
        // Exclusive &mut Registry and globally unique prepared task ID make
        // these derived fixture thread/turn identifiers unambiguous.
        let route = registry
            .started(
                &binding,
                &format!("fixture-thread-{task}"),
                "fixture-turn-1",
            )
            .expect("new fixture task owns its derived thread");
        Ok(Self {
            process,
            identity,
            lease: Some(lease),
            binding,
            route,
        })
    }
    fn send(&mut self, value: Value) {
        self.process.send(value, WAIT).unwrap();
    }
    fn receive(&mut self) -> Value {
        self.process.receive(WAIT).unwrap()
    }
    fn frame(&self, method: &str) -> Value {
        json!({"method":method,"route":self.route,"requestId":"owned-request"})
    }
    fn apply(&self, registry: &mut Registry, value: &Value) -> Check<()> {
        if value["route"] != serde_json::to_value(&self.route).unwrap() {
            return Err("foreign_route");
        }
        match value["method"].as_str() {
            Some("fixture/approval") => registry
                .approval(&self.route, value["requestId"].as_str().ok_or("request")?)
                .map_err(|_| "approval"),
            Some("fixture/terminal") => {
                let outcome = match value["outcome"].as_str() {
                    Some("completed") => Outcome::Completed,
                    Some("cancelled") => Outcome::Cancelled,
                    Some("failed") => Outcome::Failed,
                    _ => return Err("outcome"),
                };
                registry
                    .terminal(&self.route, outcome)
                    .map_err(|_| "terminal")
            }
            _ => Err("unsupported"),
        }
    }
    fn confirm_cleanup(
        &mut self,
        registry: &mut Registry,
        receipt: Option<&CleanupReceipt>,
    ) -> Check<()> {
        if !receipt
            .is_some_and(|receipt| receipt.is_complete() && receipt.belongs_to(&self.identity))
        {
            return Err("cleanup_unconfirmed");
        }
        if self.lease.is_none() {
            return Ok(());
        }
        match registry.state(&self.binding).map_err(|_| "state")? {
            TaskState::Completed | TaskState::Cancelled | TaskState::Failed => registry
                .release_after_cleanup(&self.binding)
                .map_err(|_| "state")?,
            TaskState::Running | TaskState::AwaitingApproval | TaskState::Cancelling => {
                registry.disconnected(&self.route).map_err(|_| "state")?
            }
            TaskState::Recoverable => {}
            _ => return Err("state"),
        }
        // A confirmed dead local runtime can no longer write credentials.
        // Unknown remote outcome remains Recoverable, never Completed/resumed.
        drop(self.lease.take());
        Ok(())
    }
    fn cleanup(&mut self, registry: &mut Registry) {
        let receipt = self.process.shutdown(&self.identity, WAIT).unwrap();
        self.confirm_cleanup(registry, Some(&receipt)).unwrap();
    }
    fn terminal(&mut self, registry: &mut Registry, outcome: &str) {
        let mut frame = self.frame("fixture/terminal");
        frame["outcome"] = json!(outcome);
        self.send(frame);
        let value = self.receive();
        self.apply(registry, &value).unwrap();
    }
}
impl Drop for OwnedFixtureTask {
    fn drop(&mut self) {
        if let Some(lease) = self.lease.take() {
            if self
                .process
                .shutdown(&self.identity, WAIT)
                .is_ok_and(|receipt| receipt.is_complete() && receipt.belongs_to(&self.identity))
            {
                drop(lease);
            } else {
                // Unknown teardown must not open a second credential writer.
                // This intentionally retains reservation until host exit.
                std::mem::forget(lease);
            }
        }
    }
}

fn fixture_catalog() -> (tempfile::TempDir, Arc<Service>, PathBuf, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let a = root.path().join("workspace A 中文");
    let b = root.path().join("workspace B");
    fs::create_dir(&a).unwrap();
    fs::create_dir(&b).unwrap();
    let s = Service::for_test(
        root.path().join("account-profiles"),
        fixture_executable(),
        WAIT,
    );
    (root, s, a, b)
}

#[test]
fn two_processes_bind_real_profile_leases_and_reject_cross_source_events() {
    let (_root, s, wa, wb) = fixture_catalog();
    let (a, b) = (create(&s), create(&s));
    let mut registry = Registry::default();
    let mut ta =
        OwnedFixtureTask::launch(&s, &a, &wa, "task-a", &mut registry, FixtureMode::Normal)
            .unwrap();
    let mut tb =
        OwnedFixtureTask::launch(&s, &b, &wb, "task-b", &mut registry, FixtureMode::Normal)
            .unwrap();
    let (ra, rb) = (ta.receive(), tb.receive());
    assert_ne!(ta.identity.pid(), tb.identity.pid());
    assert_eq!(
        PathBuf::from(ra["home"].as_str().unwrap()),
        ta.lease.as_ref().unwrap().home
    );
    assert_eq!(
        PathBuf::from(ra["cwd"].as_str().unwrap()),
        fs::canonicalize(&wa).unwrap()
    );
    assert_ne!(ra["home"], rb["home"]);
    assert!(ra["provider_keys"].as_array().unwrap().is_empty());
    assert_eq!(ra["file_store"], true);
    assert_eq!(s.usage(&a).unwrap_err().kind, "busy");
    assert_eq!(s.login(&a).unwrap_err().kind, "busy");
    assert_eq!(s.remove(&a).unwrap_err().kind, "busy");
    let approval_a = ta.frame("fixture/approval");
    tb.send(approval_a);
    let foreign = tb.receive();
    assert_eq!(tb.apply(&mut registry, &foreign), Err("foreign_route"));
    assert_eq!(registry.state(&tb.binding), Ok(TaskState::Running));
    ta.send(ta.frame("fixture/approval"));
    let valid = ta.receive();
    ta.apply(&mut registry, &valid).unwrap();
    assert_eq!(registry.state(&ta.binding), Ok(TaskState::AwaitingApproval));
    assert!(ta.apply(&mut registry, &valid).is_err());
    registry.decision(&ta.route, "owned-request", true).unwrap();
    ta.terminal(&mut registry, "completed");
    assert_eq!(
        s.usage(&a).unwrap_err().kind,
        "busy",
        "terminal alone cannot release credentials"
    );
    ta.cleanup(&mut registry);
    let mut successor = OwnedFixtureTask::launch(
        &s,
        &a,
        &wa,
        "task-a-next",
        &mut registry,
        FixtureMode::Normal,
    )
    .unwrap();
    successor.receive();
    // An old repeat cleanup cannot erase a later source owner.
    ta.cleanup(&mut registry);
    assert_eq!(s.usage(&a).unwrap_err().kind, "busy");
    successor.terminal(&mut registry, "completed");
    successor.cleanup(&mut registry);
    tb.terminal(&mut registry, "completed");
    tb.cleanup(&mut registry);
}

#[test]
fn missing_or_foreign_cleanup_receipt_never_releases_live_profile() {
    let (_root, s, wa, wb) = fixture_catalog();
    let (a, b) = (create(&s), create(&s));
    let mut registry = Registry::default();
    let mut ta =
        OwnedFixtureTask::launch(&s, &a, &wa, "task-a", &mut registry, FixtureMode::Normal)
            .unwrap();
    let mut tb =
        OwnedFixtureTask::launch(&s, &b, &wb, "task-b", &mut registry, FixtureMode::Normal)
            .unwrap();
    ta.receive();
    tb.receive();
    assert_eq!(
        ta.confirm_cleanup(&mut registry, None),
        Err("cleanup_unconfirmed")
    );
    tb.terminal(&mut registry, "completed");
    let foreign = tb.process.shutdown(&tb.identity, WAIT).unwrap();
    assert_eq!(
        ta.confirm_cleanup(&mut registry, Some(&foreign)),
        Err("cleanup_unconfirmed")
    );
    assert_eq!(s.usage(&a).unwrap_err().kind, "busy");
    ta.send(json!({"method":"fixture/echo","value":"still-owned"}));
    assert_eq!(ta.receive()["value"], "still-owned");
    tb.confirm_cleanup(&mut registry, Some(&foreign)).unwrap();
    ta.terminal(&mut registry, "failed");
    ta.cleanup(&mut registry);
    assert!(task_lease(&s, &a).is_ok());
}

#[test]
fn cancel_then_terminal_keeps_writer_lock_until_actual_cleanup() {
    let (_root, s, wa, _) = fixture_catalog();
    let a = create(&s);
    let mut registry = Registry::default();
    let mut task = OwnedFixtureTask::launch(
        &s,
        &a,
        &wa,
        "cancel-task",
        &mut registry,
        FixtureMode::Normal,
    )
    .unwrap();
    task.receive();
    registry.cancel(&task.route).unwrap();
    assert_eq!(registry.state(&task.binding), Ok(TaskState::Cancelling));
    assert_eq!(s.remove(&a).unwrap_err().kind, "busy");
    task.terminal(&mut registry, "cancelled");
    assert_eq!(registry.state(&task.binding), Ok(TaskState::Cancelled));
    assert_eq!(s.usage(&a).unwrap_err().kind, "busy");
    task.cleanup(&mut registry);
    assert!(task_lease(&s, &a).is_ok());
}

#[test]
fn shutdown_cancels_owned_child_and_preserves_another_service_task() {
    let (_root, s, wa, wb) = fixture_catalog();
    let (a, b) = (create(&s), create(&s));
    let other = Service::for_test(s.root.clone(), fixture_executable(), WAIT);
    let mut registry = Registry::default();
    let mut ta =
        OwnedFixtureTask::launch(&s, &a, &wa, "task-a", &mut registry, FixtureMode::Normal)
            .unwrap();
    ta.receive();
    let mut tb = OwnedFixtureTask::launch(
        &other,
        &b,
        &wb,
        "task-b",
        &mut registry,
        FixtureMode::Normal,
    )
    .unwrap();
    tb.receive();
    let stop_service = s.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    let stop = thread::spawn(move || tx.send(stop_service.shutdown()).unwrap());
    let deadline = Instant::now() + WAIT;
    while !ta.lease.as_ref().unwrap().cancel.load(Ordering::SeqCst) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let process_result = ta.process.receive(Duration::from_millis(100));
    let waiting = matches!(rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty));
    let blocked = other.lease(&a).is_err();
    ta.cleanup(&mut registry);
    let result = rx.recv_timeout(WAIT).unwrap();
    stop.join().unwrap();
    assert_eq!(process_result, Err(ProcessError::Cancelled));
    assert!(waiting && blocked);
    assert!(result.is_ok());
    assert_eq!(
        registry.state(&ta.binding),
        Ok(TaskState::Recoverable),
        "shutdown without terminal cannot claim completion"
    );
    tb.send(json!({"method":"fixture/echo","value":"independent"}));
    assert_eq!(tb.receive()["value"], "independent");
    tb.terminal(&mut registry, "completed");
    tb.cleanup(&mut registry);
}

#[test]
fn failed_start_and_conflicting_workspace_leave_no_live_writer() {
    let (_root, s, wa, wb) = fixture_catalog();
    let (a, b) = (create(&s), create(&s));
    let mut registry = Registry::default();
    assert_eq!(
        OwnedFixtureTask::launch(
            &s,
            &a,
            &wa,
            "failed",
            &mut registry,
            FixtureMode::StartupError
        )
        .err(),
        Some("startup")
    );
    assert!(task_lease(&s, &a).is_ok());
    let mut active =
        OwnedFixtureTask::launch(&s, &a, &wa, "active", &mut registry, FixtureMode::Normal)
            .unwrap();
    active.receive();
    assert_eq!(
        OwnedFixtureTask::launch(&s, &b, &wa, "conflict", &mut registry, FixtureMode::Normal).err(),
        Some("reservation")
    );
    assert!(task_lease(&s, &b).is_ok());
    let mut next =
        OwnedFixtureTask::launch(&s, &b, &wb, "next", &mut registry, FixtureMode::Normal).unwrap();
    next.receive();
    active.terminal(&mut registry, "completed");
    active.cleanup(&mut registry);
    next.terminal(&mut registry, "completed");
    next.cleanup(&mut registry);
}
