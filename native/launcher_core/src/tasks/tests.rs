use super::*;
fn identity(snapshot: &Value) -> Value {
    json!({"taskId":snapshot["taskId"],"sourceEpoch":snapshot["sourceEpoch"],"generation":snapshot["generation"]})
}
fn prepare(manager: &Arc<Manager>, source: &str, workspace: &str, sandbox: &str) -> Value {
    manager.execute("task_prepare",json!({"mode":"offline_preview","sourceId":source,"workspace":workspace,"prompt":"Synthetic prompt in memory","model":"preview-model","sandbox":sandbox})).unwrap()
}
fn wait(manager: &Arc<Manager>, id: &Value, wanted: &[&str]) -> Value {
    let end = Instant::now() + Duration::from_secs(20);
    loop {
        let snapshot = manager.execute("task_status", id.clone()).unwrap();
        if wanted.iter().any(|state| snapshot["state"] == *state)
            && snapshot["cleanupPending"] == false
        {
            return snapshot;
        }
        assert!(Instant::now() < end, "{snapshot}");
        thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn production_manager_preview_is_two_source_owned_and_readonly_overlaps_are_allowed() {
    let manager = Manager::new();
    let a = prepare(&manager, "preview-a", "synthetic/workspace", "read-only");
    let b = prepare(&manager, "preview-b", "synthetic/workspace", "read-only");
    manager.execute("task_start", identity(&a)).unwrap();
    manager.execute("task_start", identity(&b)).unwrap();
    let done = wait(&manager, &identity(&a), &["completed"]);
    assert!(done["output"]
        .as_str()
        .unwrap()
        .starts_with("Synthetic preview only"));
    assert!(done["observedIdentity"].is_null());
    assert_eq!(done["strongPrincipalVerified"], false);
    wait(&manager, &identity(&b), &["completed"]);
    let write = prepare(
        &manager,
        "preview-a",
        "synthetic/workspace",
        "workspace-write",
    );
    let overlapping = prepare(
        &manager,
        "preview-b",
        "synthetic/workspace/nested",
        "read-only",
    );
    manager.execute("task_start", identity(&write)).unwrap();
    assert_eq!(
        manager
            .execute("task_start", identity(&overlapping))
            .unwrap_err(),
        "workspace_busy"
    );
    manager.execute("task_cancel", identity(&write)).unwrap();
    wait(&manager, &identity(&write), &["cancelled"]);
    let stale = json!({"taskId":a["taskId"],"sourceEpoch":a["sourceEpoch"],"generation":9999});
    assert_eq!(
        manager.execute("task_cancel", stale).unwrap_err(),
        "invalid_request"
    );
    assert_eq!(
        manager.execute("task_shutdown", json!({})).unwrap()["cleanupComplete"],
        true
    );
    assert_eq!(
        manager
            .execute("task_start", identity(&overlapping))
            .unwrap_err(),
        "shutdown"
    );
}
#[test]
fn protocol_rejects_duplicate_keys_and_keeps_numeric_string_request_ids_distinct() {
    assert!(task_protocol::parse(br#"{"id":1,"result":{},"result":{}}"#).is_err());
    assert!(task_protocol::parse(br#"{"id":1,"result":{"x":1,"X":2}}"#).is_err());
    assert_ne!(json!(1).to_string(), json!("1").to_string());
}
#[cfg(windows)]
fn fixture() -> PathBuf {
    use std::sync::OnceLock;
    struct Binary {
        _root: tempfile::TempDir,
        path: PathBuf,
    }
    static BINARY: OnceLock<Binary> = OnceLock::new();
    BINARY
        .get_or_init(|| {
            let root = tempfile::tempdir().unwrap();
            let executable = root.path().join("official_task_fixture.exe");
            let compiler = std::env::var_os("RUSTC")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute() && path.is_file())
                .or_else(|| {
                    std::env::var_os("PATH")
                        .into_iter()
                        .flat_map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
                        .filter(|path| path.is_absolute())
                        .map(|path| path.join("rustc.exe"))
                        .find(|path| path.is_file())
                })
                .expect("existing trusted Rust compiler");
            let mut child = std::process::Command::new(compiler)
                .args(["--edition=2021", "-C", "opt-level=0"])
                .arg(
                    Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join("tests/fixtures/official_task_cli.rs"),
                )
                .arg("-o")
                .arg(&executable)
                .stdin(std::process::Stdio::null())
                .spawn()
                .unwrap();
            let end = Instant::now() + Duration::from_secs(60);
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    assert!(status.success());
                    break;
                }
                if Instant::now() >= end {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("fixture compiler timeout")
                }
                thread::sleep(Duration::from_millis(10));
            }
            Binary {
                _root: root,
                path: executable,
            }
        })
        .path
        .clone()
}
#[cfg(windows)]
fn official(mode: &str) -> (tempfile::TempDir, Arc<Manager>, Value) {
    let root = tempfile::tempdir().unwrap();
    let workspace = root.path().join("workspace");
    std::fs::create_dir(&workspace).unwrap();
    let cli = root.path().join(format!("{mode}.exe"));
    std::fs::copy(fixture(), &cli).unwrap();
    let source = account_sources::task_fixture_source(root.path().join("account-profiles"), cli);
    let manager = Arc::new(Manager {
        state: Mutex::new(State {
            accepting: true,
            tasks: HashMap::new(),
        }),
        next: AtomicU64::new(1),
        nonce: 1,
        source_factory: Some(source.acquire),
    });
    let draft=manager.execute("task_prepare",json!({"mode":"official","sourceId":source.id,"workspace":workspace,"prompt":"Synthetic fake CLI only","model":"fixture-model","sandbox":"read-only"})).unwrap();
    (root, manager, identity(&draft))
}
#[cfg(windows)]
fn await_state(manager: &Arc<Manager>, id: &Value, state: &str) -> Value {
    let end = Instant::now() + Duration::from_secs(20);
    loop {
        let view = manager.execute("task_status", id.clone()).unwrap();
        if view["state"] == state {
            return view;
        }
        assert!(
            !["failed", "interrupted"]
                .iter()
                .any(|state| view["state"] == *state),
            "{view}"
        );
        assert!(Instant::now() < end, "{view}");
        thread::sleep(Duration::from_millis(5));
    }
}
#[cfg(windows)]
#[test]
fn actual_owned_fake_cli_uses_production_handshake_turns_final_items_and_cleanup() {
    for mode in ["complete", "final_only"] {
        let (_root, manager, id) = official(mode);
        manager.execute("task_start", id.clone()).unwrap();
        let view = wait(&manager, &id, &["completed", "failed", "interrupted"]);
        assert_eq!(view["state"], "completed", "{view}");
        assert_eq!(view["output"], "Synthetic output");
        assert_eq!(view["observedIdentity"]["kind"], "chatgpt");
        assert_eq!(view["strongPrincipalVerified"], false);
        assert_eq!(view["cleanupPending"], false);
    }
}
#[cfg(windows)]
#[test]
fn actual_fake_cli_preflight_routes_fail_closed_and_do_not_claim_completion() {
    for (mode, error) in [
        ("wrong_home", "isolation_failed"),
        ("missing_store", "isolation_failed"),
        ("logged_out", "auth_required"),
        ("malformed", "protocol_error"),
        ("foreign_route", "protocol_error"),
        ("crash", "disconnected"),
        ("duplicate_approval", "protocol_error"),
        ("oversized", "protocol_error"),
        ("invalid_utf8", "protocol_error"),
        ("flood", "protocol_error"),
        ("write_stdin", "unsupported_request"),
    ] {
        let (_root, manager, id) = official(mode);
        manager.execute("task_start", id.clone()).unwrap();
        let view = wait(&manager, &id, &["failed", "interrupted"]);
        assert_eq!(view["errorKind"], error, "mode={mode}, {view}");
        assert_eq!(view["cleanupPending"], false);
        assert!(!view.to_string().contains("Synthetic fake CLI only"));
    }
}

#[cfg(windows)]
#[test]
fn actual_owned_child_bounds_blocked_stdin_and_releases_only_after_cleanup() {
    let root = tempfile::tempdir().unwrap();
    let workspace = root.path().join("workspace");
    std::fs::create_dir(&workspace).unwrap();
    let cli = root.path().join("block_input.exe");
    std::fs::copy(fixture(), &cli).unwrap();
    let source = account_sources::task_fixture_source(root.path().join("profiles"), cli);
    let lease = (source.acquire)(&source.id).unwrap();
    let mut child = match lease.launch(&workspace) {
        Ok(child) => child,
        Err(error) => panic!("bounded local launch failed: {}", error.kind),
    };
    assert_eq!(
        child.send(
            vec![b'x'; crate::owned_stdio::FRAME_LIMIT],
            Duration::from_millis(100)
        ),
        Err("timeout")
    );
    assert_eq!((source.remove)().unwrap_err(), "busy");
    assert!(child.cleanup(Duration::from_secs(3)));
    assert!(child.cleanup(Duration::from_millis(10)));
    assert_eq!((source.remove)().unwrap_err(), "busy");
    drop(lease);
    assert_eq!((source.remove)().unwrap()["removed"], true);
}

#[cfg(windows)]
#[test]
fn actual_fake_cli_lost_turn_start_response_is_not_retried_or_resumed() {
    let (root, manager, id) = official("lost_start");
    manager.execute("task_start", id.clone()).unwrap();
    let view = wait(&manager, &id, &["failed"]);
    assert_eq!(view["errorKind"], "timeout");
    assert_eq!(view["cleanupPending"], false);
    let home = root
        .path()
        .join("account-profiles")
        .join(view["sourceId"].as_str().unwrap());
    let count = std::fs::read_to_string(home.join("turn-start-count.txt")).unwrap();
    assert_eq!(count.lines().count(), 1);
}

#[cfg(windows)]
#[test]
fn actual_fake_cli_restricted_approval_rejects_accept_before_consuming_request() {
    let (_root, manager, id) = official("restricted_decisions");
    manager.execute("task_start", id.clone()).unwrap();
    let view = await_state(&manager, &id, "awaiting_approval");
    let request = &view["approvals"][0];
    assert_eq!(request["decisions"], json!(["decline", "cancel"]));
    let mut action = id.clone();
    action["approvalId"] = request["approvalId"].clone();
    action["decision"] = json!("accept");
    assert_eq!(
        manager
            .execute("task_approval", action.clone())
            .unwrap_err(),
        "invalid_request"
    );
    let remaining = manager.execute("task_status", id.clone()).unwrap();
    assert_eq!(remaining["approvals"].as_array().unwrap().len(), 1);
    action["decision"] = json!("decline");
    manager.execute("task_approval", action).unwrap();
    assert_eq!(
        wait(&manager, &id, &["completed", "failed"])["state"],
        "completed"
    );
}

#[test]
fn approval_choices_follow_optional_legacy_and_present_restricted_semantics() {
    assert_eq!(
        supported_decisions(&json!({}), "command").unwrap(),
        vec!["accept", "decline", "cancel"]
    );
    assert_eq!(
        supported_decisions(&json!({"availableDecisions":null}), "command").unwrap(),
        vec!["accept", "decline", "cancel"]
    );
    assert_eq!(supported_decisions(&json!({"kind":"command","availableDecisions":["cancel","acceptForSession","decline","cancel",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["synthetic"]}}]}),"command").unwrap(),vec!["cancel","decline"]);
    assert_eq!(
        supported_decisions(
            &json!({"availableDecisions":["acceptForSession"]}),
            "command"
        ),
        Err("unsupported_request")
    );
    assert_eq!(
        supported_decisions(&json!({"availableDecisions":[]}), "command"),
        Err("unsupported_request")
    );
    assert_eq!(
        supported_decisions(&json!({"kind":"writeStdin"}), "command"),
        Err("unsupported_request")
    );
}
#[cfg(windows)]
#[test]
fn actual_fake_cli_approval_ids_are_exactly_once_and_structured_input_is_routed() {
    let (_root, manager, id) = official("approval");
    manager.execute("task_start", id.clone()).unwrap();
    let end = Instant::now() + Duration::from_secs(20);
    let approvals = loop {
        let view = manager.execute("task_status", id.clone()).unwrap();
        if view["approvals"].as_array().unwrap().len() == 2 {
            break view["approvals"].as_array().unwrap().clone();
        }
        assert!(Instant::now() < end, "{view}");
        thread::sleep(Duration::from_millis(5));
    };
    assert_ne!(approvals[0]["approvalId"], approvals[1]["approvalId"]);
    let file = approvals
        .iter()
        .find(|request| request["kind"] == "file")
        .unwrap();
    assert_eq!(file["files"], json!(["synthetic.txt"]));
    assert!(file["summary"].as_str().unwrap().contains("+new synthetic"));
    for request in approvals {
        let mut action = id.clone();
        action["approvalId"] = request["approvalId"].clone();
        action["decision"] = json!("accept");
        manager.execute("task_approval", action.clone()).unwrap();
        assert_eq!(
            manager.execute("task_approval", action).unwrap_err(),
            "invalid_request"
        );
    }
    assert_eq!(
        wait(&manager, &id, &["completed", "failed"])["state"],
        "completed"
    );
    let (_root, manager, id) = official("input");
    manager.execute("task_start", id.clone()).unwrap();
    let view = await_state(&manager, &id, "awaiting_input");
    let mut action = id.clone();
    action["requestId"] = view["inputRequests"][0]["requestId"].clone();
    action["answers"] = json!({"choice":{"answers":["A"]}});
    manager.execute("task_input", action.clone()).unwrap();
    assert!(manager.execute("task_input", action).is_err());
    assert_eq!(
        wait(&manager, &id, &["completed", "failed"])["state"],
        "completed"
    );
}
#[cfg(windows)]
#[test]
fn actual_fake_cli_cancel_and_shutdown_confirm_process_job_and_io_cleanup() {
    for mode in ["cancel", "descendant"] {
        let (root, manager, id) = official(mode);
        manager.execute("task_start", id.clone()).unwrap();
        await_state(&manager, &id, "running");
        manager.execute("task_cancel", id.clone()).unwrap();
        let view = wait(&manager, &id, &["cancelled", "failed"]);
        assert_eq!(view["state"], "cancelled", "{view}");
        assert_eq!(view["cleanupPending"], false);
        if mode == "descendant" {
            assert!(root
                .path()
                .join("account-profiles")
                .join(view["sourceId"].as_str().unwrap())
                .join("descendant.pid")
                .is_file());
        }
    }
    let (_root, manager, id) = official("silent");
    manager.execute("task_start", id.clone()).unwrap();
    await_state(&manager, &id, "running");
    assert_eq!(
        manager.execute("task_shutdown", json!({})).unwrap()["cleanupComplete"],
        true
    );
    assert_eq!(
        manager.execute("task_status", id).unwrap()["cleanupPending"],
        false
    );
}

#[cfg(windows)]
#[test]
fn actual_fake_cli_holds_existing_source_lease_until_job_cleanup() {
    let root = tempfile::tempdir().unwrap();
    let workspace = root.path().join("workspace");
    std::fs::create_dir(&workspace).unwrap();
    let cli = root.path().join("cancel.exe");
    std::fs::copy(fixture(), &cli).unwrap();
    let source = account_sources::task_fixture_source(root.path().join("profiles"), cli);
    assert!(source.home.is_dir());
    let manager = Arc::new(Manager {
        state: Mutex::new(State {
            accepting: true,
            tasks: HashMap::new(),
        }),
        next: AtomicU64::new(1),
        nonce: 12,
        source_factory: Some(source.acquire.clone()),
    });
    let draft=manager.execute("task_prepare",json!({"mode":"official","sourceId":source.id,"workspace":workspace,"prompt":"Synthetic lease test","model":"fixture-model","sandbox":"read-only"})).unwrap();
    let id = identity(&draft);
    manager.execute("task_start", id.clone()).unwrap();
    await_state(&manager, &id, "running");
    assert_eq!((source.remove)().unwrap_err(), "busy");
    assert_eq!((source.acquire)(&source.id).err().unwrap(), "busy");
    manager.execute("task_cancel", id.clone()).unwrap();
    wait(&manager, &id, &["cancelled"]);
    assert_eq!((source.remove)().unwrap()["removed"], true);
}
