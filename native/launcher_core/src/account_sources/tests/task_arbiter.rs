use super::*;
mod execution_integration;

fn task_lease(s: &Arc<Service>, id: &str) -> Result<Lease> {
    s.lease_for(id, Purpose::Task)
}

#[test]
fn task_remove_is_busy_without_cancelling_or_deleting_task_home() {
    let (_root, s) = service("success");
    let id = create(&s);
    let lease = task_lease(&s, &id).unwrap();
    let home = lease.home.clone();
    let cancel = lease.cancel.clone();
    let other = s.clone();
    let source = id.clone();
    let removal = thread::spawn(move || other.remove(&source));
    let deadline = Instant::now() + Duration::from_secs(3);
    while !cancel.load(Ordering::SeqCst) && !removal.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let was_cancelled = cancel.load(Ordering::SeqCst);
    drop(lease); // permit the old removal path to finish, even in the RED run
    let result = removal.join().unwrap();
    assert!(
        !was_cancelled,
        "remove must not cancel a task as a side effect"
    );
    assert_eq!(result.unwrap_err().kind, "busy");
    assert!(home.join(".monitor-profile.json").is_file());
}

#[test]
fn task_profile_validation_holds_cross_service_file_lock() {
    let (_root, s) = service("success");
    let id = create(&s);
    let second = Service::for_test(
        s.root.clone(),
        fixture("success"),
        Duration::from_millis(500),
    );
    let source = id.clone();
    *s.lease_probe.lock().unwrap() = Some(Box::new(move || {
        let result = second.remove(&source);
        assert!(
            result.is_err(),
            "another service deleted the profile in the validation/lock gap"
        );
        assert_eq!(result.unwrap_err().kind, "busy");
    }));
    let lease = task_lease(&s, &id).unwrap();
    assert!(lease.home.is_dir());
    drop(lease);
}

#[test]
fn task_reservation_blocks_writers_but_other_sources_and_services_are_independent() {
    let (_root, s) = service("success");
    let (a, b) = (create(&s), create(&s));
    let lease = task_lease(&s, &a).unwrap();
    assert_eq!(s.usage(&a).unwrap_err().kind, "busy");
    assert_eq!(s.login(&a).unwrap_err().kind, "busy");
    assert!(task_lease(&s, &a).is_err());
    let second = Service::for_test(
        s.root.clone(),
        fixture("failure"),
        Duration::from_millis(500),
    );
    assert_eq!(second.usage(&a).unwrap_err().kind, "busy");
    assert_eq!(second.login(&a).unwrap_err().kind, "busy");
    let other = task_lease(&second, &b).unwrap();
    assert_ne!(lease.home, other.home);
    // Persisted profile metadata, not Service.bound, determines the fixed CLI.
    assert_eq!(fixed_cli(&other.metadata).unwrap(), fixture("success"));
    drop(lease);
    assert!(task_lease(&second, &a).is_ok());
    drop(other);
}

#[test]
fn task_changed_cli_is_rejected_without_leaking_a_reservation() {
    let root = tempfile::tempdir().unwrap();
    let copy = root.path().join("owned-fixture.exe");
    fs::copy(fixture("success"), &copy).unwrap();
    let s = Service::for_test(
        root.path().join("account-profiles"),
        copy.clone(),
        Duration::from_millis(500),
    );
    let id = create(&s);
    fs::write(&copy, b"changed-synthetic-binary").unwrap();
    let kind = match task_lease(&s, &id) {
        Ok(lease) => {
            drop(lease);
            None
        }
        Err(error) => Some(error.kind),
    };
    assert_eq!(kind, Some("unavailable"));
    assert!(!s.state.lock().unwrap().active.contains_key(&id));
    assert!(s.remove(&id).unwrap()["removed"] == true);
}

#[test]
fn task_protected_and_missing_sources_never_create_a_fallback_home() {
    let (_root, s) = service("success");
    for id in ["current", "default", "", "profile-invalid"] {
        assert!(task_lease(&s, id).is_err());
    }
    assert!(s.state.lock().unwrap().active.is_empty());
}

#[test]
fn task_cancel_before_start_never_invokes_child_factory() {
    let (_root, s) = service("success");
    let id = create(&s);
    let lease = task_lease(&s, &id).unwrap();
    lease.cancel.store(true, Ordering::SeqCst);
    let mut called = false;
    let result = lease.task_start(|| called = true);
    drop(lease);
    assert!(!called, "cancelled reservation must not start a child");
    assert_eq!(result.unwrap_err().kind, "cancelled");
}

#[test]
fn task_stale_owner_cannot_start_or_erase_successor_ownership() {
    let (_root, s) = service("success");
    let id = create(&s);
    let lease = task_lease(&s, &id).unwrap();
    let successor = Arc::new(AtomicBool::new(false));
    s.state.lock().unwrap().active.insert(
        id.clone(),
        Active {
            purpose: Purpose::Task,
            cancel: successor.clone(),
        },
    );
    let mut called = false;
    let result = lease.task_start(|| called = true);
    drop(lease);
    let state = s.state.lock().unwrap();
    assert!(Arc::ptr_eq(
        &state.active.get(&id).unwrap().cancel,
        &successor
    ));
    assert!(!called, "only exact active owner can start");
    assert_eq!(result.unwrap_err().kind, "busy");
}

#[test]
fn task_shutdown_keeps_cross_service_lease_until_guard_cleanup() {
    let (_root, s) = service("success");
    let id = create(&s);
    let lease = task_lease(&s, &id).unwrap();
    let other = Service::for_test(
        s.root.clone(),
        fixture("success"),
        Duration::from_millis(500),
    );
    let shutdown_service = s.clone();
    let (sender, receiver) = std::sync::mpsc::channel();
    let worker = thread::spawn(move || {
        sender.send(shutdown_service.shutdown()).unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(3);
    while !lease.cancel.load(Ordering::SeqCst) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let cancelled = lease.cancel.load(Ordering::SeqCst);
    let still_waiting = matches!(
        receiver.try_recv(),
        Err(std::sync::mpsc::TryRecvError::Empty)
    );
    let blocked_elsewhere = other.lease(&id).is_err();
    let new_denied = matches!(s.lease(&id), Err(Error { kind: "shutdown" }));
    drop(lease);
    let result = receiver.recv_timeout(Duration::from_secs(3)).unwrap();
    worker.join().unwrap();
    assert!(cancelled && still_waiting && blocked_elsewhere && new_denied);
    assert_eq!(result.unwrap()["shutdown"], true);
    assert!(task_lease(&other, &id).is_ok());
}
