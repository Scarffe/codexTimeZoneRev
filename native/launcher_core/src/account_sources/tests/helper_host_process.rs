//! Owned executable acceptance for the same host loop; no real Desktop adapter.
use super::*;
use crate::helper_control::{self, ControlAction, ControlRequest};
use crate::helper_host::{self, HostConfig, HostError, RuntimeTransportFactory, TargetIdentity};
use crate::runtime_helper::*;
use std::{
    collections::VecDeque,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
    process::{Child, Stdio},
};
use windows::Win32::{
    Foundation::{FILETIME, HANDLE, WAIT_TIMEOUT},
    System::Threading::*,
};

fn process_info(pid: u32) -> std::result::Result<(OwnedHandle, u64, PathBuf), HostError> {
    unsafe {
        let raw = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            false,
            pid,
        )
        .map_err(|_| HostError::InvalidTarget)?;
        let handle = OwnedHandle::from_raw_handle(raw.0);
        let (mut creation, mut exit, mut kernel, mut user) = (
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
        );
        GetProcessTimes(raw, &mut creation, &mut exit, &mut kernel, &mut user)
            .map_err(|_| HostError::InvalidTarget)?;
        let created =
            (u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime);
        let mut image = vec![0u16; 32768];
        let mut length = image.len() as u32;
        QueryFullProcessImageNameW(
            raw,
            PROCESS_NAME_FORMAT(0),
            windows::core::PWSTR(image.as_mut_ptr()),
            &mut length,
        )
        .map_err(|_| HostError::InvalidTarget)?;
        let image = PathBuf::from(
            String::from_utf16(&image[..length as usize]).map_err(|_| HostError::InvalidTarget)?,
        );
        Ok((handle, created, image))
    }
}

struct OwnedFactory;
impl RuntimeTransportFactory for OwnedFactory {
    fn connect(
        &self,
        target: TargetIdentity,
    ) -> std::result::Result<Box<dyn RuntimeTransport>, HostError> {
        let (handle, created, image) = process_info(target.pid)?;
        let executable = std::env::current_exe().map_err(|_| HostError::InvalidTarget)?;
        if created != target.creation_file_time
            || fs::canonicalize(image).ok() != fs::canonicalize(executable).ok()
        {
            return Err(HostError::InvalidTarget);
        }
        Ok(Box::new(OwnedTransport {
            target: handle,
            sequence: 0,
            events: VecDeque::new(),
            identity: None,
            stop_receipt: std::env::var_os("CTZ_OWNED_TRANSPORT_STOPPED").map(PathBuf::from),
        }))
    }
}
struct OwnedTransport {
    target: OwnedHandle,
    sequence: u64,
    events: VecDeque<RuntimeEvent>,
    identity: Option<ObservedIdentity>,
    stop_receipt: Option<PathBuf>,
}
impl Drop for OwnedTransport {
    fn drop(&mut self) {
        if let Some(path) = &self.stop_receipt {
            fs::write(path, b"synthetic transport dropped normally").unwrap();
        }
    }
}
impl OwnedTransport {
    fn push(&mut self, kind: RuntimeEventKind) {
        self.sequence += 1;
        self.events.push_back(RuntimeEvent {
            sequence: self.sequence,
            kind,
        });
    }
}
impl RuntimeTransport for OwnedTransport {
    fn write_login(
        &mut self,
        id: CorrelationId,
        token: &str,
        principal: &str,
        plan: Option<&str>,
        _: Instant,
    ) -> WriteReceipt {
        let before = self.sequence;
        let Some(marker) = principal
            .strip_prefix("synthetic-account-")
            .filter(|marker| ["A", "B"].contains(marker))
        else {
            return WriteReceipt {
                delivery: Delivery::NotWritten,
                observed_through: before,
            };
        };
        assert!(token.ends_with(&format!(".synthetic-signature-{marker}")));
        self.identity = Some(ObservedIdentity {
            auth: AuthFamily::ChatGpt,
            email: Some(format!("synthetic-{marker}@example.invalid")),
            plan_type: plan.map(str::to_owned),
            account_id: None,
        });
        self.push(RuntimeEventKind::LoginAcknowledged { id, accepted: true });
        self.push(RuntimeEventKind::AccountUpdated {
            auth: AuthFamily::ChatGptAuthTokens,
        });
        WriteReceipt {
            delivery: Delivery::Written,
            observed_through: before,
        }
    }
    fn write_refresh_response(
        &mut self,
        _: &RefreshRequestId,
        token: &str,
        principal: &str,
        _: Option<&str>,
        _: Instant,
    ) -> Delivery {
        let marker = principal
            .strip_prefix("synthetic-account-")
            .unwrap_or("INVALID");
        assert!(token.ends_with(&format!(".synthetic-refreshed-{marker}")));
        Delivery::Written
    }
    fn request_account_read(
        &mut self,
        id: CorrelationId,
        _: Instant,
    ) -> std::result::Result<(), TransportError> {
        let identity = self.identity.clone().ok_or(TransportError::Unavailable)?;
        self.push(RuntimeEventKind::AccountRead { id, identity });
        Ok(())
    }
    fn poll_event(&mut self) -> std::result::Result<Option<RuntimeEvent>, TransportError> {
        Ok(self.events.pop_front())
    }
    fn target_alive(&self) -> bool {
        unsafe { WaitForSingleObject(HANDLE(self.target.as_raw_handle()), 0) == WAIT_TIMEOUT }
    }
}

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn entry(name: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", name, "--nocapture"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

#[test]
fn owned_helper_entry() {
    let Ok(raw) = std::env::var("CTZ_OWNED_HELPER_CONFIG") else {
        return;
    };
    let config: HostConfig = serde_json::from_str(&raw).unwrap();
    let result = helper_host::run_with_factory(config, &OwnedFactory);
    assert!(
        result.is_ok(),
        "owned helper stopped with a fixed host error"
    );
}

#[test]
fn owned_target_entry() {
    let Some(ready) = std::env::var_os("CTZ_OWNED_TARGET_READY") else {
        return;
    };
    let stop = PathBuf::from(std::env::var_os("CTZ_OWNED_TARGET_STOP").unwrap());
    fs::write(ready, b"synthetic target ready").unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    while !stop.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
}

fn control(
    config: &HostConfig,
    id: u64,
    action: ControlAction,
) -> std::result::Result<Value, HostError> {
    let budget = if matches!(&action, ControlAction::Quota { .. }) {
        Duration::from_secs(13)
    } else {
        Duration::from_secs(2)
    };
    helper_control::request(
        config,
        ControlRequest {
            version: 1,
            request_id: id,
            action,
        },
        Instant::now() + budget,
    )
}

#[test]
fn helper_host_process_lifetime_survives_client_disconnect_and_cleans_after_target_exit() {
    let (root, service) = service("desktop_auth");
    let source = create(&service);
    let ready = root.path().join("owned-target-ready");
    let stop = root.path().join("owned-target-stop");
    let mut target = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_target_entry")
            .env("CTZ_OWNED_TARGET_READY", &ready)
            .env("CTZ_OWNED_TARGET_STOP", &stop)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(ready.exists());
    let (_, created, _) = process_info(target.0.id()).unwrap();
    let config = HostConfig {
        target: TargetIdentity {
            pid: target.0.id(),
            creation_file_time: created,
        },
        control_label: source.trim_start_matches("profile-").to_owned(),
    };
    let mut helper = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_helper_entry")
            .env(
                "CTZ_OWNED_HELPER_CONFIG",
                serde_json::to_string(&config).unwrap(),
            )
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut available = false;
    while Instant::now() < deadline {
        if control(&config, 1, ControlAction::Status).is_ok() {
            available = true;
            break;
        }
        if helper.0.try_wait().unwrap().is_some() {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        available,
        "owned helper never accepted its local control request"
    );
    let reply = control(
        &config,
        2,
        ControlAction::Switch {
            source_id: source.clone(),
            profiles_root: service.root.clone(),
        },
    )
    .unwrap();
    assert_eq!(reply["ok"], true);
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut active = false;
    while Instant::now() < deadline {
        let reply = control(&config, 3, ControlAction::Status).unwrap();
        if reply["data"]["phase"] == "active" {
            active = true;
            break;
        }
        assert!(helper.0.try_wait().unwrap().is_none());
        thread::sleep(Duration::from_millis(50));
    }
    assert!(
        active,
        "background source preparation never reached confirmed active state"
    );
    let active_status = control(&config, 4, ControlAction::Status).unwrap();
    assert_eq!(active_status["data"]["sourceId"], source);
    let active_root = PathBuf::from(active_status["data"]["profilesRoot"].as_str().unwrap());
    let mismatch = control(
        &config,
        5,
        ControlAction::Quota {
            source_id: "profile-0000000000000000".into(),
            profiles_root: active_root.clone(),
            details: false,
        },
    )
    .unwrap();
    assert_eq!(mismatch["error"]["kind"], "source_mismatch");
    let mismatch = control(
        &config,
        6,
        ControlAction::Quota {
            source_id: source.clone(),
            profiles_root: root.path().join("different-profiles-root"),
            details: false,
        },
    )
    .unwrap();
    assert_eq!(mismatch["error"]["kind"], "source_mismatch");
    fs::write(
        service.root.join(&source).join(".synthetic-quota-delay-ms"),
        "2200",
    )
    .unwrap();
    let quota_started = Instant::now();
    let quota = control(
        &config,
        7,
        ControlAction::Quota {
            source_id: source.clone(),
            profiles_root: active_root,
            details: false,
        },
    )
    .unwrap();
    assert!(quota_started.elapsed() >= Duration::from_secs(2));
    assert_eq!(quota["ok"], true);
    assert_eq!(quota["data"]["sourceId"], source);
    assert_eq!(
        quota["data"]["usage"]["limits"]["rateLimits"]["primary"]["usedPercent"],
        20
    );
    let rejected_stop = control(&config, 8, ControlAction::StopUnowned).unwrap();
    assert_eq!(rejected_stop["error"]["kind"], "owner_busy");
    assert!(helper.0.try_wait().unwrap().is_none());
    // Each request owns and closes its pipe connection. No client connection
    // remains here; the helper process and source reservation must remain alive.
    thread::sleep(Duration::from_millis(250));
    assert!(helper.0.try_wait().unwrap().is_none());
    assert_eq!(
        service
            .lease_for(&source, Purpose::Task)
            .err()
            .unwrap()
            .kind,
        "busy"
    );
    let cli_pid = fs::read_to_string(service.root.join(&source).join(".desktop-child-pid"))
        .unwrap()
        .parse::<u32>()
        .unwrap();
    let (cli_handle, _, _) = process_info(cli_pid).unwrap();
    assert_eq!(
        unsafe { WaitForSingleObject(HANDLE(cli_handle.as_raw_handle()), 0) },
        WAIT_TIMEOUT
    );

    fs::write(stop, b"synthetic target exit").unwrap();
    assert!(target.0.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut exited = false;
    while Instant::now() < deadline {
        if let Some(status) = helper.0.try_wait().unwrap() {
            assert!(status.success());
            exited = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        exited,
        "helper did not end after its exact owned target exited"
    );
    assert_ne!(
        unsafe { WaitForSingleObject(HANDLE(cli_handle.as_raw_handle()), 0) },
        WAIT_TIMEOUT
    );
    assert!(service.lease_for(&source, Purpose::Task).is_ok());
}

#[test]
fn helper_host_process_stop_unowned_keeps_target_alive_and_drops_transport() {
    let root = tempfile::tempdir().unwrap();
    let ready = root.path().join("owned-target-ready");
    let stop = root.path().join("owned-target-stop");
    let transport_stopped = root.path().join("owned-transport-stopped");
    let mut target = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_target_entry")
            .env("CTZ_OWNED_TARGET_READY", &ready)
            .env("CTZ_OWNED_TARGET_STOP", &stop)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(ready.exists());
    let (_, created, _) = process_info(target.0.id()).unwrap();
    let config = HostConfig {
        target: TargetIdentity {
            pid: target.0.id(),
            creation_file_time: created,
        },
        control_label: "53544f50554e4f574e4544303031".into(),
    };
    let mut helper = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_helper_entry")
            .env(
                "CTZ_OWNED_HELPER_CONFIG",
                serde_json::to_string(&config).unwrap(),
            )
            .env("CTZ_OWNED_TRANSPORT_STOPPED", &transport_stopped)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut available = false;
    while Instant::now() < deadline {
        if control(&config, 1, ControlAction::Status).is_ok() {
            available = true;
            break;
        }
        if helper.0.try_wait().unwrap().is_some() {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(available);
    let reconcile = control(&config, 9, ControlAction::Reconcile).unwrap();
    assert_eq!(reconcile["error"]["kind"], "delivery_unresolved");
    let reply = control(&config, 2, ControlAction::StopUnowned).unwrap();
    assert_eq!(
        reply["ok"], true,
        "a helper with no owned source must stop normally"
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut exited = false;
    while Instant::now() < deadline {
        if let Some(status) = helper.0.try_wait().unwrap() {
            assert!(status.success());
            exited = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(exited, "unowned helper did not finish normally");
    assert!(
        transport_stopped.exists(),
        "normal transport Drop must run rather than process termination"
    );
    assert!(
        target.0.try_wait().unwrap().is_none(),
        "StopUnowned must leave the exact target running"
    );
    fs::write(stop, b"synthetic target exit").unwrap();
    assert!(target.0.wait().unwrap().success());
}

mod runtime_client_cases;
mod recovery_cases;
