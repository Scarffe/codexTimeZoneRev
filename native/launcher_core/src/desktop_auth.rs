//! Private managed-source credentials. Public dispatch exposes capabilities only.
//!
//! A finite native helper must retain this owner for its attached target's entire
//! lifetime. This module does not attach to a Desktop or perform an account switch.
use crate::account_sources::{self, DesktopSourceError, DesktopSourceLease};
use crate::account_usage::{self, Rpc, RpcError};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock, TryLockError, Weak,
    },
    thread,
    time::{Duration, Instant},
};

const OPERATION_BUDGET: Duration = Duration::from_secs(10);
type SourceKey = (PathBuf, String);
type ProviderResult<T> = Result<T, ProviderError>;

#[derive(Debug, Clone, Copy)]
pub(crate) enum ProviderError {
    Source(DesktopSourceError),
    Rpc(RpcError),
    Closed,
}
impl ProviderError {
    pub(crate) fn kind(self) -> &'static str {
        match self {
            Self::Source(error) => error.kind(),
            Self::Rpc(error) => error.kind(),
            Self::Closed => "closed",
        }
    }
}
impl From<DesktopSourceError> for ProviderError {
    fn from(error: DesktopSourceError) -> Self {
        Self::Source(error)
    }
}
impl From<RpcError> for ProviderError {
    fn from(error: RpcError) -> Self {
        Self::Rpc(error)
    }
}

#[derive(Clone, Copy)]
pub(crate) enum RefreshMode {
    Reuse,
    Refresh,
}

#[derive(Clone)]
pub(crate) struct ProviderObservation {
    pub email: String,
    pub plan_type: Option<String>,
}

// Intentionally no Debug, Display, Clone or Serialize implementation. The token
// is lent only to the private native consumer, never returned as application JSON.
struct PrivateCredential {
    token: String,
    account_id: String,
}
impl PrivateCredential {
    fn from_official_token(token: String) -> ProviderResult<Self> {
        let mut pieces = token.split('.');
        let header = pieces.next().ok_or(RpcError::Auth)?;
        let payload = pieces.next().ok_or(RpcError::Auth)?;
        let signature = pieces.next().ok_or(RpcError::Auth)?;
        if header.is_empty()
            || payload.is_empty()
            || signature.is_empty()
            || pieces.next().is_some()
        {
            return Err(RpcError::Auth.into());
        }
        // Trust comes from the isolated official CLI owner. Decoding its claim
        // supplies the required principal; this is not signature verification.
        let decoded = URL_SAFE_NO_PAD
            .decode(payload)
            .map_err(|_| RpcError::Auth)?;
        let claims: Value = serde_json::from_slice(&decoded).map_err(|_| RpcError::Auth)?;
        let account_id = claims["https://api.openai.com/auth"]["chatgpt_account_id"]
            .as_str()
            .filter(|id| {
                !id.trim().is_empty() && id.len() <= 1024 && !id.chars().any(char::is_control)
            })
            .ok_or(RpcError::Auth)?
            .to_owned();
        Ok(Self { token, account_id })
    }
}

struct Owner {
    // Field drop order is significant: Rpc kills and waits for its owned CLI
    // before DesktopSourceLease releases either source reservation.
    rpc: Rpc,
    _lease: DesktopSourceLease,
    observed_email: String,
    principal: Option<String>,
}

pub(crate) struct ManagedAccountProvider {
    key: SourceKey,
    cancel: Arc<AtomicBool>,
    budget: Duration,
    owner: Mutex<Option<Owner>>,
    quota_interrupt: Mutex<Option<Weak<AtomicBool>>>,
}

struct QuotaRegistration<'a> {
    provider: &'a ManagedAccountProvider,
    interrupt: Arc<AtomicBool>,
}
impl Drop for QuotaRegistration<'_> {
    fn drop(&mut self) {
        let mut registered = self
            .provider
            .quota_interrupt
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if registered
            .as_ref()
            .is_some_and(|current| std::ptr::eq(current.as_ptr(), Arc::as_ptr(&self.interrupt)))
        {
            *registered = None;
        }
    }
}

fn registry() -> &'static Mutex<HashMap<SourceKey, Weak<ManagedAccountProvider>>> {
    static PROVIDERS: OnceLock<Mutex<HashMap<SourceKey, Weak<ManagedAccountProvider>>>> =
        OnceLock::new();
    PROVIDERS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn read_chatgpt_observation(rpc: &mut Rpc) -> ProviderResult<String> {
    read_chatgpt_details(rpc).map(|observation| observation.email)
}

fn read_chatgpt_details(rpc: &mut Rpc) -> ProviderResult<ProviderObservation> {
    let value = rpc.call("account/read", json!({"refreshToken":false}))?;
    let account = &value["account"];
    if account.is_null() {
        return Err(RpcError::Auth.into());
    }
    if account["type"] != "chatgpt" {
        return Err(RpcError::Unsupported.into());
    }
    // account/read has no unique account ID. Email is an independent observation;
    // only the official token claim supplies and pins the ChatGPT principal.
    Ok(ProviderObservation {
        email: account["email"]
            .as_str()
            .ok_or(RpcError::Failed)?
            .to_owned(),
        plan_type: account["planType"].as_str().map(str::to_owned),
    })
}

impl ManagedAccountProvider {
    pub(crate) fn open(source_id: &str) -> ProviderResult<Arc<Self>> {
        Self::from_lease(
            account_sources::acquire_desktop_source(source_id)?,
            OPERATION_BUDGET,
        )
    }

    pub(crate) fn open_at(root: &Path, source_id: &str) -> ProviderResult<Arc<Self>> {
        Self::from_lease(
            account_sources::acquire_desktop_source_at(root, source_id)?,
            OPERATION_BUDGET,
        )
    }

    pub(crate) fn source_key(&self) -> (PathBuf, String) {
        self.key.clone()
    }

    pub(crate) fn from_lease(
        lease: DesktopSourceLease,
        budget: Duration,
    ) -> ProviderResult<Arc<Self>> {
        let key = lease.registry_key()?;
        let cancel = lease.cancel_signal();
        let mut rpc = lease.start_rpc(budget)?;
        rpc.restrict_errors_to_codes();
        // initialize verifies canonical codexHome and the effective file backend
        // before read_chatgpt_observation or any request for credential material.
        rpc.initialize()?;
        let observed_email = read_chatgpt_observation(&mut rpc)?;
        if cancel.load(Ordering::SeqCst) {
            return Err(RpcError::Cancelled.into());
        }
        let provider = Arc::new(Self {
            key,
            cancel,
            budget,
            quota_interrupt: Mutex::new(None),
            owner: Mutex::new(Some(Owner {
                rpc,
                _lease: lease,
                observed_email,
                principal: None,
            })),
        });
        registry()
            .lock()
            .map_err(|_| RpcError::Failed)?
            .insert(provider.key.clone(), Arc::downgrade(&provider));
        Ok(provider)
    }

    fn with_owner_budget<T>(
        &self,
        budget: Duration,
        quota_interrupt: Option<&Arc<AtomicBool>>,
        call: impl FnOnce(&mut Owner) -> ProviderResult<T>,
    ) -> ProviderResult<T> {
        let deadline = Instant::now() + budget.min(self.budget);
        let cancelled = || {
            self.cancel.load(Ordering::SeqCst)
                || quota_interrupt.is_some_and(|signal| signal.load(Ordering::SeqCst))
        };
        let mut guard = loop {
            if cancelled() {
                return Err(RpcError::Cancelled.into());
            }
            match self.owner.try_lock() {
                Ok(guard) => break guard,
                Err(TryLockError::Poisoned(_)) => return Err(RpcError::Failed.into()),
                Err(TryLockError::WouldBlock) => {
                    let remaining = deadline
                        .checked_duration_since(Instant::now())
                        .ok_or(RpcError::Timeout)?;
                    thread::sleep(remaining.min(Duration::from_millis(5)));
                }
            }
        };
        let owner = guard.as_mut().ok_or(ProviderError::Closed)?;
        if cancelled() {
            return Err(RpcError::Cancelled.into());
        }
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or(RpcError::Timeout)?;
        owner.rpc.renew_deadline(remaining)?;
        call(owner)
    }

    pub(crate) fn read_observation_with_budget(
        &self,
        budget: Duration,
    ) -> ProviderResult<ProviderObservation> {
        self.interrupt_quota();
        self.with_owner_budget(budget, None, |owner| {
            let observation = read_chatgpt_details(&mut owner.rpc)?;
            if observation.email != owner.observed_email {
                return Err(RpcError::IdentityChanged.into());
            }
            if self.cancel.load(Ordering::SeqCst) {
                return Err(RpcError::Cancelled.into());
            }
            Ok(observation)
        })
    }

    /// The consumer is trusted native code and must not reenter this provider.
    /// No credential text is returned, logged, or placed in a public response.
    pub(crate) fn consume_auth(
        &self,
        refresh: RefreshMode,
        consumer: impl FnOnce(&str, &str) -> ProviderResult<()>,
    ) -> ProviderResult<()> {
        self.consume_auth_with_budget(refresh, self.budget, consumer)
    }

    pub(crate) fn consume_auth_with_budget(
        &self,
        refresh: RefreshMode,
        budget: Duration,
        consumer: impl FnOnce(&str, &str) -> ProviderResult<()>,
    ) -> ProviderResult<()> {
        self.interrupt_quota();
        self.with_owner_budget(budget, None, |owner| {
            if read_chatgpt_observation(&mut owner.rpc)? != owner.observed_email {
                return Err(RpcError::IdentityChanged.into());
            }
            let mut status = owner.rpc.call(
                "getAuthStatus",
                json!({
                    "includeToken":true,
                    "refreshToken":matches!(refresh, RefreshMode::Refresh),
                }),
            )?;
            if status["authMethod"].is_null() {
                return Err(RpcError::Auth.into());
            }
            if status["authMethod"] != "chatgpt" {
                return Err(RpcError::Unsupported.into());
            }
            let token = match status.get_mut("authToken").map(Value::take) {
                Some(Value::String(token)) if !token.is_empty() => token,
                _ => return Err(RpcError::Auth.into()),
            };
            drop(status);
            let credential = PrivateCredential::from_official_token(token)?;
            if read_chatgpt_observation(&mut owner.rpc)? != owner.observed_email
                || owner
                    .principal
                    .as_ref()
                    .is_some_and(|id| id != &credential.account_id)
            {
                return Err(RpcError::IdentityChanged.into());
            }
            if self.cancel.load(Ordering::SeqCst) {
                return Err(RpcError::Cancelled.into());
            }
            owner.principal = Some(credential.account_id.clone());
            // Cancellation/close must take the same owner mutex after raising
            // the signal. Neither can complete ahead of an accepted consumer.
            consumer(&credential.token, &credential.account_id)
        })
    }

    pub(crate) fn read_quota(&self, details: bool) -> ProviderResult<Value> {
        self.read_quota_with_budget(details, self.budget)
    }

    pub(crate) fn read_quota_with_budget(
        &self,
        details: bool,
        budget: Duration,
    ) -> ProviderResult<Value> {
        let interrupt = self.prepare_quota();
        self.read_quota_interruptible(details, budget, interrupt)
    }

    /// Register before spawning a quota worker, so an intervening auth request
    /// can interrupt it even if that worker has not acquired the RPC lock yet.
    pub(crate) fn prepare_quota(&self) -> Arc<AtomicBool> {
        let interrupt = Arc::new(AtomicBool::new(false));
        let mut registered = self
            .quota_interrupt
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(previous) = registered.as_ref().and_then(Weak::upgrade) {
            previous.store(true, Ordering::SeqCst);
        }
        *registered = Some(Arc::downgrade(&interrupt));
        interrupt
    }

    pub(crate) fn interrupt_quota(&self) {
        if let Some(interrupt) = self
            .quota_interrupt
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_ref()
            .and_then(Weak::upgrade)
        {
            interrupt.store(true, Ordering::SeqCst);
        }
    }

    pub(crate) fn read_quota_interruptible(
        &self,
        details: bool,
        budget: Duration,
        interrupt: Arc<AtomicBool>,
    ) -> ProviderResult<Value> {
        let registration = QuotaRegistration {
            provider: self,
            interrupt,
        };
        self.with_owner_budget(budget, Some(&registration.interrupt), |owner| {
            let observed_email = &owner.observed_email;
            owner
                .rpc
                .with_wait_interrupt(registration.interrupt.clone(), |rpc| {
                    let value = account_usage::read_initialized_typed(rpc, details)?;
                    if value["account"]["email"].as_str() != Some(observed_email.as_str()) {
                        return Err(RpcError::IdentityChanged.into());
                    }
                    if self.cancel.load(Ordering::SeqCst)
                        || registration.interrupt.load(Ordering::SeqCst)
                    {
                        return Err(RpcError::Cancelled.into());
                    }
                    Ok(value)
                })
        })
    }

    pub(crate) fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        // After this gate completes, no later consumer can start. Reservation
        // release is deliberately reserved for close/Drop after child cleanup.
        drop(self.owner.lock().unwrap_or_else(|error| error.into_inner()));
    }

    fn unregister(&self) {
        let mut entries = registry().lock().unwrap_or_else(|error| error.into_inner());
        if entries
            .get(&self.key)
            .is_some_and(|entry| std::ptr::eq(entry.as_ptr(), self))
        {
            entries.remove(&self.key);
        }
    }

    pub(crate) fn close(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        let mut owner = self.owner.lock().unwrap_or_else(|error| error.into_inner());
        self.unregister();
        drop(owner.take());
    }
}
impl Drop for ManagedAccountProvider {
    fn drop(&mut self) {
        self.close();
    }
}

/// This registry shares an owner only inside its native process. GUI-to-helper
/// quota routing remains a separate IPC integration step.
pub(crate) fn usage_for_source(root: &Path, source_id: &str) -> Option<ProviderResult<Value>> {
    let key = (std::fs::canonicalize(root).ok()?, source_id.to_owned());
    let provider = {
        let mut entries = match registry().lock() {
            Ok(entries) => entries,
            Err(_) => return Some(Err(RpcError::Failed.into())),
        };
        let provider = entries.get(&key)?.upgrade();
        if provider.is_none() {
            entries.remove(&key);
        }
        provider?
    };
    Some(provider.read_quota(false))
}

pub(crate) fn capabilities() -> Value {
    json!({"privateSourceAuthSupported":true,"actualSwitchEnabled":cfg!(windows),"desktopAttachmentImplemented":cfg!(windows)})
}
