//! Finite helper host for the pinned existing Desktop runtime.
use crate::{
    account_sources,
    desktop_auth::{ManagedAccountProvider, ProviderError},
    helper_control::{ControlAction, ControlRequest, ControlServer, TargetReservation},
    runtime_helper::{Phase, RuntimeOwner, RuntimeTransport},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, TryRecvError},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TargetIdentity {
    pub pid: u32,
    pub creation_file_time: u64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HostConfig {
    pub target: TargetIdentity,
    // Nonsecret bounded hex namespace, not a bearer credential or bypass token.
    pub control_label: String,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum HostError {
    Unsupported,
    InvalidRequest,
    InvalidTarget,
    SourceBusy,
    Isolation,
    TargetExited,
    Unavailable,
    Timeout,
}
impl HostError {
    pub(crate) fn kind(self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::InvalidRequest => "invalid_request",
            Self::InvalidTarget => "invalid_target",
            Self::SourceBusy => "owner_busy",
            Self::Isolation => "isolation_failed",
            Self::TargetExited => "target_exited",
            Self::Unavailable => "unavailable",
            Self::Timeout => "timeout",
        }
    }
}

/// Acceptance of PID/time alone never authorizes attachment. The concrete
/// production factory must validate the pinned image/module and v2 channel.
pub(crate) trait RuntimeTransportFactory {
    fn connect(&self, target: TargetIdentity) -> Result<Box<dyn RuntimeTransport>, HostError>;
}
pub(crate) struct ProductionTransportFactory;
impl RuntimeTransportFactory for ProductionTransportFactory {
    fn connect(&self, target: TargetIdentity) -> Result<Box<dyn RuntimeTransport>, HostError> {
        crate::desktop_runtime_transport::connect(target)
    }
}

fn valid_config(config: &HostConfig) -> bool {
    config.target.pid != 0
        && config.target.creation_file_time != 0
        && (16..=64).contains(&config.control_label.len())
        && config
            .control_label
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
}

fn success(id: u64, data: Value) -> Value {
    json!({"version":1,"requestId":id,"ok":true,"data":data})
}
fn failure(id: u64, kind: &'static str) -> Value {
    json!({"version":1,"requestId":id,"ok":false,"error":{"kind":kind}})
}

fn phase_name(phase: Phase) -> &'static str {
    match phase {
        Phase::Unattached => "unattached",
        Phase::AwaitingConfirmation => "awaiting_confirmation",
        Phase::Active => "active",
        Phase::Unresolved => "unresolved",
        Phase::TargetExited => "target_exited",
    }
}

fn status(owner: &RuntimeOwner, preparing: bool, error: Option<&'static str>) -> Value {
    let status = owner.status();
    let source = owner.active_source_key();
    json!({
        "phase":phase_name(status.phase),"preparing":preparing,
        "activeSourceRetained":status.active_source_retained,"pendingSourceRetained":status.pending_source_retained,
        "sourceId":source.as_ref().map(|(_,id)|id),"profilesRoot":source.as_ref().map(|(root,_)|root),
        "errorKind":error,
    })
}

// Compare only the explicit canonical key or its ordinary Windows spelling.
// No filesystem lookup/UNC traversal can block the refresh loop for a quota
// request. Status provides the authoritative canonical key to reconnecting UI.
fn root_key(path: &Path) -> Option<String> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        return None;
    }
    let text = path.to_str()?.replace('/', "\\");
    let text = if let Some(unc) = text.strip_prefix("\\\\?\\UNC\\") {
        format!("\\\\{unc}")
    } else {
        text.strip_prefix("\\\\?\\").unwrap_or(&text).to_owned()
    };
    Some(text.trim_end_matches('\\').to_owned())
}

struct Preparation {
    cancel: Arc<AtomicBool>,
    lease_cancel: Arc<Mutex<Option<Arc<AtomicBool>>>>,
    output: Receiver<Result<Arc<ManagedAccountProvider>, ProviderError>>,
    thread: Option<JoinHandle<()>>,
}

struct PendingQuota {
    request_id: u64,
    source_id: String,
    profiles_root: PathBuf,
    active_root: PathBuf,
    read: crate::runtime_helper::QuotaRead,
}
impl Preparation {
    fn start(root: PathBuf, source: String) -> Self {
        let cancel = Arc::new(AtomicBool::new(false));
        let lease_cancel = Arc::new(Mutex::new(None));
        let worker_cancel = cancel.clone();
        let worker_slot = lease_cancel.clone();
        let (sender, output) = mpsc::sync_channel(1);
        let thread = thread::spawn(move || {
            let result = (|| {
                if worker_cancel.load(Ordering::SeqCst) {
                    return Err(crate::account_usage::RpcError::Cancelled.into());
                }
                let lease = account_sources::acquire_desktop_source_at(&root, &source)?;
                let signal = lease.cancel_signal();
                *worker_slot
                    .lock()
                    .unwrap_or_else(|error| error.into_inner()) = Some(signal.clone());
                if worker_cancel.load(Ordering::SeqCst) {
                    signal.store(true, Ordering::SeqCst);
                    return Err(crate::account_usage::RpcError::Cancelled.into());
                }
                let provider = ManagedAccountProvider::from_lease(lease, Duration::from_secs(10))?;
                if worker_cancel.load(Ordering::SeqCst) {
                    provider.close();
                    return Err(crate::account_usage::RpcError::Cancelled.into());
                }
                Ok(provider)
            })();
            // Receiver loss drops the unused result and its owned provider.
            let _ = sender.send(result);
        });
        Self {
            cancel,
            lease_cancel,
            output,
            thread: Some(thread),
        }
    }
    fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
        if let Some(signal) = self
            .lease_cancel
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_ref()
        {
            signal.store(true, Ordering::SeqCst);
        }
    }
    fn join(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
    fn close_unused(mut self) {
        self.cancel();
        self.join();
        if let Ok(Ok(provider)) = self.output.try_recv() {
            provider.close();
        }
    }
}

pub(crate) fn run_with_factory(
    config: HostConfig,
    factory: &dyn RuntimeTransportFactory,
) -> Result<(), HostError> {
    if !valid_config(&config) {
        return Err(HostError::InvalidRequest);
    }
    // Reserve first: a second owner must not even connect/Stop another bridge.
    let _target_owner = TargetReservation::acquire(config.target)?;
    let transport = factory.connect(config.target)?;
    if !transport.target_alive() {
        return Err(HostError::TargetExited);
    }
    let mut server = ControlServer::bind(&config)?;
    let mut owner = RuntimeOwner::new(transport, config.target.creation_file_time);
    let mut preparing: Option<Preparation> = None;
    let mut quota: Option<PendingQuota> = None;
    let mut last_error = None;
    loop {
        // Runtime refresh/account metadata always runs before a GUI operation.
        if let Err(error) = owner.poll_once() {
            last_error = Some(error.kind());
        }
        if owner.status().phase == Phase::TargetExited {
            if let Some(preparation) = preparing.take() {
                preparation.close_unused();
            }
            return Ok(());
        }
        let prepared = if let Some(preparation) = preparing.as_ref() {
            match preparation.output.try_recv() {
                Ok(result) => Some(result),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => {
                    Some(Err(crate::account_usage::RpcError::Failed.into()))
                }
            }
        } else {
            None
        };
        if let Some(result) = prepared {
            let mut preparation = preparing.take().unwrap();
            preparation.join();
            match result {
                Ok(provider) if !preparation.cancel.load(Ordering::SeqCst) => {
                    let unused = provider.clone();
                    match owner.begin_switch(provider) {
                        Ok(_) => last_error = None,
                        Err(error) => {
                            unused.close();
                            last_error = Some(error.kind());
                        }
                    }
                }
                Ok(provider) => {
                    provider.close();
                    last_error = Some("cancelled");
                }
                Err(error) => last_error = Some(error.kind()),
            }
        }
        if let Some(pending) = quota.as_mut() {
            let same_source = owner
                .active_source_key()
                .is_some_and(|(root, id)| root == pending.active_root && id == pending.source_id);
            let result = if !same_source {
                Some(Err(crate::runtime_helper::HelperError::SourceMismatch))
            } else if owner.status().phase != Phase::Active {
                Some(Err(crate::runtime_helper::HelperError::Busy))
            } else {
                pending.read.poll()
            };
            if let Some(result) = result {
                let pending = quota.take().unwrap();
                let reply = match result {
                    Ok(usage) => success(
                        pending.request_id,
                        json!({"sourceId":pending.source_id,"profilesRoot":pending.profiles_root,"usage":usage}),
                    ),
                    Err(error) => failure(pending.request_id, error.kind()),
                };
                // Cancellation/join affects this quota read only.
                drop(pending.read);
                if let Err(error) = server.respond(&reply) {
                    last_error = Some(error.kind());
                }
                owner.gui_detached();
            }
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        let request = match server.poll() {
            Ok(request) => request,
            Err(error) => {
                // A malformed or disconnected GUI cannot abandon refresh.
                let _ = server.respond(&failure(0, error.kind()));
                None
            }
        };
        if let Some(ControlRequest {
            version,
            request_id,
            action,
        }) = request
        {
            let mut stop_after_reply = false;
            let reply = if version != 1 {
                failure(request_id, "invalid_request")
            } else {
                match action {
                    ControlAction::Status => {
                        success(request_id, status(&owner, preparing.is_some(), last_error))
                    }
                    ControlAction::Live => success(request_id, owner.live_snapshot()),
                    ControlAction::Reconcile => match owner.reconcile() {
                        Ok(()) => {
                            success(request_id, status(&owner, preparing.is_some(), last_error))
                        }
                        Err(error) => failure(request_id, error.kind()),
                    },
                    ControlAction::StopUnowned => {
                        let owned = owner.status();
                        if preparing.is_some()
                            || owned.active_source_retained
                            || owned.pending_source_retained
                        {
                            failure(request_id, "owner_busy")
                        } else {
                            stop_after_reply = true;
                            success(request_id, json!({"state":"stopping"}))
                        }
                    }
                    ControlAction::Switch {
                        source_id,
                        profiles_root,
                    } => {
                        if preparing.is_some()
                            || owner.status().pending_source_retained
                            || owner.status().phase == Phase::Unresolved
                        {
                            failure(request_id, "busy")
                        } else if !profiles_root.is_absolute()
                            || account_sources::validate_task_source(&source_id).is_err()
                        {
                            failure(request_id, "source_invalid")
                        } else {
                            preparing = Some(Preparation::start(profiles_root, source_id));
                            last_error = None;
                            success(request_id, json!({"state":"preparing"}))
                        }
                    }
                    ControlAction::Quota {
                        source_id,
                        profiles_root,
                        details,
                    } => {
                        let expected = owner.active_source_key().filter(|(root, id)| {
                            id == &source_id
                                && root_key(root).is_some_and(|actual| {
                                    root_key(&profiles_root)
                                        .is_some_and(|requested| actual == requested)
                                })
                        });
                        if let Some((root, _)) = expected {
                            match owner.begin_quota_for_source(&root, &source_id, details) {
                                Ok(read) => match server.defer_quota_response() {
                                    Ok(()) => {
                                        quota = Some(PendingQuota {
                                            request_id,
                                            source_id,
                                            profiles_root,
                                            active_root: root,
                                            read,
                                        });
                                        thread::sleep(Duration::from_millis(10));
                                        continue;
                                    }
                                    Err(error) => failure(request_id, error.kind()),
                                },
                                Err(error) => failure(request_id, error.kind()),
                            }
                        } else {
                            failure(request_id, "source_mismatch")
                        }
                    }
                    ControlAction::Cancel => {
                        if let Some(preparation) = preparing.as_ref() {
                            preparation.cancel();
                            success(request_id, json!({"state":"cancelling_preparation"}))
                        } else {
                            match owner.cancel_switch() {
                                Ok(()) => success(request_id, status(&owner, false, last_error)),
                                Err(error) => failure(request_id, error.kind()),
                            }
                        }
                    }
                }
            };
            match server.respond(&reply) {
                Ok(()) if stop_after_reply => {
                    match server.finish_stop_reply(Instant::now() + Duration::from_secs(2)) {
                        // Returning drops the transport normally. No target
                        // process is terminated or placed into a helper Job.
                        Ok(()) => return Ok(()),
                        Err(error) => last_error = Some(error.kind()),
                    }
                }
                Ok(()) => {}
                Err(error) => last_error = Some(error.kind()),
            }
            // Each pipe transaction may be the GUI's last one. This changes no
            // provider/transport ownership and never terminates the host loop.
            owner.gui_detached();
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// A hidden Rust entrypoint wrapper in lib.rs lets the separate binary reuse
/// private production modules without exporting credential functionality in FFI.
pub(crate) fn main_entry() -> i32 {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() != 6
        || args[0] != "--target-pid"
        || args[2] != "--target-created"
        || args[4] != "--control-label"
    {
        return 4;
    }
    let (Ok(pid), Ok(creation_file_time)) = (args[1].parse::<u32>(), args[3].parse::<u64>()) else {
        return 4;
    };
    let config = HostConfig {
        target: TargetIdentity {
            pid,
            creation_file_time,
        },
        control_label: args[5].clone(),
    };
    match run_with_factory(config, &ProductionTransportFactory) {
        Ok(()) => 0,
        Err(HostError::Unsupported) => 2,
        Err(HostError::SourceBusy) => 3,
        Err(HostError::InvalidRequest | HostError::InvalidTarget) => 4,
        Err(_) => 1,
    }
}
