//! Include as account_sources::tests::runtime_helper after root approves API.
use super::*;
use crate::desktop_auth::ManagedAccountProvider;
use crate::runtime_helper::*;
use std::collections::VecDeque;

#[derive(Clone)]
struct Control(Arc<Mutex<FakeState>>);
struct FakeTransport(Control);
struct FakeState {
    alive: bool,
    sequence: u64,
    events: VecDeque<RuntimeEvent>,
    next_login: Delivery,
    next_refresh: Delivery,
    logins: Vec<(CorrelationId, String, bool, Duration)>,
    refreshes: Vec<(RefreshRequestId, String, bool, Duration)>,
    reads: Vec<CorrelationId>,
}
impl Control {
    fn new() -> Self {
        Self(Arc::new(Mutex::new(FakeState {
            alive: true,
            sequence: 0,
            events: VecDeque::new(),
            next_login: Delivery::Written,
            next_refresh: Delivery::Written,
            logins: vec![],
            refreshes: vec![],
            reads: vec![],
        })))
    }
    fn push(&self, kind: RuntimeEventKind) {
        let mut state = self.0.lock().unwrap();
        state.sequence += 1;
        let sequence = state.sequence;
        state.events.push_back(RuntimeEvent { sequence, kind });
    }
    fn exit(&self) {
        self.0.lock().unwrap().alive = false;
    }
    fn last_read(&self) -> CorrelationId {
        *self.0.lock().unwrap().reads.last().unwrap()
    }
}
impl RuntimeTransport for FakeTransport {
    fn write_login(
        &mut self,
        id: CorrelationId,
        token: &str,
        principal: &str,
        plan_type: Option<&str>,
        deadline: Instant,
    ) -> WriteReceipt {
        assert_eq!(
            plan_type,
            Some("plus"),
            "source plan must reach the SDK's optional chatgptPlanType field"
        );
        let mut state = self.0 .0.lock().unwrap();
        let marker = principal
            .strip_prefix("synthetic-account-")
            .unwrap_or("INVALID");
        let recognized = token.ends_with(&format!(".synthetic-signature-{marker}"));
        state.logins.push((
            id,
            principal.into(),
            recognized,
            deadline.saturating_duration_since(Instant::now()),
        ));
        let delivery = state.next_login;
        state.next_login = Delivery::Written;
        WriteReceipt {
            delivery,
            observed_through: state.sequence,
        }
    }
    fn write_refresh_response(
        &mut self,
        id: &RefreshRequestId,
        token: &str,
        principal: &str,
        plan_type: Option<&str>,
        deadline: Instant,
    ) -> Delivery {
        assert_eq!(
            plan_type,
            Some("plus"),
            "refresh must preserve the source's optional plan observation"
        );
        let mut state = self.0 .0.lock().unwrap();
        let marker = principal
            .strip_prefix("synthetic-account-")
            .unwrap_or("INVALID");
        let recognized = token.ends_with(&format!(".synthetic-refreshed-{marker}"));
        state.refreshes.push((
            id.clone(),
            principal.into(),
            recognized,
            deadline.saturating_duration_since(Instant::now()),
        ));
        let delivery = state.next_refresh;
        state.next_refresh = Delivery::Written;
        delivery
    }
    fn request_account_read(
        &mut self,
        id: CorrelationId,
        _deadline: Instant,
    ) -> std::result::Result<(), TransportError> {
        self.0 .0.lock().unwrap().reads.push(id);
        Ok(())
    }
    fn poll_event(&mut self) -> std::result::Result<Option<RuntimeEvent>, TransportError> {
        Ok(self.0 .0.lock().unwrap().events.pop_front())
    }
    fn target_alive(&self) -> bool {
        self.0 .0.lock().unwrap().alive
    }
}

fn helper() -> (RuntimeOwner, Control) {
    let control = Control::new();
    (
        RuntimeOwner::new(Box::new(FakeTransport(control.clone())), 0x53594e54),
        control,
    )
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
fn identity(principal: &str) -> ObservedIdentity {
    ObservedIdentity {
        auth: AuthFamily::ChatGpt,
        email: Some(format!("synthetic-{principal}@example.invalid")),
        plan_type: Some("plus".into()),
        account_id: None,
    }
}
fn confirm(owner: &mut RuntimeOwner, control: &Control, attempt: CorrelationId, principal: &str) {
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGptAuthTokens,
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    let read = control.last_read();
    control.push(RuntimeEventKind::AccountRead {
        id: read,
        identity: identity(principal),
    });
    assert_eq!(owner.poll_once().unwrap().phase, Phase::Active);
}
fn busy(s: &Arc<Service>, id: &str) {
    assert_eq!(s.lease_for(id, Purpose::Task).err().unwrap().kind, "busy");
}
fn finish(owner: &mut RuntimeOwner, control: &Control) {
    control.exit();
    assert_eq!(owner.poll_once().unwrap().phase, Phase::TargetExited);
}

#[test]
fn runtime_quota_bound_source_is_rechecked_after_pending_identity_confirmation() {
    let (_root, s) = service("desktop_auth");
    let (_a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, attempt, "A");
    let (expected_root, expected_id) = owner.active_source_key().unwrap();
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGptAuthTokens,
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    control.push(RuntimeEventKind::AccountRead {
        id: control.last_read(),
        identity: identity("B"),
    });
    assert_eq!(
        owner
            .read_quota_for_source(&expected_root, &expected_id, false)
            .err()
            .map(|e| e.kind()),
        Some("source_mismatch"),
        "B confirmed during the auth drain cannot be returned under A's quota label"
    );
    assert_eq!(owner.active_source_key().unwrap().1, b);
    finish(&mut owner, &control);
}

#[test]
fn runtime_write_completion_is_only_pending_authentication() {
    let (_root, s) = service("desktop_auth");
    let (id, provider) = managed(&s, "A");
    let (mut owner, control) = helper();
    owner.begin_switch(provider).unwrap();
    let status = owner.status();
    assert_eq!(status.phase, Phase::AwaitingConfirmation);
    assert!(!status.active_source_retained);
    assert!(status.pending_source_retained);
    busy(&s, &id);
    let state = control.0.lock().unwrap();
    assert_eq!(state.logins.len(), 1);
    assert!(
        state.logins[0].2,
        "fake bridge did not receive the private synthetic credential"
    );
    assert!(state.logins[0].3 <= Duration::from_secs(2));
    drop(state);
    finish(&mut owner, &control);
}

#[test]
fn runtime_holds_old_and_new_until_ack_update_and_later_identity_all_agree() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    busy(&s, &a);
    busy(&s, &b);
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    owner.poll_once().unwrap();
    busy(&s, &a);
    busy(&s, &b);
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGptAuthTokens,
    });
    owner.poll_once().unwrap();
    busy(&s, &a);
    busy(&s, &b);
    control.push(RuntimeEventKind::AccountRead {
        id: control.last_read(),
        identity: identity("B"),
    });
    assert_eq!(owner.poll_once().unwrap().phase, Phase::Active);
    assert!(s.lease_for(&a, Purpose::Task).is_ok());
    busy(&s, &b);
    finish(&mut owner, &control);
}

#[test]
fn runtime_wrong_correlation_and_identity_mismatch_never_release_reservations() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    let reads_before = control.0.lock().unwrap().reads.len();
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: CorrelationId(attempt.0.wrapping_add(500)),
        accepted: true,
    });
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGptAuthTokens,
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    assert_eq!(control.0.lock().unwrap().reads.len(), reads_before);
    busy(&s, &a);
    busy(&s, &b);
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    owner.poll_once().unwrap();
    control.push(RuntimeEventKind::AccountRead {
        id: control.last_read(),
        identity: identity("A"),
    });
    assert_eq!(owner.poll_once().unwrap().phase, Phase::Unresolved);
    busy(&s, &a);
    busy(&s, &b);
    assert_eq!(control.0.lock().unwrap().logins.len(), 2);
    finish(&mut owner, &control);
}

#[test]
fn runtime_unknown_delivery_reconciles_by_bounded_reads_without_token_rewrite_or_rollback() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    control.0.lock().unwrap().next_login = Delivery::Unknown;
    owner.begin_switch(second).unwrap();
    assert_eq!(owner.status().phase, Phase::Unresolved);
    assert_eq!(
        owner.cancel_switch().unwrap_err().kind(),
        "delivery_unresolved"
    );
    let reads_before = control.0.lock().unwrap().reads.len();
    for _ in 0..4 {
        let _ = owner.reconcile();
    }
    let state = control.0.lock().unwrap();
    assert_eq!(
        state.logins.len(),
        2,
        "unknown delivery must not retry a credential write"
    );
    assert!(state.reads.len() - reads_before <= 2);
    drop(state);
    busy(&s, &a);
    busy(&s, &b);
    finish(&mut owner, &control);
}

#[test]
fn runtime_proven_not_written_releases_only_unused_candidate() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    control.0.lock().unwrap().next_login = Delivery::NotWritten;
    assert_eq!(
        owner.begin_switch(second).unwrap_err().kind(),
        "not_written"
    );
    assert_eq!(owner.status().phase, Phase::Active);
    busy(&s, &a);
    assert!(s.lease_for(&b, Purpose::Task).is_ok());
    finish(&mut owner, &control);
}

#[test]
fn runtime_gui_exit_keeps_refresh_owner_and_pending_refresh_waits_for_new_identity() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    owner.gui_detached();
    assert!(!owner.status().gui_attached);
    let old_refresh = RefreshRequestId::Text("synthetic-refresh-A".into());
    control.push(RuntimeEventKind::RefreshRequested {
        id: old_refresh.clone(),
        previous_account_id: None,
    });
    owner.poll_once().unwrap();
    let usage = owner.read_quota(false).unwrap();
    assert_eq!(usage["limits"]["rateLimits"]["primary"]["usedPercent"], 20);
    busy(&s, &a);
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    let new_refresh = RefreshRequestId::Number(902);
    control.push(RuntimeEventKind::RefreshRequested {
        id: new_refresh.clone(),
        previous_account_id: None,
    });
    owner.poll_once().unwrap();
    assert_eq!(
        control.0.lock().unwrap().refreshes.len(),
        1,
        "pending identity must not receive guessed source credentials"
    );
    confirm(&mut owner, &control, attempt, "B");
    let state = control.0.lock().unwrap();
    assert_eq!(state.refreshes.len(), 2);
    assert!(state.refreshes[0].0 == old_refresh && state.refreshes[1].0 == new_refresh);
    assert_eq!(state.refreshes[0].1, "synthetic-account-A");
    assert_eq!(state.refreshes[1].1, "synthetic-account-B");
    assert!(state
        .refreshes
        .iter()
        .all(|entry| entry.2 && entry.3 > Duration::ZERO && entry.3 <= Duration::from_secs(8)));
    drop(state);
    busy(&s, &b);
    finish(&mut owner, &control);
}

#[test]
fn runtime_target_exit_closes_both_owned_clis_before_foreign_source_reacquisition() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    owner.begin_switch(second).unwrap();
    let foreign = Service::for_test(s.root.clone(), fixture("success"), Duration::from_secs(10));
    assert_eq!(
        foreign.lease_for(&a, Purpose::Task).err().unwrap().kind,
        "busy"
    );
    assert_eq!(
        foreign.lease_for(&b, Purpose::Task).err().unwrap().kind,
        "busy"
    );
    finish(&mut owner, &control);
    assert!(foreign.lease_for(&a, Purpose::Task).is_ok());
    assert!(foreign.lease_for(&b, Purpose::Task).is_ok());
    assert!(!owner.status().active_source_retained && !owner.status().pending_source_retained);
}

#[test]
fn runtime_refresh_lifecycle_transient_not_written_allows_new_id() {
    let (_root, s) = service("desktop_auth");
    let (source, provider) = managed(&s, "A");
    let (mut owner, control) = helper();
    let attempt = owner.begin_switch(provider).unwrap();
    confirm(&mut owner, &control, attempt, "A");

    control.0.lock().unwrap().next_refresh = Delivery::NotWritten;
    let first_id = RefreshRequestId::Text("synthetic-transient-refresh-1".into());
    control.push(RuntimeEventKind::RefreshRequested {
        id: first_id.clone(),
        previous_account_id: None,
    });
    let _ = owner.poll_once();
    assert_eq!(control.0.lock().unwrap().refreshes.len(), 1);
    assert!(owner.status().active_source_retained);
    assert!(!owner.status().pending_source_retained);
    busy(&s, &source);

    let next_id = RefreshRequestId::Text("synthetic-transient-refresh-2".into());
    control.push(RuntimeEventKind::RefreshRequested {
        id: next_id.clone(),
        previous_account_id: None,
    });
    owner.poll_once().unwrap();
    let state = control.0.lock().unwrap();
    assert_eq!(
        state.refreshes.len(),
        2,
        "a new refresh request must not be trapped behind a transient non-delivery"
    );
    assert!(state.refreshes[0].0 == first_id && state.refreshes[1].0 == next_id);
    assert!(state
        .refreshes
        .iter()
        .all(|entry| entry.1 == "synthetic-account-A" && entry.2));
    drop(state);
    assert_eq!(owner.status().phase, Phase::Active);
    busy(&s, &source);
    finish(&mut owner, &control);
}

#[test]
fn runtime_refresh_lifecycle_explicit_non_chatgpt_blocks_old_source() {
    for auth in [AuthFamily::LoggedOut, AuthFamily::ApiKey] {
        let (_root, s) = service("desktop_auth");
        let (source, provider) = managed(&s, "A");
        let (mut owner, control) = helper();
        let attempt = owner.begin_switch(provider).unwrap();
        confirm(&mut owner, &control, attempt, "A");
        control.push(RuntimeEventKind::AccountUpdated { auth });
        owner.poll_once().unwrap();

        control.push(RuntimeEventKind::RefreshRequested {
            id: RefreshRequestId::Number(1903),
            previous_account_id: None,
        });
        let _ = owner.poll_once();
        let state = control.0.lock().unwrap();
        assert!(
            state.refreshes.is_empty(),
            "an explicit non-ChatGPT target state must not receive the old source's credentials"
        );
        assert_eq!(
            state.logins.len(),
            1,
            "a mode notification must not trigger a login write"
        );
        drop(state);
        busy(&s, &source);
        finish(&mut owner, &control);
    }
}

#[test]
fn runtime_identity_scope_normal_mode_cannot_confirm_external_login() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGpt,
    });
    assert_eq!(owner.poll_once().unwrap().phase, Phase::Unattached);
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    let reads_before = control.0.lock().unwrap().reads.len();
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGpt,
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    let read = {
        let state = control.0.lock().unwrap();
        if state.reads.len() > reads_before {
            state.reads.last().copied()
        } else {
            None
        }
    };
    if let Some(read) = read {
        let mut observed = identity("B");
        observed.account_id = Some("synthetic-account-B".into());
        control.push(RuntimeEventKind::AccountRead {
            id: read,
            identity: observed,
        });
        owner.poll_once().unwrap();
    }
    assert!(
        owner.status().pending_source_retained,
        "normal ChatGPT mode must not confirm an external-token login"
    );
    busy(&s, &a);
    busy(&s, &b);
    finish(&mut owner, &control);
}

#[test]
fn runtime_identity_scope_present_target_account_id_must_match_source_principal() {
    let (_root, s) = service("desktop_auth");
    let (a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGptAuthTokens,
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    let mut observed = identity("B");
    observed.account_id = Some("synthetic-account-A".into());
    control.push(RuntimeEventKind::AccountRead {
        id: control.last_read(),
        identity: observed,
    });
    owner.poll_once().unwrap();
    assert!(
        owner.status().pending_source_retained,
        "a present mismatching target account ID must retain both sources"
    );
    assert_eq!(owner.status().phase, Phase::Unresolved);
    busy(&s, &a);
    busy(&s, &b);

    // The same already acknowledged attempt can reconcile with an actual
    // matching optional principal, without another credential write.
    owner.reconcile().unwrap();
    let mut matching = identity("B");
    matching.account_id = Some("synthetic-account-B".into());
    control.push(RuntimeEventKind::AccountRead {
        id: control.last_read(),
        identity: matching,
    });
    assert_eq!(owner.poll_once().unwrap().phase, Phase::Active);
    assert!(s.lease_for(&a, Purpose::Task).is_ok());
    busy(&s, &b);
    assert_eq!(control.0.lock().unwrap().logins.len(), 2);
    finish(&mut owner, &control);
}

#[test]
fn runtime_identity_scope_refresh_hint_must_match_owner_without_switching() {
    let (_root, s) = service("desktop_auth");
    let (source, provider) = managed(&s, "A");
    let (mut owner, control) = helper();
    let attempt = owner.begin_switch(provider).unwrap();
    confirm(&mut owner, &control, attempt, "A");
    control.push(RuntimeEventKind::RefreshRequested {
        id: RefreshRequestId::Number(2501),
        previous_account_id: Some("synthetic-account-B".into()),
    });
    let _ = owner.poll_once();
    assert!(
        control.0.lock().unwrap().refreshes.is_empty(),
        "a foreign previous-account hint must not receive the active source's credentials"
    );
    busy(&s, &source);
    assert_eq!(control.0.lock().unwrap().logins.len(), 1);
    assert_eq!(owner.active_source_key().unwrap().1, source);

    control.push(RuntimeEventKind::RefreshRequested {
        id: RefreshRequestId::Number(2502),
        previous_account_id: Some("synthetic-account-A".into()),
    });
    owner.poll_once().unwrap();
    control.push(RuntimeEventKind::RefreshRequested {
        id: RefreshRequestId::Number(2503),
        previous_account_id: None,
    });
    owner.poll_once().unwrap();
    let state = control.0.lock().unwrap();
    assert_eq!(state.refreshes.len(), 2);
    assert!(state
        .refreshes
        .iter()
        .all(|entry| entry.1 == "synthetic-account-A" && entry.2));
    assert_eq!(state.logins.len(), 1);
    drop(state);
    busy(&s, &source);
    finish(&mut owner, &control);
}

#[test]
fn runtime_idle_tick_retries_remaining_queued_refresh_after_transient_source_failure() {
    let root = tempfile::tempdir().unwrap();
    let cli = root.path().join("desktop_refresh_once_fail.exe");
    fs::copy(fixture("desktop_auth"), &cli).unwrap();
    let s = Service::for_test(
        root.path().join("account-profiles"),
        cli,
        Duration::from_secs(10),
    );
    let (_a, first) = managed(&s, "A");
    let (mut owner, control) = helper();
    let first_attempt = owner.begin_switch(first).unwrap();
    confirm(&mut owner, &control, first_attempt, "A");
    let (b, second) = managed(&s, "B");
    let attempt = owner.begin_switch(second).unwrap();
    let first_id = RefreshRequestId::Number(3101);
    let remaining_id = RefreshRequestId::Number(3102);
    control.push(RuntimeEventKind::RefreshRequested {
        id: first_id,
        previous_account_id: Some("synthetic-account-B".into()),
    });
    control.push(RuntimeEventKind::RefreshRequested {
        id: remaining_id.clone(),
        previous_account_id: Some("synthetic-account-B".into()),
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    assert!(control.0.lock().unwrap().refreshes.is_empty());
    control.push(RuntimeEventKind::LoginAcknowledged {
        id: attempt,
        accepted: true,
    });
    control.push(RuntimeEventKind::AccountUpdated {
        auth: AuthFamily::ChatGptAuthTokens,
    });
    owner.poll_once().unwrap();
    owner.poll_once().unwrap();
    control.push(RuntimeEventKind::AccountRead {
        id: control.last_read(),
        identity: identity("B"),
    });
    assert_eq!(
        owner.poll_once().unwrap_err().kind(),
        "rate_limited",
        "the first callback must fail through the production provider's synthetic CLI"
    );
    assert_eq!(owner.status().phase, Phase::Active);
    busy(&s, &b);
    assert!(control.0.lock().unwrap().events.is_empty());
    owner.poll_once().unwrap(); // No new event arrives to trigger the old flush path.
    let state = control.0.lock().unwrap();
    assert_eq!(
        state.refreshes.len(),
        1,
        "an idle tick must continue the remaining callback queue"
    );
    assert!(state.refreshes[0].0 == remaining_id);
    assert_eq!(state.refreshes[0].1, "synthetic-account-B");
    assert!(state.refreshes[0].2);
    drop(state);
    busy(&s, &b);
    finish(&mut owner, &control);
}
