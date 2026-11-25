// Copy this file and the two adjacent .cjs fixtures into account_sources/tests/;
// include as #[cfg(windows)] mod owned_adapter inside account_sources::tests.
// The only test constructor is the root-provided production BridgeTransport one.
use super::*;
use crate::desktop_auth::ManagedAccountProvider;
use crate::helper_host::TargetIdentity;
use crate::runtime_helper::{Phase, RuntimeOwner};
use std::{
    io::{BufRead, BufReader, Write},
    os::windows::{
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Stdio},
    sync::mpsc::{self, Receiver},
};
use windows::Win32::{
    Foundation::{FILETIME, HANDLE, WAIT_TIMEOUT},
    System::Threading::{
        GetProcessTimes, OpenProcess, WaitForSingleObject, PROCESS_QUERY_LIMITED_INFORMATION,
        PROCESS_SYNCHRONIZE,
    },
};

fn process_identity(pid: u32) -> (OwnedHandle, TargetIdentity) {
    unsafe {
        let handle = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            false,
            pid,
        )
        .expect("open only the just-spawned owned process");
        let owned = OwnedHandle::from_raw_handle(handle.0);
        let (mut created, mut exited, mut kernel, mut user) = (
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
        );
        GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user)
            .expect("owned creation FILETIME");
        (
            owned,
            TargetIdentity {
                pid,
                creation_file_time: (u64::from(created.dwHighDateTime) << 32)
                    | u64::from(created.dwLowDateTime),
            },
        )
    }
}

struct OwnedNode {
    process: Child,
    input: ChildStdin,
    receipts: Receiver<Value>,
    owner_handle: OwnedHandle,
    server_handle: OwnedHandle,
    owner_identity: TargetIdentity,
    server_identity: TargetIdentity,
    ticket: u64,
    finished: bool,
    _work: tempfile::TempDir,
}
impl OwnedNode {
    fn start() -> Self {
        let work = tempfile::tempdir().unwrap();
        fs::write(
            work.path().join("owned_adapter_parent.cjs"),
            include_str!("owned_adapter_parent.cjs"),
        )
        .unwrap();
        fs::write(
            work.path().join("owned_adapter_server.cjs"),
            include_str!("owned_adapter_server.cjs"),
        )
        .unwrap();
        let system = std::env::var_os("SystemRoot").unwrap_or_else(|| r"C:\Windows".into());
        // No CODEX/OPENAI/profile or Node preload environment is inherited.
        let profile = std::env::var_os("USERPROFILE").expect("Windows fixture user profile");
        let node = PathBuf::from(profile)
            .join(".cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe");
        let mut process = Command::new(node)
            .arg(work.path().join("owned_adapter_parent.cjs"))
            .env_clear()
            .env("SystemRoot", &system)
            .env("WINDIR", &system)
            .env("TEMP", work.path())
            .env("TMP", work.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(0x0800_0000)
            .spawn()
            .expect("Rust directly spawns its owned Node parent");
        let input = process.stdin.take().unwrap();
        let stdout = process.stdout.take().unwrap();
        let (send, receipts) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else {
                    break;
                };
                let value = serde_json::from_str::<Value>(&line)
                    .unwrap_or_else(|_| json!({"event":"invalid-receipt"}));
                if send.send(value).is_err() {
                    break;
                }
            }
        });
        let spawned = receipts
            .recv_timeout(Duration::from_secs(5))
            .expect("owned startup receipt");
        assert_eq!(spawned["event"], "spawned");
        assert_eq!(spawned["ownerPid"].as_u64(), Some(u64::from(process.id())));
        let child_pid = spawned["childPid"]
            .as_u64()
            .and_then(|pid| u32::try_from(pid).ok())
            .expect("owned child PID");
        let (owner_handle, owner_identity) = process_identity(process.id());
        let (server_handle, server_identity) = process_identity(child_pid);
        Self {
            process,
            input,
            receipts,
            owner_handle,
            server_handle,
            owner_identity,
            server_identity,
            ticket: 0,
            finished: false,
            _work: work,
        }
    }
    fn alive(&mut self) -> bool {
        self.process.try_wait().unwrap().is_none()
            && unsafe {
                WaitForSingleObject(HANDLE(self.owner_handle.as_raw_handle()), 0) == WAIT_TIMEOUT
            }
            && unsafe {
                WaitForSingleObject(HANDLE(self.server_handle.as_raw_handle()), 0) == WAIT_TIMEOUT
            }
    }
    fn command(&mut self, op: &str) -> Value {
        self.ticket += 1;
        serde_json::to_writer(&mut self.input, &json!({"op":op,"ticket":self.ticket})).unwrap();
        self.input.write_all(b"\n").unwrap();
        self.input.flush().unwrap();
        let receipt = self
            .receipts
            .recv_timeout(Duration::from_secs(5))
            .expect("owned hash/count receipt");
        assert_eq!(
            receipt["event"], "oracle",
            "fixture emits only sanitized oracle receipts"
        );
        assert_eq!(receipt["ticket"].as_u64(), Some(self.ticket));
        assert_eq!(
            receipt["hashEqual"].as_bool(),
            Some(true),
            "original reader equals the server's cumulative SHA256 oracle"
        );
        assert_eq!(receipt["allHashesEqual"].as_bool(), Some(true));
        assert_eq!(receipt["validSyntheticTokens"].as_bool(), Some(true));
        assert_eq!(receipt["modelRequests"].as_u64(), Some(0));
        receipt
    }
    fn finish(&mut self) {
        let _ = self.command("exit");
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(status) = self.process.try_wait().unwrap() {
                assert!(status.success());
                self.finished = true;
                break;
            }
            assert!(Instant::now() < deadline, "owned fixture did not exit");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for OwnedNode {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        // Cleanup owns only this test's Popen equivalent; RuntimeOwner has no kill API.
        let _ = self.input.write_all(b"{\"op\":\"exit\",\"ticket\":0}\n");
        let _ = self.input.flush();
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if self.process.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

fn managed(s: &Arc<Service>, principal: &str) -> (String, Arc<ManagedAccountProvider>) {
    let id = create(s);
    fs::write(s.root.join(&id).join(".synthetic-principal"), principal).unwrap();
    let lease = DesktopSourceLease {
        inner: s.lease_for(&id, Purpose::Desktop).unwrap(),
    };
    let provider = ManagedAccountProvider::from_lease(lease, Duration::from_secs(10)).unwrap();
    (id, provider)
}
fn pump_active(owner: &mut RuntimeOwner) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if owner.poll_once().unwrap().phase == Phase::Active {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "synthetic target identity was not confirmed"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn auth_refresh_reads(path: &Path) -> usize {
    fs::read_to_string(path.join(".desktop-rpc-receipt"))
        .unwrap_or_default()
        .lines()
        .filter(|line| *line == "auth:refresh")
        .count()
}

#[test]
#[ignore = "requires explicitly compiled owned bundle"]
fn owned_adapter_two_providers_scoped_refresh_quota_and_original_reader() {
    let bundle = PathBuf::from(
        std::env::var_os("CTZ_RUNTIME_OWNED_BUNDLE")
            .expect("CTZ_RUNTIME_OWNED_BUNDLE must explicitly select the compiled owned bundle"),
    );
    for file in [
        "codex_runtime_bridge.dll",
        "codex_desktop_observer.dll",
        "codex_runtime_metadata.exe",
    ] {
        assert!(
            bundle.join(file).is_file(),
            "explicit owned bundle is incomplete"
        );
    }
    let (_profiles, service) = service("desktop_auth");
    let (a, first) = managed(&service, "A");
    let (b, second) = managed(&service, "B");
    let mut node = OwnedNode::start();
    let baseline = node.command("baseline");
    assert_eq!(baseline["baseline"].as_u64(), Some(3));
    assert!(node.alive());
    let transport = crate::desktop_runtime_transport::connect_owned_for_test(
        &bundle,
        node.owner_identity,
        node.server_identity,
    )
    .expect("the production adapter must connect through OwnedProductionGate");
    assert_eq!(node.command("snapshot")["probes"].as_u64(), Some(2));
    let mut owner = RuntimeOwner::new(transport, 0x4f57_4e45_44);
    owner.begin_switch(first).unwrap();
    pump_active(&mut owner);
    let a_key = owner.active_source_key().unwrap();
    assert_eq!(a_key.1, a);
    assert_eq!(
        service.lease_for(&a, Purpose::Task).err().unwrap().kind,
        "busy"
    );

    node.command("hold-b");
    let old = node.command("late-a"); // captured before B's write watermark
    let reads_before_b = old["reads"].as_u64().unwrap();
    owner.begin_switch(second).unwrap();
    owner.poll_once().unwrap();
    assert_eq!(owner.status().phase, Phase::AwaitingConfirmation);
    assert!(owner.status().pending_source_retained);
    assert_eq!(
        node.command("snapshot")["reads"].as_u64(),
        Some(reads_before_b),
        "old A ack/update cannot request B's confirmation read"
    );
    assert_eq!(
        owner
            .read_quota_for_source(&a_key.0, &a_key.1, false)
            .err()
            .unwrap()
            .kind(),
        "busy"
    );
    assert_eq!(
        service.lease_for(&a, Purpose::Task).err().unwrap().kind,
        "busy"
    );
    assert_eq!(
        service.lease_for(&b, Purpose::Task).err().unwrap().kind,
        "busy"
    );

    node.command("release-login");
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        owner.poll_once().unwrap();
        if node.command("snapshot")["heldRead"].as_bool() == Some(true) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "B confirmation read was not issued"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    node.command("release-read");
    assert_eq!(
        owner
            .read_quota_for_source(&a_key.0, &a_key.1, false)
            .err()
            .unwrap()
            .kind(),
        "source_mismatch",
        "the queued B confirmation must not return B quota under A's source label"
    );
    let b_key = owner.active_source_key().unwrap();
    assert_eq!(b_key.1, b);
    assert!(service.lease_for(&a, Purpose::Task).is_ok());
    let quota = owner
        .read_quota_for_source(&b_key.0, &b_key.1, false)
        .unwrap();
    assert_eq!(quota["account"]["email"], "synthetic-B@example.invalid");
    assert_eq!(quota["limits"]["rateLimits"]["primary"]["usedPercent"], 20);

    let refresh_before = auth_refresh_reads(&service.root.join(&b));
    node.command("refresh-bad");
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        if let Err(error) = owner.poll_once() {
            assert_eq!(error.kind(), "source_mismatch");
            break;
        }
        assert!(
            Instant::now() < deadline,
            "wrong previousAccountId was not observed"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        auth_refresh_reads(&service.root.join(&b)),
        refresh_before,
        "foreign callback must not obtain a source token"
    );
    assert_eq!(
        node.command("snapshot")["badRefreshResponses"].as_u64(),
        Some(0)
    );
    node.command("refresh-good");
    let deadline = Instant::now() + Duration::from_secs(4);
    let final_oracle = loop {
        owner.poll_once().unwrap();
        let report = node.command("snapshot");
        if report["goodRefreshResponses"].as_u64() == Some(1) {
            break report;
        }
        assert!(
            Instant::now() < deadline,
            "correct scoped synthetic refresh was not delivered"
        );
        std::thread::sleep(Duration::from_millis(5));
    };
    assert_eq!(
        auth_refresh_reads(&service.root.join(&b)),
        refresh_before + 1
    );
    assert_eq!(final_oracle["logins"].as_u64(), Some(2));
    assert_eq!(final_oracle["lateAuthFrames"].as_u64(), Some(2));
    assert_eq!(final_oracle["badRefreshResponses"].as_u64(), Some(0));
    assert_eq!(final_oracle["activeIsB"].as_bool(), Some(true));
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        owner.poll_once().unwrap();
        let live = owner.live_snapshot();
        if live["items"].as_array().is_some_and(|rows| {
            rows.iter().any(|row| {
                row["threadId"] == "00000000-0000-7000-8000-000000000001"
                    && row["attention"] == "approval"
                    && row["state"] == "running"
            })
        }) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "preexisting waiting thread was not bootstrapped through the production adapter"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    owner.gui_detached();
    assert!(!owner.status().gui_attached && owner.status().active_source_retained);
    drop(owner);
    assert!(
        node.alive(),
        "dropping the production owner/transport must not kill either owned target process"
    );
    let after_drop = node.command("snapshot");
    assert_eq!(after_drop["hashEqual"].as_bool(), Some(true));
    assert!(after_drop["frames"].as_u64().unwrap() >= 13);
    node.finish();
}
