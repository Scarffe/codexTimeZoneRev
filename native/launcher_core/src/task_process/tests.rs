use super::*;
use serde_json::json;
use std::{fs, sync::atomic::Ordering, time::Instant};
const WAIT: Duration = Duration::from_secs(3);

#[test]
fn task_process_compiler_unset_uses_first_existing_absolute_developer_path_entry() {
    let root = tempfile::tempdir().unwrap();
    let first = root.path().join("compiler one");
    let second = root.path().join("compiler two");
    fs::create_dir(&first).unwrap();
    fs::create_dir(&second).unwrap();
    let compiler_name = if cfg!(windows) { "rustc.exe" } else { "rustc" };
    fs::write(first.join(compiler_name), b"dummy; never executed").unwrap();
    fs::write(second.join(compiler_name), b"dummy; never executed").unwrap();
    let path = std::env::join_paths([
        PathBuf::from("relative-untrusted-entry"),
        root.path().join("absent"),
        first.clone(),
        second,
    ])
    .unwrap();
    assert_eq!(
        fixture_compiler(None, Some(&path)),
        Ok(first.join(compiler_name))
    );
}

#[test]
fn task_process_compiler_explicit_valid_absolute_overrides_developer_path() {
    let root = tempfile::tempdir().unwrap();
    let compiler = root.path().join("chosen-rustc.exe");
    fs::write(&compiler, b"dummy; never executed").unwrap();
    let path_compiler = root.path().join("rustc.exe");
    fs::write(path_compiler, b"dummy; never executed").unwrap();
    assert_eq!(
        fixture_compiler(Some(compiler.as_os_str()), Some(root.path().as_os_str())),
        Ok(compiler.clone())
    );
    assert_eq!(
        fixture_compiler(Some(compiler.as_os_str()), None),
        Ok(compiler)
    );
}

#[test]
fn task_process_compiler_invalid_explicit_or_missing_path_fails_without_fallback() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("rustc.exe"), b"dummy; never executed").unwrap();
    let valid_path = root.path().as_os_str();
    for invalid in [
        PathBuf::new(),
        PathBuf::from("rustc.exe"),
        root.path().join("missing.exe"),
        root.path().to_path_buf(),
    ] {
        assert_eq!(
            fixture_compiler(Some(invalid.as_os_str()), Some(valid_path)),
            Err("explicit fixture compiler invalid")
        );
    }
    assert_eq!(
        fixture_compiler(None, None),
        Err("fixture compiler unavailable")
    );
    assert_eq!(
        fixture_compiler(None, Some(std::ffi::OsStr::new("relative-entry"))),
        Err("fixture compiler unavailable")
    );
    assert_eq!(
        fixture_compiler(None, Some(root.path().join("missing").as_os_str())),
        Err("fixture compiler unavailable")
    );
}

fn launch(mode: FixtureMode) -> (tempfile::TempDir, FixtureLaunch) {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let workspace = root.path().join("workspace");
    fs::create_dir(&home).unwrap();
    fs::create_dir(&workspace).unwrap();
    (
        root,
        FixtureLaunch {
            home,
            workspace,
            mode,
        },
    )
}
fn start(mode: FixtureMode) -> (tempfile::TempDir, TaskProcess, Arc<AtomicBool>) {
    let (root, launch) = launch(mode);
    let cancel = Arc::new(AtomicBool::new(false));
    let process = TaskProcess::spawn_fixture(launch, cancel.clone()).unwrap();
    (root, process, cancel)
}
fn stop(process: &mut TaskProcess) {
    let identity = process.identity();
    let receipt = process.shutdown(&identity, WAIT).unwrap();
    assert_eq!(receipt.pid(), identity.pid());
    assert!(receipt.is_complete());
    assert!(receipt.belongs_to(&identity));
    assert!(process.shutdown(&identity, WAIT).unwrap().is_complete());
}

// Removing env_clear, the file-store argument, or cwd/home isolation breaks this.
#[test]
fn task_process_two_children_isolate_paths_environment_and_dummy_files() {
    let names = [
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "CODEX_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
    ];
    let before: Vec<_> = names.iter().map(std::env::var_os).collect();
    // The dedicated isolation runner requires positive inherited-canary proof.
    // Ordinary cargo test can run without synthetic provider variables; it still
    // proves the child's provider-key set is empty and the parent is unchanged.
    if std::env::var_os("CTZ_K31_REQUIRE_CANARIES").as_deref() == Some(std::ffi::OsStr::new("1")) {
        assert!(
            before.iter().all(Option::is_some),
            "runner must seed synthetic canaries"
        );
    }
    let (root_a, mut a, _) = start(FixtureMode::Normal);
    let (root_b, mut b, _) = start(FixtureMode::Normal);
    assert_ne!(a.identity(), b.identity());
    let status_a = a.receive(WAIT).unwrap();
    let status_b = b.receive(WAIT).unwrap();
    for (status, root) in [(&status_a, &root_a), (&status_b, &root_b)] {
        assert_eq!(status["method"], "fixture/ready");
        assert_eq!(
            status["home"],
            fs::canonicalize(root.path().join("home"))
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(
            status["cwd"],
            fs::canonicalize(root.path().join("workspace"))
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(status["file_store"], true);
        assert_eq!(status["provider_keys"], json!([]));
        assert_eq!(status["home_dirs_match"], true);
        assert_eq!(
            fs::read_to_string(root.path().join("home/fixture-dummy.txt")).unwrap(),
            "synthetic fixture only"
        );
    }
    assert_ne!(status_a["home"], status_b["home"]);
    assert_ne!(status_a["cwd"], status_b["cwd"]);
    stop(&mut a);
    stop(&mut b);
    assert!(
        before == names.iter().map(std::env::var_os).collect::<Vec<_>>(),
        "parent environment changed"
    );
}

// Dropping notifications/server requests or rewriting IDs breaks exact ordering.
#[test]
fn task_process_bidirectional_messages_retain_approval_notifications_and_response() {
    let (_root, mut process, _) = start(FixtureMode::Normal);
    process.receive(WAIT).unwrap();
    process
        .send(json!({"id":7,"method":"approval"}), WAIT)
        .unwrap();
    assert_eq!(
        process.receive(WAIT).unwrap(),
        json!({"method":"fixture/progress","params":{"phase":"before"}})
    );
    assert_eq!(
        process.receive(WAIT).unwrap(),
        json!({"id":"approval-7","method":"fixture/approval","params":{"task":"synthetic"}})
    );
    process
        .send(json!({"id":"approval-7","result":{"approved":true}}), WAIT)
        .unwrap();
    assert_eq!(
        process.receive(WAIT).unwrap(),
        json!({"method":"fixture/progress","params":{"phase":"after"}})
    );
    assert_eq!(
        process.receive(WAIT).unwrap(),
        json!({"id":7,"result":{"approved":true}})
    );
    stop(&mut process);
}

#[test]
fn task_process_foreign_identity_does_not_touch_other_child() {
    let (_a, mut a, _) = start(FixtureMode::Normal);
    let (_b, mut b, _) = start(FixtureMode::Normal);
    a.receive(WAIT).unwrap();
    b.receive(WAIT).unwrap();
    assert_eq!(
        a.shutdown(&b.identity(), WAIT).unwrap_err(),
        ProcessError::ForeignIdentity
    );
    a.send(json!({"id":1,"method":"echo"}), WAIT).unwrap();
    assert_eq!(a.receive(WAIT).unwrap()["id"], 1);
    stop(&mut a);
    assert!(!a
        .shutdown(&a.identity(), WAIT)
        .unwrap()
        .belongs_to(&b.identity()));
    b.send(json!({"id":2,"method":"echo"}), WAIT).unwrap();
    assert_eq!(b.receive(WAIT).unwrap()["id"], 2);
    stop(&mut b);
}

#[test]
fn task_process_cancel_deadline_and_blocked_pipe_are_bounded() {
    let (_root, mut process, cancel) = start(FixtureMode::Silent);
    process.receive(WAIT).unwrap();
    let began = Instant::now();
    assert_eq!(
        process.receive(Duration::from_millis(60)),
        Err(ProcessError::Deadline)
    );
    assert!(began.elapsed() < Duration::from_secs(1));
    cancel.store(true, Ordering::Release);
    assert_eq!(process.receive(WAIT), Err(ProcessError::Cancelled));
    assert_eq!(
        process.send(json!({"id":1}), WAIT),
        Err(ProcessError::Cancelled)
    );
    stop(&mut process);
    let (_root, mut blocked, _) = start(FixtureMode::BlockInput);
    blocked.receive(WAIT).unwrap();
    let began = Instant::now();
    // Windows can buffer the first frame without a reader. Fill the actual pipe
    // rather than assuming a platform-specific anonymous-pipe capacity.
    let mut blocked_result = Ok(());
    for id in 1..=64 {
        blocked_result = blocked.send(
            json!({"id":id,"method":"echo","data":"x".repeat(60_000)}),
            Duration::from_millis(80),
        );
        if blocked_result.is_err() {
            break;
        }
    }
    assert_eq!(blocked_result, Err(ProcessError::Deadline));
    let retry_began = Instant::now();
    assert_eq!(
        blocked.send(json!({"id":100,"method":"echo"}), WAIT),
        Err(ProcessError::Deadline)
    );
    assert!(
        retry_began.elapsed() < Duration::from_millis(100),
        "uncertain write must poison new sends immediately"
    );
    stop(&mut blocked);
    assert!(began.elapsed() < WAIT);
}

#[test]
fn task_process_bad_output_errors_are_typed_and_bounded() {
    for (mode, expected) in [
        (FixtureMode::Crash, ProcessError::Eof),
        (FixtureMode::Malformed, ProcessError::Malformed),
        (FixtureMode::Oversized, ProcessError::Oversized),
        (FixtureMode::Flood, ProcessError::QueueOverflow),
    ] {
        let (_root, mut process, _) = start(mode);
        let began = Instant::now();
        let error = loop {
            match process.receive(WAIT) {
                Ok(_) => {
                    std::thread::sleep(Duration::from_millis(40));
                }
                Err(e) => break e,
            }
        };
        assert_eq!(error, expected, "{mode:?}");
        assert_eq!(
            process.send(json!({"id":3,"method":"echo"}), WAIT),
            Err(expected),
            "terminal output cannot accept new work"
        );
        stop(&mut process);
        assert!(began.elapsed() < WAIT);
    }
}

#[test]
fn task_process_invalid_paths_startup_and_invalid_frames_fail_closed() {
    let (_root, mut config) = launch(FixtureMode::Normal);
    config.home = config.home.join("missing");
    assert!(matches!(
        TaskProcess::spawn_fixture(config, Arc::new(AtomicBool::new(false))),
        Err(ProcessError::InvalidPath)
    ));
    let (_root, config) = launch(FixtureMode::StartupError);
    assert!(matches!(
        TaskProcess::spawn_fixture(config, Arc::new(AtomicBool::new(false))),
        Err(ProcessError::Startup)
    ));
    let (_root, mut process, _) = start(FixtureMode::Normal);
    process.receive(WAIT).unwrap();
    assert_eq!(
        process.send(json!({"id":{},"method":"echo"}), WAIT),
        Err(ProcessError::InvalidMessage)
    );
    assert_eq!(
        process.send(json!({"id":1,"data":"x".repeat(65536)}), WAIT),
        Err(ProcessError::Oversized)
    );
    stop(&mut process);
}

#[test]
fn task_process_precancelled_launch_has_no_fixture_side_effects() {
    let (_root, config) = launch(FixtureMode::Normal);
    let home = config.home.clone();
    assert!(matches!(
        TaskProcess::spawn_fixture(config, Arc::new(AtomicBool::new(true))),
        Err(ProcessError::Cancelled)
    ));
    assert!(!home.join("fixture-dummy.txt").exists());
}

#[test]
fn task_process_outgoing_budget_and_depth_fail_before_any_pipe_write() {
    let (_root, mut process, _) = start(FixtureMode::Normal);
    process.receive(WAIT).unwrap();
    assert_eq!(
        process.send(json!({"id":1,"data":"x".repeat(65_536)}), Duration::ZERO),
        Err(ProcessError::Deadline)
    );
    let mut nested = json!(0);
    for _ in 0..200 {
        nested = json!([nested]);
    }
    assert_eq!(
        process.send(json!({"id":2,"data":nested}), WAIT),
        Err(ProcessError::InvalidMessage)
    );
    process.send(json!({"id":3,"method":"echo"}), WAIT).unwrap();
    assert_eq!(process.receive(WAIT).unwrap()["id"], 3);
    stop(&mut process);
}

#[test]
fn task_process_wait_observes_cancellation_while_pending() {
    let (_root, mut process, cancel) = start(FixtureMode::Silent);
    process.receive(WAIT).unwrap();
    let toggler = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(60));
        cancel.store(true, Ordering::Release);
    });
    let began = Instant::now();
    assert_eq!(process.receive(WAIT), Err(ProcessError::Cancelled));
    assert!(began.elapsed() < Duration::from_secs(1));
    toggler.join().unwrap();
    stop(&mut process);
}

#[test]
fn task_process_rejects_aliased_and_reparse_directories() {
    let (root, mut config) = launch(FixtureMode::Normal);
    config.workspace = config.home.clone();
    assert!(matches!(
        TaskProcess::spawn_fixture(config, Arc::new(AtomicBool::new(false))),
        Err(ProcessError::InvalidPath)
    ));
    let link = root.path().join("linked-home");
    create_junction(&link, &root.path().join("home"));
    let config = FixtureLaunch {
        home: link.clone(),
        workspace: root.path().join("workspace"),
        mode: FixtureMode::Normal,
    };
    assert!(matches!(
        TaskProcess::spawn_fixture(config, Arc::new(AtomicBool::new(false))),
        Err(ProcessError::InvalidPath)
    ));
    // Remove only the junction itself, never recursively follow its target.
    fs::remove_dir(&link).unwrap();
    assert!(!root.path().join("home/fixture-dummy.txt").exists());
}

// Junctions exercise the reparse-point boundary without requiring the Windows
// symbolic-link privilege. This writes only the test's newly created directory.
fn create_junction(link: &std::path::Path, target: &std::path::Path) {
    use std::ffi::c_void;
    use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn DeviceIoControl(
            handle: *mut c_void,
            code: u32,
            input: *const c_void,
            input_size: u32,
            output: *mut c_void,
            output_size: u32,
            returned: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
    }
    assert!(link.is_absolute() && target.is_absolute());
    assert_eq!(link.parent(), target.parent());
    fs::create_dir(link).unwrap();
    let target = fs::canonicalize(target)
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let display = target.strip_prefix(r"\\?\").unwrap_or(&target);
    let substitute: Vec<u16> = format!(r"\??\{display}").encode_utf16().collect();
    let print: Vec<u16> = display.encode_utf16().collect();
    let path_bytes = (substitute.len() + print.len() + 2) * 2;
    let mut buffer = Vec::new();
    buffer.extend_from_slice(&0xa0000003u32.to_le_bytes());
    for value in [
        (8 + path_bytes) as u16,
        0,
        0,
        (substitute.len() * 2) as u16,
        ((substitute.len() + 1) * 2) as u16,
        (print.len() * 2) as u16,
    ] {
        buffer.extend_from_slice(&value.to_le_bytes());
    }
    for value in substitute.into_iter().chain([0]).chain(print).chain([0]) {
        buffer.extend_from_slice(&value.to_le_bytes());
    }
    let file = fs::OpenOptions::new()
        .access_mode(0x40000000)
        .custom_flags(0x00200000 | 0x02000000)
        .open(link)
        .unwrap();
    let mut returned = 0;
    let result = unsafe {
        DeviceIoControl(
            file.as_raw_handle(),
            0x000900a4,
            buffer.as_ptr().cast(),
            buffer.len() as u32,
            std::ptr::null_mut(),
            0,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    assert_ne!(
        result,
        0,
        "fixture junction: {}",
        std::io::Error::last_os_error()
    );
}

#[test]
fn task_process_total_retained_output_never_exceeds_32_messages() {
    let (_root, mut process, _) = start(FixtureMode::Flood);
    std::thread::sleep(Duration::from_millis(150));
    let mut retained = 0;
    loop {
        match process.receive(WAIT) {
            Ok(_) => retained += 1,
            Err(ProcessError::QueueOverflow) => break,
            result => panic!("unexpected flood result: {result:?}"),
        }
    }
    assert!(retained <= 32, "retained {retained} messages");
    stop(&mut process);
}

// A descendant inherits stdout so reader joining also proves inherited pipes close.
#[test]
fn task_process_descendants_die_on_shutdown_and_drop_unrelated_child_survives() {
    use windows::Win32::{
        Foundation::{CloseHandle, WAIT_OBJECT_0},
        System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE},
    };
    let (_other_root, mut other, _) = start(FixtureMode::Normal);
    other.receive(WAIT).unwrap();
    for explicit in [true, false] {
        let (_root, mut process, _) = start(FixtureMode::Descendant);
        let ready = process.receive(WAIT).unwrap();
        let descendant = ready["descendant_pid"].as_u64().unwrap() as u32;
        let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, descendant).unwrap() };
        if explicit {
            stop(&mut process);
        }
        drop(process);
        assert_eq!(unsafe { WaitForSingleObject(handle, 3000) }, WAIT_OBJECT_0);
        unsafe {
            CloseHandle(handle).unwrap();
        }
        other.send(json!({"id":9,"method":"echo"}), WAIT).unwrap();
        assert_eq!(other.receive(WAIT).unwrap()["id"], 9);
    }
    stop(&mut other);
}
