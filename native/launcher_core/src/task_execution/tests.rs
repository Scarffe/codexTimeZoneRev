use super::*;

fn binding(name: &str) -> Binding {
    Binding::fixture(
        &format!("profile-{name}"),
        &format!("fixture-principal-{name}"),
        &format!("fixture-canonical-workspace-{name}"),
        &format!("task-{name}"),
        1,
        1,
    )
    .unwrap()
}

fn running(registry: &mut Registry, b: &Binding) -> Route {
    registry.prepare(b.clone()).unwrap();
    registry
        .started(b, &format!("thread-{}", b.task_id), "turn-1")
        .unwrap()
}

#[test]
fn rejects_current_default_and_ambiguous_bindings() {
    for source in ["", "current", "default", " CURRENT ", "profile-"] {
        assert!(Binding::fixture(source, "principal", "workspace", "task", 1, 1).is_err());
    }
    assert!(Binding::fixture("profile-a", "", "workspace", "task", 1, 1).is_err());
    assert!(Binding::fixture("profile-a", "principal", "", "task", 1, 1).is_err());
    assert!(Binding::fixture("profile-a", "principal", "workspace", "task", 0, 1).is_err());
    assert!(Binding::fixture("profile-a", "principal", "workspace", "task", 1, 0).is_err());
    assert!(!REAL_EXECUTION_SUPPORTED);
}

#[test]
fn two_sources_progress_independently_and_keep_exact_approval_routes() {
    let mut r = Registry::default();
    let (a, b) = (binding("a"), binding("b"));
    let ar = running(&mut r, &a);
    let br = running(&mut r, &b);
    r.approval(&ar, "request-a").unwrap();
    assert_eq!(r.state(&a), Ok(State::AwaitingApproval));
    assert_eq!(r.state(&b), Ok(State::Running));
    assert_eq!(
        r.decision(&br, "request-a", true),
        Err(Error::InvalidApproval)
    );
    r.terminal(&br, Outcome::Completed).unwrap();
    assert_eq!(r.state(&a), Ok(State::AwaitingApproval));
    let decision = r.decision(&ar, "request-a", true).unwrap();
    assert_eq!(decision.route, ar);
    assert_eq!(decision.request_id, "request-a");
    assert!(decision.approved);
    assert_eq!(r.state(&a), Ok(State::Running));
}

#[test]
fn source_and_workspace_reservations_last_until_terminal_and_cleanup() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    let mut same_source = binding("second");
    same_source.source_id = a.source_id.clone();
    assert_eq!(r.prepare(same_source.clone()), Err(Error::SourceBusy));
    let mut same_workspace = binding("b");
    same_workspace.workspace_key = a.workspace_key.clone();
    assert_eq!(r.prepare(same_workspace.clone()), Err(Error::WorkspaceBusy));
    assert_eq!(r.release_after_cleanup(&a), Err(Error::InvalidState));
    r.terminal(&ar, Outcome::Completed).unwrap();
    assert_eq!(r.prepare(same_source.clone()), Err(Error::SourceBusy));
    r.release_after_cleanup(&a).unwrap();
    r.prepare(same_source).unwrap();
    r.prepare(same_workspace).unwrap();
    assert_eq!(r.prepare(a), Err(Error::DuplicateTask));
}

#[test]
fn every_ownership_axis_rejects_events_without_state_change() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    r.approval(&ar, "request-a").unwrap();
    let before = r.clone();
    let mut mutations = Vec::new();
    for axis in 0..8 {
        let mut bad = ar.clone();
        match axis {
            0 => bad.binding.source_id = "profile-b".into(),
            1 => bad.binding.identity_binding = "other-principal".into(),
            2 => bad.binding.workspace_key = "other-workspace".into(),
            3 => bad.binding.task_id = "other-task".into(),
            4 => bad.binding.source_epoch += 1,
            5 => bad.binding.generation += 1,
            6 => bad.thread_id = "foreign-thread".into(),
            _ => bad.turn_id = "foreign-turn".into(),
        }
        mutations.push(bad);
    }
    for bad in mutations {
        assert!(r.approval(&bad, "new-request").is_err());
        assert!(r.decision(&bad, "request-a", true).is_err());
        assert!(r.cancel(&bad).is_err());
        assert!(r.terminal(&bad, Outcome::Completed).is_err());
        assert!(r.disconnected(&bad).is_err());
        assert!(r.resume_plan(&bad).is_err());
        assert_eq!(r, before);
    }
}

#[test]
fn start_event_must_match_prepared_generation_and_cannot_rebind() {
    let mut r = Registry::default();
    let a = binding("a");
    r.prepare(a.clone()).unwrap();
    let before = r.clone();
    let mut late = a.clone();
    late.generation += 1;
    assert!(r.started(&late, "thread", "turn").is_err());
    assert!(r.started(&a, "", "turn").is_err());
    assert_eq!(r, before);
    let route = r.started(&a, "thread-a", "turn-a").unwrap();
    assert_eq!(
        r.started(&a, "other-thread", "turn-b"),
        Err(Error::InvalidState)
    );
    assert_eq!(r.route(&a), Ok(&route));
}

#[test]
fn approvals_are_consumed_once_and_replays_never_reopen_them() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    r.approval(&ar, "request-a").unwrap();
    r.approval(&ar, "request-b").unwrap();
    r.decision(&ar, "request-a", false).unwrap();
    assert_eq!(r.state(&a), Ok(State::AwaitingApproval));
    let before = r.clone();
    assert!(r.decision(&ar, "request-a", true).is_err());
    assert!(r.approval(&ar, "request-a").is_err());
    assert_eq!(r, before);
    r.decision(&ar, "request-b", true).unwrap();
    assert_eq!(r.state(&a), Ok(State::Running));
}

#[test]
fn cancel_invalidates_approval_but_does_not_claim_a_terminal_outcome() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    r.approval(&ar, "request-a").unwrap();
    r.cancel(&ar).unwrap();
    assert_eq!(r.state(&a), Ok(State::Cancelling));
    let before = r.clone();
    assert!(r.decision(&ar, "request-a", true).is_err());
    assert!(r.approval(&ar, "late-request").is_err());
    assert!(r.release_after_cleanup(&a).is_err());
    assert_eq!(r, before);
    r.terminal(&ar, Outcome::Cancelled).unwrap();
    assert_eq!(r.state(&a), Ok(State::Cancelled));
}

#[test]
fn terminal_event_is_authoritative_in_cancel_completion_races() {
    for completed_first in [false, true] {
        let mut r = Registry::default();
        let a = binding("a");
        let ar = running(&mut r, &a);
        if !completed_first {
            r.cancel(&ar).unwrap();
        }
        r.terminal(&ar, Outcome::Completed).unwrap();
        assert_eq!(r.state(&a), Ok(State::Completed));
        let before = r.clone();
        assert!(r.cancel(&ar).is_err());
        assert!(r.terminal(&ar, Outcome::Cancelled).is_err());
        assert_eq!(r, before);
    }
}

#[test]
fn disconnect_and_restore_do_not_auto_resume_or_complete() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    r.approval(&ar, "old-request").unwrap();
    r.disconnected(&ar).unwrap();
    assert_eq!(r.state(&a), Ok(State::Recoverable));
    assert!(r.decision(&ar, "old-request", true).is_err());
    assert!(r.terminal(&ar, Outcome::Completed).is_err());
    assert!(r.release_after_cleanup(&a).is_err());
    let mut restored = Registry::default();
    restored
        .restore_owned_fixture(r.recovery_record(&ar).unwrap())
        .unwrap();
    let before = restored.clone();
    assert_eq!(restored.state(&a), Ok(State::Recoverable));
    let plan = restored.resume_plan(&ar).unwrap();
    assert_eq!(plan.route, ar);
    assert!(!plan.real_execution_supported);
    assert_eq!(
        restored, before,
        "planning alone has zero execution side effects"
    );
    for axis in 0..3 {
        let mut bad = ar.clone();
        match axis {
            0 => bad.binding.source_id = "profile-b".into(),
            1 => bad.binding.identity_binding = "changed-identity".into(),
            _ => bad.thread_id = "foreign-thread".into(),
        }
        assert!(restored.resume_plan(&bad).is_err());
        assert_eq!(restored, before);
    }
}

#[test]
fn cancelled_intent_survives_disconnect_and_restore_without_resuming() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    r.cancel(&ar).unwrap();
    r.disconnected(&ar).unwrap();
    assert!(
        r.resume_plan(&ar).is_err(),
        "disconnect must not erase cancel intent"
    );
    let mut restored = Registry::default();
    restored
        .restore_owned_fixture(r.recovery_record(&ar).unwrap())
        .unwrap();
    assert!(restored.resume_plan(&ar).is_err());
    assert_eq!(restored.state(&a), Ok(State::Recoverable));
}

#[test]
fn failure_or_cancel_before_thread_start_can_release_only_its_own_runtime() {
    for outcome in [Outcome::Failed, Outcome::Cancelled] {
        let mut r = Registry::default();
        let a = binding("a");
        r.prepare(a.clone()).unwrap();
        assert!(r.abort_prepared(&a, Outcome::Completed).is_err());
        r.abort_prepared(&a, outcome).unwrap();
        assert!(r.started(&a, "late-thread", "late-turn").is_err());
        r.release_after_cleanup(&a).unwrap();
        let mut next = a.clone();
        next.task_id = "next-task".into();
        next.generation += 1;
        r.prepare(next).unwrap();
    }
}

#[test]
fn failed_runtime_never_appears_completed_or_releases_another_owners_reservation() {
    let mut r = Registry::default();
    let (a, b) = (binding("a"), binding("b"));
    let ar = running(&mut r, &a);
    let br = running(&mut r, &b);
    r.terminal(&ar, Outcome::Failed).unwrap();
    r.release_after_cleanup(&a).unwrap();
    assert_eq!(r.state(&a), Ok(State::Failed));
    assert_eq!(r.state(&b), Ok(State::Running));
    assert!(r.release_after_cleanup(&b).is_err());
    r.terminal(&br, Outcome::Cancelled).unwrap();
}

#[test]
fn old_thread_cannot_be_imported_by_a_new_task() {
    let mut r = Registry::default();
    let a = binding("a");
    let ar = running(&mut r, &a);
    r.terminal(&ar, Outcome::Completed).unwrap();
    r.release_after_cleanup(&a).unwrap();
    let mut next = a.clone();
    next.task_id = "next-task".into();
    next.generation += 1;
    r.prepare(next.clone()).unwrap();
    assert_eq!(
        r.started(&next, &ar.thread_id, "new-turn"),
        Err(Error::ThreadOwned)
    );
    assert_eq!(r.state(&next), Ok(State::Prepared));
}
