//! Private finite helper owner/state kernel. The target bridge and helper process
//! lifecycle are separate integration steps; public switching remains disabled.
use crate::desktop_auth::{ManagedAccountProvider, ProviderError, RefreshMode};
use serde_json::Value;
use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, TryRecvError},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const SWITCH_BUDGET: Duration = Duration::from_secs(2);
const QUOTA_BUDGET: Duration = Duration::from_secs(10);
const REFRESH_BUDGET: Duration = Duration::from_secs(8);
const CONFIRMATION_WINDOW: Duration = Duration::from_secs(10);
const MAX_REFRESH_IDS: usize = 4;
const MAX_RECONCILIATION_READS: u8 = 2;

/// Quota waits off the transport loop. Its cancellation signal belongs to this
/// read only; dropping a GUI request never cancels the retained auth provider.
pub(crate) struct QuotaRead {
    cancel: Arc<AtomicBool>,
    output: Receiver<Result<Value, ProviderError>>,
    worker: Option<JoinHandle<()>>,
}
impl QuotaRead {
    fn start(provider: Arc<ManagedAccountProvider>, details: bool) -> Self {
        let cancel = provider.prepare_quota();
        let signal = cancel.clone();
        let (sender, output) = mpsc::sync_channel(1);
        let worker = thread::spawn(move || {
            let result = provider.read_quota_interruptible(details, QUOTA_BUDGET, signal);
            let _ = sender.send(result);
        });
        Self {
            cancel,
            output,
            worker: Some(worker),
        }
    }
    pub(crate) fn poll(&mut self) -> Option<Result<Value, HelperError>> {
        match self.output.try_recv() {
            Ok(result) => Some(result.map_err(HelperError::Source)),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => Some(Err(HelperError::Source(
                crate::account_usage::RpcError::Failed.into(),
            ))),
        }
    }
}
impl Drop for QuotaRead {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CorrelationId(pub u64);

// Preserve the protocol's typed refresh ID. No bearer values are stored here.
#[derive(Clone, PartialEq, Eq)]
pub(crate) enum RefreshRequestId {
    Number(i64),
    Text(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AuthFamily {
    ChatGpt,
    ChatGptAuthTokens,
    ApiKey,
    LoggedOut,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct ObservedIdentity {
    pub auth: AuthFamily,
    pub email: Option<String>,
    pub plan_type: Option<String>,
    // Private optional workspaceRouting.chatgptAccountId from an actual target
    // account/read. None remains observation-only, not unique-principal proof.
    pub account_id: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Delivery {
    NotWritten,
    Written,
    Unknown,
}

#[derive(Clone, Copy)]
pub(crate) struct WriteReceipt {
    pub delivery: Delivery,
    // Observer sequence already seen before the write. Queued older notices
    // cannot serve as evidence for this attempt.
    pub observed_through: u64,
}

pub(crate) struct RuntimeEvent {
    pub sequence: u64,
    pub kind: RuntimeEventKind,
}
pub(crate) enum RuntimeEventKind {
    LoginAcknowledged {
        id: CorrelationId,
        accepted: bool,
    },
    AccountUpdated {
        auth: AuthFamily,
    },
    AccountRead {
        id: CorrelationId,
        identity: ObservedIdentity,
    },
    RefreshRequested {
        id: RefreshRequestId,
        previous_account_id: Option<String>,
    },
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum TransportError {
    Unsupported,
    Unavailable,
    TargetExited,
}

/// Implemented only by the bridge bound to the already validated exact target.
/// There is deliberately no kill, logout, arbitrary PID, token-read or model API.
pub(crate) trait RuntimeTransport: Send {
    fn metadata_supported(&self) -> bool {
        false
    }
    fn write_metadata(
        &mut self,
        _request: &crate::runtime_bootstrap::MetadataRequest,
        _deadline: Instant,
    ) -> Delivery {
        Delivery::NotWritten
    }
    fn poll_metadata(
        &mut self,
    ) -> Result<Option<crate::runtime_bootstrap::MetadataEvent>, TransportError> {
        Ok(None)
    }
    fn write_login(
        &mut self,
        id: CorrelationId,
        token: &str,
        account_id: &str,
        plan_type: Option<&str>,
        deadline: Instant,
    ) -> WriteReceipt;
    fn write_refresh_response(
        &mut self,
        id: &RefreshRequestId,
        token: &str,
        account_id: &str,
        plan_type: Option<&str>,
        deadline: Instant,
    ) -> Delivery;
    // The bridge emits only account/read {refreshToken:false} for this method.
    fn request_account_read(
        &mut self,
        id: CorrelationId,
        deadline: Instant,
    ) -> Result<(), TransportError>;
    fn poll_event(&mut self) -> Result<Option<RuntimeEvent>, TransportError>;
    fn target_alive(&self) -> bool;
    fn poll_live(
        &mut self,
    ) -> Result<(Option<crate::global_live::LiveEvent>, u32), TransportError> {
        Ok((None, 0))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    Unattached,
    AwaitingConfirmation,
    Active,
    Unresolved,
    TargetExited,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct HelperStatus {
    pub phase: Phase,
    pub gui_attached: bool,
    pub active_source_retained: bool,
    pub pending_source_retained: bool,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum HelperError {
    Unsupported,
    Busy,
    DeliveryNotWritten,
    DeliveryUnresolved,
    NoActiveSource,
    SourceMismatch,
    Source(ProviderError),
    Transport(TransportError),
}
impl HelperError {
    pub(crate) fn kind(self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::Busy => "busy",
            Self::DeliveryNotWritten => "not_written",
            Self::DeliveryUnresolved => "delivery_unresolved",
            Self::NoActiveSource => "no_active_source",
            Self::SourceMismatch => "source_mismatch",
            Self::Source(error) => error.kind(),
            Self::Transport(TransportError::Unsupported) => "unsupported",
            Self::Transport(TransportError::Unavailable) => "transport_unavailable",
            Self::Transport(TransportError::TargetExited) => "target_exited",
        }
    }
}

pub(crate) struct RuntimeOwner {
    transport: Box<dyn RuntimeTransport>,
    next_id: u64,
    phase: Phase,
    gui_attached: bool,
    active: Option<Arc<ManagedAccountProvider>>,
    active_principal: Option<String>,
    pending: Option<PendingSwitch>,
    queued_refresh: VecDeque<(RefreshRequestId, Option<String>, Instant)>,
    answered_refresh: VecDeque<RefreshRequestId>,
    confirmed_auth_revision: u64,
    last_sequence: u64,
    live: crate::global_live::LiveStore,
    bootstrap: crate::runtime_bootstrap::Bootstrap,
    started: Instant,
}
struct PendingSwitch {
    provider: Arc<ManagedAccountProvider>,
    expected: ObservedIdentity,
    expected_principal: String,
    id: CorrelationId,
    after_sequence: u64,
    ack_sequence: Option<u64>,
    update_sequence: Option<u64>,
    read: Option<(CorrelationId, u64)>,
    rejected: bool,
    reconciliation_reads: u8,
    proof_deadline: Instant,
}
impl RuntimeOwner {
    // Namespace belongs to this finite helper's validated attachment generation.
    // The real bridge serializes helper-owned correlation IDs in its reserved
    // namespace, preserving unrelated Desktop request IDs.
    pub(crate) fn new(transport: Box<dyn RuntimeTransport>, namespace: u64) -> Self {
        let bootstrap = crate::runtime_bootstrap::Bootstrap::new(transport.metadata_supported());
        Self {
            transport,
            next_id: namespace,
            phase: Phase::Unattached,
            gui_attached: true,
            active: None,
            active_principal: None,
            pending: None,
            queued_refresh: VecDeque::new(),
            answered_refresh: VecDeque::new(),
            confirmed_auth_revision: 0,
            last_sequence: 0,
            live: crate::global_live::LiveStore::default(),
            bootstrap,
            started: Instant::now(),
        }
    }

    fn correlation(&mut self) -> Result<CorrelationId, HelperError> {
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or(HelperError::Unsupported)?;
        Ok(CorrelationId(self.next_id))
    }

    pub(crate) fn confirmed_auth_revision(&self) -> u64 {
        self.confirmed_auth_revision
    }

    fn remaining(deadline: Instant) -> Result<Duration, HelperError> {
        deadline
            .checked_duration_since(Instant::now())
            .filter(|budget| !budget.is_zero())
            .ok_or(HelperError::Source(
                crate::account_usage::RpcError::Timeout.into(),
            ))
    }

    fn target_exited(&mut self) {
        if let Some(pending) = self.pending.take() {
            pending.provider.close();
        }
        if let Some(active) = self.active.take() {
            active.close();
        }
        self.active_principal = None;
        self.queued_refresh.clear();
        self.answered_refresh.clear();
        self.phase = Phase::TargetExited;
    }

    /// The caller must prepare this provider outside the owner's serial loop.
    /// ACL checks/CLI startup are not covered by the short transaction budget.
    pub(crate) fn begin_switch(
        &mut self,
        candidate: Arc<ManagedAccountProvider>,
    ) -> Result<CorrelationId, HelperError> {
        if self.phase == Phase::TargetExited || !self.transport.target_alive() {
            self.target_exited();
            candidate.close();
            return Err(HelperError::Transport(TransportError::TargetExited));
        }
        if self.pending.is_some()
            || self.phase == Phase::Unresolved
            || self
                .active
                .as_ref()
                .is_some_and(|active| Arc::ptr_eq(active, &candidate))
        {
            return Err(HelperError::Busy);
        }
        let id = self.correlation()?;
        let deadline = Instant::now() + SWITCH_BUDGET;
        let observation = match candidate.read_observation_with_budget(Self::remaining(deadline)?) {
            Ok(observation) => observation,
            Err(error) => {
                candidate.close();
                return Err(HelperError::Source(error));
            }
        };
        let expected = ObservedIdentity {
            auth: AuthFamily::ChatGpt,
            email: Some(observation.email),
            plan_type: observation.plan_type,
            account_id: None,
        };
        let mut receipt = None;
        let mut expected_principal = String::new();
        let source_result = candidate.consume_auth_with_budget(
            RefreshMode::Reuse,
            Self::remaining(deadline)?,
            |token, account_id| {
                expected_principal = account_id.to_owned();
                receipt = Some(self.transport.write_login(
                    id,
                    token,
                    account_id,
                    expected.plan_type.as_deref(),
                    deadline,
                ));
                Ok(())
            },
        );
        // A provider failure before the consumer is a proven non-delivery. Once
        // a write receipt exists, retain ownership even if later work fails.
        let Some(receipt) = receipt else {
            candidate.close();
            return Err(source_result
                .err()
                .map(HelperError::Source)
                .unwrap_or(HelperError::DeliveryNotWritten));
        };
        if receipt.delivery == Delivery::NotWritten {
            candidate.close();
            return Err(HelperError::DeliveryNotWritten);
        }
        self.pending = Some(PendingSwitch {
            provider: candidate,
            expected,
            expected_principal,
            id,
            after_sequence: receipt.observed_through.max(self.last_sequence),
            ack_sequence: None,
            update_sequence: None,
            read: None,
            rejected: false,
            reconciliation_reads: 0,
            proof_deadline: Instant::now() + CONFIRMATION_WINDOW,
        });
        self.phase = if receipt.delivery == Delivery::Written && source_result.is_ok() {
            Phase::AwaitingConfirmation
        } else {
            Phase::Unresolved
        };
        Ok(id)
    }

    fn confirmation_read(&mut self) -> Result<(), HelperError> {
        let Some(pending) = self.pending.as_ref() else {
            return Ok(());
        };
        let (Some(ack), Some(update)) = (pending.ack_sequence, pending.update_sequence) else {
            return Ok(());
        };
        if pending.rejected {
            return Ok(());
        }
        let after = ack.max(update);
        if pending.read.is_some_and(|(_, previous)| previous >= after) {
            return Ok(());
        }
        let id = self.correlation()?;
        if let Err(error) = self
            .transport
            .request_account_read(id, Instant::now() + SWITCH_BUDGET)
        {
            self.phase = Phase::Unresolved;
            return Err(HelperError::Transport(error));
        }
        self.pending.as_mut().unwrap().read = Some((id, after));
        Ok(())
    }

    fn event(&mut self, event: RuntimeEvent) -> Result<(), HelperError> {
        if event.sequence <= self.last_sequence {
            return Ok(());
        }
        self.last_sequence = event.sequence;
        match event.kind {
            RuntimeEventKind::LoginAcknowledged { id, accepted } => {
                if let Some(pending) = self
                    .pending
                    .as_mut()
                    .filter(|pending| pending.id == id && event.sequence > pending.after_sequence)
                {
                    if accepted && !pending.rejected {
                        pending.ack_sequence = Some(event.sequence);
                    } else {
                        pending.rejected = true;
                        self.phase = Phase::Unresolved;
                    }
                    self.confirmation_read()?;
                }
            }
            RuntimeEventKind::AccountUpdated { auth } => {
                if let Some(pending) = self
                    .pending
                    .as_mut()
                    .filter(|pending| event.sequence > pending.after_sequence)
                {
                    if auth == AuthFamily::ChatGptAuthTokens {
                        pending.update_sequence = Some(event.sequence);
                    } else {
                        pending.update_sequence = None;
                        pending.read = None;
                        self.phase = Phase::Unresolved;
                    }
                    self.confirmation_read()?;
                } else if self.pending.is_none()
                    && auth != AuthFamily::ChatGptAuthTokens
                    && self.active.is_some()
                {
                    // The target explicitly left this authentication family.
                    // Keep ownership, but do not restore the old source through
                    // a later callback or an uncorrelated ChatGPT notification.
                    self.queued_refresh.clear();
                    self.phase = Phase::Unresolved;
                }
            }
            RuntimeEventKind::AccountRead { id, identity } => {
                let confirmed = if let Some(pending) = self.pending.as_mut() {
                    if let Some((expected_id, after)) = pending.read {
                        if id != expected_id || event.sequence <= after {
                            return Ok(());
                        }
                        pending.read = None;
                        !pending.rejected && pending.ack_sequence.is_some() && pending.update_sequence.is_some()
                            && identity.auth == pending.expected.auth
                            && identity.email == pending.expected.email
                            && identity.plan_type == pending.expected.plan_type
                            // A missing experimental target ID remains an
                            // observation-only match. A present ID must agree
                            // with the privately pinned official source claim.
                            && identity.account_id.as_deref().is_none_or(|id| id == pending.expected_principal.as_str())
                    } else {
                        return Ok(());
                    }
                } else {
                    return Ok(());
                };
                if confirmed {
                    let pending = self.pending.take().unwrap();
                    self.active_principal = Some(pending.expected_principal);
                    if let Some(previous) = self.active.replace(pending.provider) {
                        previous.close();
                    }
                    self.phase = Phase::Active;
                    self.confirmed_auth_revision = self.confirmed_auth_revision.wrapping_add(1);
                    self.flush_refresh()?;
                } else {
                    self.phase = Phase::Unresolved;
                }
            }
            RuntimeEventKind::RefreshRequested {
                id,
                previous_account_id,
            } => {
                let valid = match &id {
                    RefreshRequestId::Number(_) => true,
                    RefreshRequestId::Text(text) => {
                        !text.is_empty() && text.len() <= 128 && !text.chars().any(char::is_control)
                    }
                };
                if !valid {
                    self.phase = Phase::Unresolved;
                    return Err(HelperError::Unsupported);
                }
                if self.answered_refresh.contains(&id)
                    || self
                        .queued_refresh
                        .iter()
                        .any(|(queued, _, _)| queued == &id)
                {
                    return Ok(());
                }
                if self.queued_refresh.len() >= MAX_REFRESH_IDS {
                    self.phase = Phase::Unresolved;
                    return Err(HelperError::DeliveryUnresolved);
                }
                self.queued_refresh.push_back((
                    id,
                    previous_account_id,
                    Instant::now() + REFRESH_BUDGET,
                ));
                self.flush_refresh()?;
            }
        }
        Ok(())
    }

    fn flush_refresh(&mut self) -> Result<(), HelperError> {
        if self.pending.is_some() || self.phase != Phase::Active {
            return Ok(());
        }
        let Some(provider) = self.active.clone() else {
            return Ok(());
        };
        while let Some((id, previous_account_id, deadline)) = self.queued_refresh.pop_front() {
            if previous_account_id
                .as_deref()
                .is_some_and(|hint| self.active_principal.as_deref() != Some(hint))
            {
                // This hint scopes this callback only. Do not refresh a foreign
                // source, switch implicitly, or poison later correctly scoped
                // callbacks for the still-confirmed active owner.
                return Err(HelperError::SourceMismatch);
            }
            let remaining = match Self::remaining(deadline) {
                Ok(remaining) => remaining,
                // Nothing was delivered. A later fresh request has a new
                // deadline and may use the still-confirmed active source.
                Err(error) => return Err(error),
            };
            let observation = match provider.read_observation_with_budget(remaining) {
                Ok(observation) => observation,
                Err(error) => {
                    if !matches!(
                        error,
                        ProviderError::Rpc(
                            crate::account_usage::RpcError::Failed
                                | crate::account_usage::RpcError::Timeout
                                | crate::account_usage::RpcError::RateLimited
                        )
                    ) {
                        self.phase = Phase::Unresolved;
                    }
                    return Err(HelperError::Source(error));
                }
            };
            let mut delivery = None;
            let result = provider.consume_auth_with_budget(
                RefreshMode::Refresh,
                Self::remaining(deadline)?,
                |token, account_id| {
                    delivery = Some(self.transport.write_refresh_response(
                        &id,
                        token,
                        account_id,
                        observation.plan_type.as_deref(),
                        deadline,
                    ));
                    Ok(())
                },
            );
            // An unknown response delivery cannot be replayed blindly.
            if delivery.is_some() {
                self.answered_refresh.push_back(id);
                if self.answered_refresh.len() > MAX_REFRESH_IDS {
                    self.answered_refresh.pop_front();
                }
            }
            if let Err(error) = result {
                if delivery.is_some()
                    || !matches!(
                        error,
                        ProviderError::Rpc(
                            crate::account_usage::RpcError::Failed
                                | crate::account_usage::RpcError::Timeout
                                | crate::account_usage::RpcError::RateLimited
                        )
                    )
                {
                    self.phase = Phase::Unresolved;
                }
                return Err(HelperError::Source(error));
            }
            match delivery {
                Some(Delivery::Written) => {
                    self.confirmed_auth_revision = self.confirmed_auth_revision.wrapping_add(1);
                }
                Some(Delivery::NotWritten) => return Err(HelperError::DeliveryNotWritten),
                _ => {
                    self.phase = Phase::Unresolved;
                    return Err(HelperError::DeliveryUnresolved);
                }
            }
        }
        Ok(())
    }

    pub(crate) fn poll_once(&mut self) -> Result<HelperStatus, HelperError> {
        if self.phase == Phase::TargetExited {
            return Ok(self.status());
        }
        if !self.transport.target_alive() {
            self.target_exited();
            return Ok(self.status());
        }
        // Live-only overflow never changes authentication ownership or causes a
        // credential write. Drain its small independent queue on every tick.
        for _ in 0..16 {
            match self.transport.poll_live() {
                Ok((event, dropped)) => {
                    let empty = event.is_none();
                    if let Some(event) = event {
                        self.live.apply(event);
                    }
                    self.live.gap(dropped);
                    if empty {
                        break;
                    }
                }
                Err(_) => {
                    self.live.invalidate();
                    break;
                }
            }
        }
        match self.transport.poll_event() {
            Ok(Some(event)) => self.event(event)?,
            // A transient failure in one callback must not strand the bounded
            // remainder until another transport event happens to arrive.
            Ok(None) => self.flush_refresh()?,
            Err(error) => {
                if !self.transport.target_alive() {
                    self.target_exited();
                    return Ok(self.status());
                }
                self.phase = Phase::Unresolved;
                return Err(HelperError::Transport(error));
            }
        }
        if self.phase == Phase::AwaitingConfirmation
            && self
                .pending
                .as_ref()
                .is_some_and(|pending| Instant::now() >= pending.proof_deadline)
        {
            self.phase = Phase::Unresolved;
        }
        self.metadata_tick();
        Ok(self.status())
    }

    fn metadata_tick(&mut self) {
        if !self.transport.metadata_supported() {
            return;
        }
        for _ in 0..16 {
            match self.transport.poll_metadata() {
                Ok(Some(event)) => {
                    if let Some(snapshot) = self.bootstrap.received(event) {
                        self.live.apply_snapshot(snapshot);
                    }
                }
                Ok(None) => break,
                Err(_) => {
                    self.bootstrap.failed(Delivery::Unknown);
                    self.live.invalidate();
                    return;
                }
            }
        }
        // Authentication owns the next opportunity whenever confirmation or
        // refresh is pending. Metadata reads never change that ownership.
        if self.pending.is_some()
            || !self.queued_refresh.is_empty()
            || matches!(self.phase, Phase::Unresolved | Phase::TargetExited)
        {
            return;
        }
        let Ok(id) = self.correlation() else {
            return;
        };
        if let Some(request) = self.bootstrap.next(
            id,
            self.live.watermark(),
            self.started.elapsed().as_millis() as u64,
        ) {
            let delivery = self
                .transport
                .write_metadata(&request, Instant::now() + Duration::from_millis(250));
            if delivery != Delivery::Written {
                self.bootstrap.failed(delivery);
                self.live.invalidate();
            }
        }
    }

    pub(crate) fn reconcile(&mut self) -> Result<(), HelperError> {
        if !self.transport.target_alive() {
            self.target_exited();
            return Err(HelperError::Transport(TransportError::TargetExited));
        }
        let pending = self
            .pending
            .as_ref()
            .ok_or(HelperError::DeliveryUnresolved)?;
        if pending.reconciliation_reads >= MAX_RECONCILIATION_READS {
            return Err(HelperError::DeliveryUnresolved);
        }
        let after = pending
            .ack_sequence
            .unwrap_or(pending.after_sequence)
            .max(pending.update_sequence.unwrap_or(pending.after_sequence));
        let id = self.correlation()?;
        self.pending.as_mut().unwrap().reconciliation_reads += 1;
        if let Err(error) = self
            .transport
            .request_account_read(id, Instant::now() + SWITCH_BUDGET)
        {
            self.phase = Phase::Unresolved;
            return Err(HelperError::Transport(error));
        }
        self.pending.as_mut().unwrap().read = Some((id, after));
        Ok(())
    }

    pub(crate) fn cancel_switch(&mut self) -> Result<(), HelperError> {
        if self.pending.is_some() {
            self.phase = Phase::Unresolved;
            return Err(HelperError::DeliveryUnresolved);
        }
        Ok(())
    }

    pub(crate) fn gui_detached(&mut self) {
        self.gui_attached = false;
    }
    pub(crate) fn live_snapshot(&self) -> Value {
        self.live
            .snapshot(self.phase != Phase::TargetExited && self.transport.target_alive())
    }

    pub(crate) fn active_source_key(&self) -> Option<(std::path::PathBuf, String)> {
        self.active.as_ref().map(|provider| provider.source_key())
    }

    pub(crate) fn read_quota(&mut self, details: bool) -> Result<Value, HelperError> {
        self.read_quota_bound(None, details)
    }
    fn read_quota_bound(
        &mut self,
        expected: Option<(&std::path::Path, &str)>,
        details: bool,
    ) -> Result<Value, HelperError> {
        self.quota_provider(expected)?
            .read_quota_with_budget(details, QUOTA_BUDGET)
            .map_err(HelperError::Source)
    }
    fn quota_provider(
        &mut self,
        expected: Option<(&std::path::Path, &str)>,
    ) -> Result<Arc<ManagedAccountProvider>, HelperError> {
        // Drain a finite metadata batch before a low-priority quota command.
        for _ in 0..MAX_REFRESH_IDS * 2 {
            if !self.transport.target_alive() {
                self.target_exited();
                return Err(HelperError::Transport(TransportError::TargetExited));
            }
            match self.transport.poll_event() {
                Ok(Some(event)) => self.event(event)?,
                Ok(None) => break,
                Err(error) => {
                    self.phase = Phase::Unresolved;
                    return Err(HelperError::Transport(error));
                }
            }
        }
        // Draining a pending identity confirmation can replace the active
        // provider. Bind the actual read after that drain, not its earlier label.
        if expected.is_some_and(|(root, id)| {
            self.active_source_key()
                .as_ref()
                .is_none_or(|(actual, source)| actual != root || source != id)
        }) {
            return Err(HelperError::SourceMismatch);
        }
        if self.pending.is_some() || self.phase != Phase::Active {
            return Err(HelperError::Busy);
        }
        self.active.clone().ok_or(HelperError::NoActiveSource)
    }
    pub(crate) fn begin_quota_for_source(
        &mut self,
        root: &std::path::Path,
        source: &str,
        details: bool,
    ) -> Result<QuotaRead, HelperError> {
        Ok(QuotaRead::start(
            self.quota_provider(Some((root, source)))?,
            details,
        ))
    }
    pub(crate) fn read_quota_for_source(
        &mut self,
        root: &std::path::Path,
        source: &str,
        details: bool,
    ) -> Result<Value, HelperError> {
        self.read_quota_bound(Some((root, source)), details)
    }

    pub(crate) fn status(&self) -> HelperStatus {
        HelperStatus {
            phase: self.phase,
            gui_attached: self.gui_attached,
            active_source_retained: self.active.is_some(),
            pending_source_retained: self.pending.is_some(),
        }
    }
}
