//! Launcher client for the separate finite helper. Only metadata crosses public JSON.
use crate::{
    account_sources,
    helper_control::{self, ControlAction, ControlRequest},
    helper_host::{HostConfig, HostError},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
        process::CommandExt,
    },
    path::{Component, Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use windows::{
    core::PCWSTR,
    Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT},
        Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH},
        System::Threading::{
            GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, WaitForSingleObject,
            PROCESS_NAME_FORMAT, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
        },
    },
};

const STATUS_BUDGET: Duration = Duration::from_millis(600);
const CONTROL_BUDGET: Duration = Duration::from_secs(3);
const QUOTA_CONTROL_BUDGET: Duration = Duration::from_secs(13);
const STARTUP_BUDGET: Duration = Duration::from_secs(10);
const LOCATOR_LIMIT: u64 = 16 * 1024;
static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Copy)]
pub(crate) struct RuntimeClientError {
    kind: &'static str,
}
impl RuntimeClientError {
    fn new(kind: &str) -> Self {
        let kind = match kind {
            "source_invalid" | "no_active_source" | "invalid_request" => "invalid_request",
            "startup_failed" | "invalid_target" | "unavailable" | "transport_unavailable" => {
                "unavailable"
            }
            "closed" | "shutdown" => "shutdown",
            "unsupported" => "unsupported",
            "timeout" => "timeout",
            "owner_busy" => "owner_busy",
            "source_busy" | "busy" => "busy",
            "source_mismatch" => "source_mismatch",
            "auth_required" => "auth_required",
            "auth_failed" => "auth_failed",
            "cancelled" => "cancelled",
            "rate_limited" => "rate_limited",
            "identity_changed" => "identity_changed",
            "isolation_failed" => "isolation_failed",
            "cli_changed" => "cli_changed",
            "network" => "network",
            "not_written" => "not_written",
            "delivery_unresolved" => "delivery_unresolved",
            "target_exited" => "target_exited",
            "not_connected" => "not_connected",
            "locator_invalid" => "locator_invalid",
            "locator_unverifiable" => "locator_unverifiable",
            "helper_starting" => "helper_starting",
            "helper_exited" => "helper_exited",
            _ => "unavailable",
        };
        Self { kind }
    }
    pub(crate) fn kind(self) -> &'static str {
        self.kind
    }
}
impl From<HostError> for RuntimeClientError {
    fn from(error: HostError) -> Self {
        Self::new(error.kind())
    }
}
type ClientResult<T> = Result<T, RuntimeClientError>;

// Noncredential metadata only. Never add token/account-principal fields.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Locator {
    pub version: u32,
    pub helper_pid: u32,
    pub helper_creation_file_time: u64,
    pub helper_exe: PathBuf,
    pub config: HostConfig,
}
#[derive(Clone)]
struct CachedStatus {
    locator: Locator,
    data: Value,
}
pub(crate) struct RuntimeClient {
    locator_file: PathBuf,
    candidate_directory: PathBuf,
    cached: Mutex<Option<CachedStatus>>,
}

fn snapshot(supported: bool, phase: &'static str, error: Option<RuntimeClientError>) -> Value {
    json!({"runtimeVersion":1,"supported":supported,"connected":false,"phase":phase,
        "preparing":false,"sourceId":null,"errorKind":error.map(|error|error.kind()),
        "activeSourceRetained":false,"pendingSourceRetained":false,
        "modelAttributionVerified":false,"inFlightMayUsePrevious":true})
}
fn normalized(path: &Path) -> Option<String> {
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
fn same_path(first: &Path, second: &Path) -> bool {
    normalized(first)
        .zip(normalized(second))
        .is_some_and(|(first, second)| first.eq_ignore_ascii_case(&second))
}
fn same_source_path(first: &Path, second: &Path) -> bool {
    normalized(first)
        .zip(normalized(second))
        .is_some_and(|(first, second)| first == second)
}
fn same_locator(first: &Locator, second: &Locator) -> bool {
    first.helper_pid == second.helper_pid
        && first.helper_creation_file_time == second.helper_creation_file_time
        && same_path(&first.helper_exe, &second.helper_exe)
        && first.config.target.pid == second.config.target.pid
        && first.config.target.creation_file_time == second.config.target.creation_file_time
        && first
            .config
            .control_label
            .eq_ignore_ascii_case(&second.config.control_label)
}
fn config_valid(config: &HostConfig) -> bool {
    config.target.pid != 0
        && config.target.creation_file_time != 0
        && (16..=64).contains(&config.control_label.len())
        && config
            .control_label
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
}
fn plain_path(path: &Path) -> ClientResult<()> {
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata)
                if metadata.file_attributes() & 0x400 != 0 || metadata.file_type().is_symlink() =>
            {
                return Err(RuntimeClientError::new("isolation_failed"))
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(RuntimeClientError::new("unavailable")),
        }
    }
    Ok(())
}
fn creation(handle: HANDLE) -> ClientResult<u64> {
    let (mut created, mut exited, mut kernel, mut user) = (
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
    );
    unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) }
        .map_err(|_| RuntimeClientError::new("locator_unverifiable"))?;
    Ok((u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime))
}
struct ProcessHandle(HANDLE);
impl Drop for ProcessHandle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
fn live(locator: &Locator) -> ClientResult<bool> {
    let handle = match unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            false,
            locator.helper_pid,
        )
    } {
        Ok(handle) => ProcessHandle(handle),
        Err(error) if [0x80070057u32, 0x80070490u32].contains(&(error.code().0 as u32)) => {
            return Ok(false)
        }
        Err(_) => return Err(RuntimeClientError::new("locator_unverifiable")),
    };
    match unsafe { WaitForSingleObject(handle.0, 0) } {
        WAIT_OBJECT_0 => return Ok(false),
        WAIT_TIMEOUT => {}
        _ => return Err(RuntimeClientError::new("locator_unverifiable")),
    }
    if creation(handle.0)? != locator.helper_creation_file_time {
        return Ok(false);
    }
    let mut image = vec![0u16; 32768];
    let mut length = image.len() as u32;
    unsafe {
        QueryFullProcessImageNameW(
            handle.0,
            PROCESS_NAME_FORMAT(0),
            windows::core::PWSTR(image.as_mut_ptr()),
            &mut length,
        )
    }
    .map_err(|_| RuntimeClientError::new("locator_unverifiable"))?;
    let image = PathBuf::from(
        String::from_utf16(&image[..length as usize])
            .map_err(|_| RuntimeClientError::new("locator_unverifiable"))?,
    );
    Ok(same_path(&image, &locator.helper_exe))
}

impl RuntimeClient {
    pub(crate) fn at(locator_file: PathBuf, candidate_directory: PathBuf) -> Self {
        Self {
            locator_file,
            candidate_directory,
            cached: Mutex::new(None),
        }
    }
    fn bundle_ready(&self) -> bool {
        [
            "codex_runtime_bridge.dll",
            "codex_desktop_observer.dll",
            "codex_runtime_metadata.exe",
            "codex_timezone_helper.exe",
        ]
        .iter()
        .all(|file| self.candidate_directory.join(file).is_file())
    }
    fn load(&self) -> ClientResult<Option<Locator>> {
        plain_path(&self.locator_file)?;
        let metadata = match fs::metadata(&self.locator_file) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(RuntimeClientError::new("unavailable")),
        };
        if !metadata.is_file() || metadata.len() == 0 || metadata.len() > LOCATOR_LIMIT {
            return Err(RuntimeClientError::new("locator_invalid"));
        }
        let bytes =
            fs::read(&self.locator_file).map_err(|_| RuntimeClientError::new("unavailable"))?;
        let locator: Locator = serde_json::from_slice(&bytes)
            .map_err(|_| RuntimeClientError::new("locator_invalid"))?;
        if locator.version != 1
            || locator.helper_pid == 0
            || locator.helper_creation_file_time == 0
            || !locator.helper_exe.is_absolute()
            || !config_valid(&locator.config)
        {
            return Err(RuntimeClientError::new("locator_invalid"));
        }
        Ok(Some(locator))
    }
    fn control(
        &self,
        locator: &Locator,
        action: ControlAction,
        budget: Duration,
    ) -> ClientResult<Value> {
        let request = ControlRequest {
            version: 1,
            request_id: REQUEST_ID.fetch_add(1, Ordering::Relaxed),
            action,
        };
        let reply = helper_control::request(&locator.config, request, Instant::now() + budget)
            .map_err(RuntimeClientError::from)?;
        if reply["ok"] != true {
            return Err(RuntimeClientError::new(
                reply["error"]["kind"].as_str().unwrap_or("unavailable"),
            ));
        }
        Ok(reply["data"].clone())
    }
    fn observe(&self, locator: &Locator) -> ClientResult<Value> {
        let data = self.control(locator, ControlAction::Status, STATUS_BUDGET)?;
        if ![
            "unattached",
            "awaiting_confirmation",
            "active",
            "unresolved",
            "target_exited",
        ]
        .contains(&data["phase"].as_str().unwrap_or_default())
            || !data["preparing"].is_boolean()
            || !data["activeSourceRetained"].is_boolean()
            || !data["pendingSourceRetained"].is_boolean()
        {
            return Err(RuntimeClientError::new("invalid_request"));
        }
        *self
            .cached
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(CachedStatus {
            locator: locator.clone(),
            data: data.clone(),
        });
        Ok(data)
    }
    fn cached_data(&self, locator: &Locator) -> Option<Value> {
        self.cached
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_ref()
            .filter(|cached| same_locator(&cached.locator, locator))
            .map(|cached| cached.data.clone())
    }
    fn projection(&self, data: &Value) -> Value {
        let mut public = snapshot(true, "unattached", None);
        public["connected"] = json!(true);
        for key in [
            "phase",
            "preparing",
            "activeSourceRetained",
            "pendingSourceRetained",
        ] {
            public[key] = data[key].clone();
        }
        public["sourceId"] = data["sourceId"]
            .as_str()
            .filter(|source| account_sources::validate_task_source(source).is_ok())
            .map_or(Value::Null, |source| json!(source));
        public["errorKind"] = data["errorKind"].as_str().map_or(Value::Null, |kind| {
            json!(RuntimeClientError::new(kind).kind())
        });
        public
    }
    fn live_snapshot(&self, locator: &Locator) -> Value {
        match self.observe(locator) {
            Ok(data) => self.projection(&data),
            Err(error) => {
                if let Some(cached) = self.cached_data(locator) {
                    let mut public = self.projection(&cached);
                    public["connected"] = json!(false);
                    public["phase"] = json!("unresolved");
                    public["errorKind"] = json!(error.kind());
                    public
                } else {
                    snapshot(true, "connecting", Some(error))
                }
            }
        }
    }
    pub(crate) fn status(&self) -> Value {
        match self.load() {
            Ok(Some(locator)) => match live(&locator) {
                Ok(true) => self.live_snapshot(&locator),
                Ok(false) => snapshot(
                    self.bundle_ready(),
                    "disconnected",
                    Some(RuntimeClientError::new("helper_exited")),
                ),
                Err(error) => snapshot(true, "unresolved", Some(error)),
            },
            Ok(None) => snapshot(self.bundle_ready(), "disconnected", None),
            Err(error) => snapshot(self.bundle_ready(), "unresolved", Some(error)),
        }
    }
    fn reserve(&self) -> ClientResult<File> {
        let parent = self
            .locator_file
            .parent()
            .ok_or(RuntimeClientError::new("unavailable"))?;
        plain_path(parent)?;
        fs::create_dir_all(parent).map_err(|_| RuntimeClientError::new("unavailable"))?;
        plain_path(parent)?;
        let lock = parent.join("locator-v1.lock");
        plain_path(&lock)?;
        OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .share_mode(0)
            .open(lock)
            .map_err(|error| {
                RuntimeClientError::new(if matches!(error.raw_os_error(), Some(32 | 33)) {
                    "owner_busy"
                } else {
                    "unavailable"
                })
            })
    }
    fn store(&self, locator: &Locator) -> ClientResult<()> {
        let parent = self
            .locator_file
            .parent()
            .ok_or(RuntimeClientError::new("unavailable"))?;
        plain_path(&self.locator_file)?;
        let mut file = tempfile::NamedTempFile::new_in(parent)
            .map_err(|_| RuntimeClientError::new("unavailable"))?;
        let bytes =
            serde_json::to_vec(locator).map_err(|_| RuntimeClientError::new("unavailable"))?;
        file.write_all(&bytes)
            .and_then(|_| file.as_file().sync_all())
            .map_err(|_| RuntimeClientError::new("unavailable"))?;
        let from = file
            .path()
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        let to = self
            .locator_file
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        unsafe {
            MoveFileExW(
                PCWSTR(from.as_ptr()),
                PCWSTR(to.as_ptr()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        }
        .map_err(|_| RuntimeClientError::new("unavailable"))?;
        Ok(())
    }
    fn new_owner(&self) -> ClientResult<(Locator, Option<Child>)> {
        let _reservation = self.reserve()?;
        if let Some(locator) = self.load()? {
            if live(&locator)? {
                return Ok((locator, None));
            }
        }
        if !self.bundle_ready() {
            return Err(RuntimeClientError::new("unsupported"));
        }
        // Ensure a publishable same-directory temporary file before spawning.
        let parent = self
            .locator_file
            .parent()
            .ok_or(RuntimeClientError::new("unavailable"))?;
        let preflight = tempfile::NamedTempFile::new_in(parent)
            .map_err(|_| RuntimeClientError::new("unavailable"))?;
        drop(preflight);
        let target =
            crate::desktop_runtime_transport::discover().map_err(RuntimeClientError::from)?;
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let label = format!(
            "{nanos:032x}{:08x}{:08x}",
            std::process::id(),
            REQUEST_ID.fetch_add(1, Ordering::Relaxed)
        );
        let config = HostConfig {
            target,
            control_label: label,
        };
        let executable =
            fs::canonicalize(self.candidate_directory.join("codex_timezone_helper.exe"))
                .map_err(|_| RuntimeClientError::new("unsupported"))?;
        let mut child = Command::new(&executable)
            .current_dir(&self.candidate_directory)
            .args([
                "--target-pid",
                &target.pid.to_string(),
                "--target-created",
                &target.creation_file_time.to_string(),
                "--control-label",
                &config.control_label,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(0x08000000 | 0x01000000)
            .spawn()
            .map_err(|_| RuntimeClientError::new("unavailable"))?;
        let created = match creation(HANDLE(child.as_raw_handle())) {
            Ok(created) => created,
            Err(error) => {
                // A just-started helper has no source. Ask its restricted stop;
                // never terminate it or its target to hide startup failure.
                let _ = helper_control::request(
                    &config,
                    ControlRequest {
                        version: 1,
                        request_id: REQUEST_ID.fetch_add(1, Ordering::Relaxed),
                        action: ControlAction::StopUnowned,
                    },
                    Instant::now() + STARTUP_BUDGET,
                );
                return Err(error);
            }
        };
        let locator = Locator {
            version: 1,
            helper_pid: child.id(),
            helper_creation_file_time: created,
            helper_exe: executable,
            config,
        };
        if let Err(error) = self.store(&locator) {
            let _ = self.control(&locator, ControlAction::StopUnowned, STARTUP_BUDGET);
            let _ = child.try_wait();
            return Err(error);
        }
        // Published before any readiness wait. Dropping Child never kills it.
        Ok((locator, Some(child)))
    }
    pub(crate) fn connect(&self) -> Value {
        // Existing owners take precedence over local candidate component checks.
        match self.load() {
            Ok(Some(locator)) => match live(&locator) {
                Ok(true) => return self.live_snapshot(&locator),
                Err(error) => return snapshot(true, "unresolved", Some(error)),
                Ok(false) => {}
            },
            Err(error) => return snapshot(self.bundle_ready(), "unresolved", Some(error)),
            Ok(None) => {}
        }
        let (locator, mut child) = match self.new_owner() {
            Ok(value) => value,
            Err(error) => return snapshot(self.bundle_ready(), "disconnected", Some(error)),
        };
        let deadline = Instant::now() + STARTUP_BUDGET;
        loop {
            if let Ok(data) = self.observe(&locator) {
                return self.projection(&data);
            }
            if let Some(child) = child.as_mut() {
                if let Ok(Some(status)) = child.try_wait() {
                    return snapshot(
                        true,
                        "disconnected",
                        Some(RuntimeClientError::new(if status.code() == Some(2) {
                            "unsupported"
                        } else {
                            "helper_exited"
                        })),
                    );
                }
            }
            match live(&locator) {
                Ok(false) => {
                    return snapshot(
                        true,
                        "disconnected",
                        Some(RuntimeClientError::new("helper_exited")),
                    )
                }
                Err(error) => return snapshot(true, "unresolved", Some(error)),
                Ok(true) => {}
            }
            if Instant::now() >= deadline {
                return snapshot(
                    true,
                    "connecting",
                    Some(RuntimeClientError::new("helper_starting")),
                );
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
    fn active_key(data: &Value) -> Option<(PathBuf, String)> {
        if data["activeSourceRetained"] != true {
            return None;
        }
        let source = data["sourceId"].as_str()?;
        if account_sources::validate_task_source(source).is_err() {
            return None;
        }
        let root = PathBuf::from(data["profilesRoot"].as_str()?);
        normalized(&root)?;
        Some((root, source.to_owned()))
    }
    fn key_matches(data: &Value, root: &Path, source: &str) -> bool {
        Self::active_key(data).is_some_and(|(active_root, active_source)| {
            active_source == source && same_source_path(&active_root, root)
        })
    }
    pub(crate) fn quota_for_source(
        &self,
        root: &Path,
        source: &str,
    ) -> Option<ClientResult<Value>> {
        let cached = self
            .cached
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone();
        let locator = match self.load() {
            Ok(Some(locator)) => locator,
            Ok(None) => return None,
            Err(error) => {
                return cached
                    .as_ref()
                    .filter(|cached| Self::key_matches(&cached.data, root, source))
                    .map(|_| Err(error))
            }
        };
        match live(&locator) {
            Ok(false) => return None,
            Err(error) => {
                return cached
                    .as_ref()
                    .filter(|cached| {
                        same_locator(&cached.locator, &locator)
                            && Self::key_matches(&cached.data, root, source)
                    })
                    .map(|_| Err(error))
            }
            Ok(true) => {}
        }
        let data = match self.observe(&locator) {
            Ok(data) => data,
            Err(error) => {
                return self
                    .cached_data(&locator)
                    .filter(|data| Self::key_matches(data, root, source))
                    .map(|_| Err(error))
            }
        };
        if !Self::key_matches(&data, root, source) {
            return None;
        }
        Some(
            self.control(
                &locator,
                ControlAction::Quota {
                    source_id: source.to_owned(),
                    profiles_root: root.to_owned(),
                    details: false,
                },
                QUOTA_CONTROL_BUDGET,
            )
            .and_then(|reply| {
                let reply_root = reply["profilesRoot"]
                    .as_str()
                    .map(PathBuf::from)
                    .ok_or(RuntimeClientError::new("source_mismatch"))?;
                if reply["sourceId"].as_str() != Some(source)
                    || !same_source_path(&reply_root, root)
                    || !reply["usage"].is_object()
                {
                    return Err(RuntimeClientError::new("source_mismatch"));
                }
                Ok(reply["usage"].clone())
            }),
        )
    }
    fn action(&self, action: ControlAction, stop: bool) -> Value {
        let locator = match self.load() {
            Ok(Some(locator)) => match live(&locator) {
                Ok(true) => locator,
                Ok(false) => {
                    return snapshot(
                        self.bundle_ready(),
                        "disconnected",
                        Some(RuntimeClientError::new("not_connected")),
                    )
                }
                Err(error) => return snapshot(true, "unresolved", Some(error)),
            },
            Ok(None) => {
                return snapshot(
                    self.bundle_ready(),
                    "disconnected",
                    Some(RuntimeClientError::new("not_connected")),
                )
            }
            Err(error) => return snapshot(self.bundle_ready(), "unresolved", Some(error)),
        };
        let result = self.control(&locator, action, CONTROL_BUDGET);
        if stop && result.is_ok() {
            let deadline = Instant::now() + CONTROL_BUDGET;
            while Instant::now() < deadline {
                if matches!(live(&locator), Ok(false)) {
                    return snapshot(self.bundle_ready(), "disconnected", None);
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
        // Mutations return the same public DTO only after a follow-up Status.
        let mut public = self.status();
        if let Err(error) = result {
            public["errorKind"] = json!(error.kind());
        }
        public
    }

    fn live_status(&self) -> Value {
        let unavailable = || crate::global_live::unavailable(false);
        let locator = match self.load() {
            Ok(Some(locator)) if matches!(live(&locator), Ok(true)) => locator,
            _ => return unavailable(),
        };
        let data = match self.control(&locator, ControlAction::Live, STATUS_BUDGET) {
            Ok(data) => data,
            Err(_) => return unavailable(),
        };
        let decoded: LiveSnapshot = match serde_json::from_value(data) {
            Ok(decoded) => decoded,
            Err(_) => return unavailable(),
        };
        if decoded.live_version != 1
            || decoded.items.len() > 48
            || !decoded.initial_gap
            || !["partial", "unavailable"].contains(&decoded.coverage.as_str())
            || decoded.items.iter().any(|item| {
                item.thread_id.is_empty()
                    || item.thread_id.len() > 256
                    || item.turn_id.as_ref().is_some_and(|turn| turn.len() > 256)
                    || ![
                        "unknown",
                        "not_loaded",
                        "idle",
                        "running",
                        "failed",
                        "completed",
                        "cancelled",
                    ]
                    .contains(&item.state.as_str())
                    || !["unknown", "none", "approval", "input", "approval_and_input"]
                        .contains(&item.attention.as_str())
            })
        {
            return unavailable();
        }
        serde_json::to_value(decoded).unwrap_or_else(|_| unavailable())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LiveSnapshot {
    live_version: u32,
    connected: bool,
    coverage: String,
    initial_gap: bool,
    dropped: u32,
    generation: u64,
    items: Vec<LiveItem>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LiveItem {
    thread_id: String,
    turn_id: Option<String>,
    state: String,
    attention: String,
    observed_at_ms: u64,
    sequence: u64,
}

fn global() -> ClientResult<&'static RuntimeClient> {
    static CLIENT: OnceLock<RuntimeClient> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client);
    }
    let local = PathBuf::from(
        std::env::var_os("LOCALAPPDATA").ok_or(RuntimeClientError::new("unavailable"))?,
    );
    if !local.is_absolute() {
        return Err(RuntimeClientError::new("unavailable"));
    }
    let executable = std::env::current_exe().map_err(|_| RuntimeClientError::new("unavailable"))?;
    let directory = executable
        .parent()
        .ok_or(RuntimeClientError::new("unavailable"))?
        .to_owned();
    Ok(CLIENT.get_or_init(|| {
        RuntimeClient::at(
            local.join("CodexTimeZone/runtime-owner/locator-v1.json"),
            directory,
        )
    }))
}
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    Status {},
    Connect {},
    Switch {
        #[serde(rename = "sourceId")]
        source_id: String,
    },
    Cancel {},
    Reconcile {},
    StopUnowned {},
}
pub(crate) fn execute(payload: Value) -> Result<Value, String> {
    let action: Action = match serde_json::from_value(payload) {
        Ok(action) => action,
        Err(_) => {
            return Ok(snapshot(
                false,
                "disconnected",
                Some(RuntimeClientError::new("invalid_request")),
            ))
        }
    };
    if matches!(&action,Action::Switch {source_id} if account_sources::validate_task_source(source_id).is_err())
    {
        return Ok(snapshot(
            false,
            "disconnected",
            Some(RuntimeClientError::new("invalid_request")),
        ));
    }
    let client = match global() {
        Ok(client) => client,
        Err(error) => return Ok(snapshot(false, "disconnected", Some(error))),
    };
    let mut data = match action {
        Action::Status {} => client.status(),
        Action::Connect {} => client.connect(),
        Action::Switch { source_id } => match account_sources::managed_profiles_root() {
            Ok(root) => client.action(
                ControlAction::Switch {
                    source_id,
                    profiles_root: root,
                },
                false,
            ),
            Err(_) => snapshot(
                false,
                "disconnected",
                Some(RuntimeClientError::new("unavailable")),
            ),
        },
        Action::Cancel {} => client.action(ControlAction::Cancel, false),
        Action::Reconcile {} => client.action(ControlAction::Reconcile, false),
        Action::StopUnowned {} => client.action(ControlAction::StopUnowned, true),
    };
    // Public sourceId belongs only to this GUI's profiles namespace. Internal
    // at() clients and protected IPC retain full keys for cross-candidate routing.
    if data["sourceId"].is_string() {
        let visible = account_sources::managed_profiles_root()
            .ok()
            .zip(
                client
                    .cached
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .as_ref()
                    .and_then(|cached| RuntimeClient::active_key(&cached.data)),
            )
            .is_some_and(|(gui_root, (active_root, _))| same_source_path(&gui_root, &active_root));
        if !visible {
            data["sourceId"] = Value::Null;
        }
    }
    Ok(data)
}
pub(crate) fn quota_for_source(root: &Path, source: &str) -> Option<ClientResult<Value>> {
    global().ok()?.quota_for_source(root, source)
}
pub(crate) fn live_snapshot() -> Value {
    global()
        .map(RuntimeClient::live_status)
        .unwrap_or_else(|_| crate::global_live::unavailable(false))
}
