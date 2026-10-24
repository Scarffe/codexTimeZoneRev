//! Isolated official CLI profiles. Tokens and authorization URLs never cross FFI.
use crate::account_usage::{self, Rpc, RpcError};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
const OWNER: &str = "codex_timezone_managed_profile_v1";
const LOGIN_TIMEOUT: Duration = Duration::from_secs(600);
#[derive(Debug, Clone)]
struct Error {
    kind: &'static str,
}
impl Error {
    fn new(kind: &'static str) -> Self {
        Self { kind }
    }
    fn value(&self) -> Value {
        let message = match self.kind {
            "protected_source" => "当前来源仅供观察。",
            "invalid_source" => "来源标识无效。",
            "isolation_failed" => "账号目录隔离验证失败，操作已停止。",
            "busy" => "该来源正在执行其他操作。",
            "auth_required" => "请重新登录此来源。",
            "auth_failed" => "登录未完成，请重试。",
            "timeout" => "操作超时，请重试。",
            "cancelled" => "操作已取消。",
            "rate_limited" => "查询受到限流，请稍后重试。",
            "identity_changed" => "查询期间账号身份改变，请重试。",
            "unsupported" => "当前组件不支持此操作。",
            "not_found" => "来源或登录任务不存在。",
            "shutdown" => "账号监测正在退出。",
            _ => "账号服务暂不可用，请稍后重试。",
        };
        json!({"kind":self.kind,"message":message})
    }
}
impl From<RpcError> for Error {
    fn from(e: RpcError) -> Self {
        Self::new(e.kind())
    }
}
type Result<T> = std::result::Result<T, Error>;
pub(crate) fn is_auth_override(key: &str) -> bool {
    let k = key.to_ascii_uppercase();
    if k == "CODEX_CA_CERTIFICATE" {
        return false;
    }
    [
        "CODEX",
        "OPENAI",
        "AZURE_OPENAI",
        "ANTHROPIC",
        "CHATGPT",
        "OPENCODE",
        "GEMINI",
        "GOOGLE_API",
        "MODEL_PROVIDER",
        "OLLAMA",
        "VLLM",
        "LMSTUDIO",
    ]
    .iter()
    .any(|p| k.starts_with(p))
}
pub(crate) fn isolate_command(command: &mut Command, home: &Path) {
    let keys = std::env::vars_os()
        .map(|(k, _)| k)
        .chain(command.get_envs().map(|(k, _)| k.to_owned()))
        .collect::<Vec<_>>();
    for key in keys {
        if is_auth_override(&key.to_string_lossy()) {
            command.env_remove(key);
        }
    }
    command
        .env("CODEX_HOME", home)
        .current_dir(home)
        .args(["-c", "cli_auth_credentials_store=\"file\""]);
}
fn quiet(command: &mut Command) {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}
fn opaque(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    format!(
        "{prefix}-{:032x}{:08x}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}
fn source(id: &str) -> Result<()> {
    if ["current", "default"].contains(&id) {
        return Err(Error::new("protected_source"));
    }
    if !id.starts_with("profile-")
        || !(16..=64).contains(&id[8..].len())
        || !id[8..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(Error::new("invalid_source"));
    }
    Ok(())
}
fn safe_path(path: &Path) -> Result<()> {
    for p in path.ancestors() {
        let m = match fs::symlink_metadata(p) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(Error::new("isolation_failed")),
        };
        {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if m.file_attributes() & 0x400 != 0 {
                    return Err(Error::new("isolation_failed"));
                }
            }
            if m.file_type().is_symlink() {
                return Err(Error::new("isolation_failed"));
            }
        }
    }
    Ok(())
}
fn safe_tree(path: &Path) -> Result<()> {
    safe_path(path)?;
    if path.is_dir() {
        for e in fs::read_dir(path).map_err(|_| Error::new("isolation_failed"))? {
            safe_tree(&e.map_err(|_| Error::new("isolation_failed"))?.path())?
        }
    }
    Ok(())
}
// Fixed script, path supplied only through an environment slot. Never evaluates path text.
// Existing ACLs are verified, never silently repaired. Only fresh owned directories are secured.
fn acl(path: &Path, create: bool, tree: bool) -> Result<()> {
    #[cfg(windows)]
    {
        let script = include_str!("account_profile_acl.ps1");
        let system = std::env::var_os("SystemRoot").ok_or(Error::new("isolation_failed"))?;
        let mut c = Command::new(
            PathBuf::from(system).join("System32/WindowsPowerShell/v1.0/powershell.exe"),
        );
        c.args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("CTZ_PROFILE_ACL_PATH", path)
            .env("CTZ_PROFILE_ACL_CREATE", if create { "1" } else { "0" })
            .env("CTZ_PROFILE_ACL_TREE", if tree { "1" } else { "0" });
        quiet(&mut c);
        let mut child = c.spawn().map_err(|_| Error::new("isolation_failed"))?;
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match child.try_wait() {
                Ok(Some(s)) => {
                    return if s.success() {
                        Ok(())
                    } else {
                        Err(Error::new("isolation_failed"))
                    }
                }
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(Error::new("isolation_failed"));
                }
            }
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (path, create, tree);
        Err(Error::new("unsupported"))
    }
}
fn binding(cli: &Path) -> Result<Value> {
    let m = fs::metadata(cli).map_err(|_| Error::new("unavailable"))?;
    Ok(
        json!({"path":cli,"length":m.len(),"modified":m.modified().ok().and_then(|v|v.duration_since(UNIX_EPOCH).ok()).map(|v|v.as_nanos().to_string())}),
    )
}
fn fixed_cli(metadata: &Value) -> Result<PathBuf> {
    let cli = PathBuf::from(
        metadata["cli"]["path"]
            .as_str()
            .ok_or(Error::new("isolation_failed"))?,
    );
    if metadata["cli"] != binding(&cli)? {
        return Err(Error::new("unavailable"));
    }
    Ok(cli)
}
struct Job {
    id: String,
    state: &'static str,
    error: Option<Error>,
    cancel: Arc<AtomicBool>,
}
#[derive(Default)]
struct State {
    bound: Option<PathBuf>,
    verified: Option<Value>,
    active: HashMap<String, Arc<AtomicBool>>,
    jobs: HashMap<String, Job>,
    shutdown: bool,
}
struct Service {
    root: PathBuf,
    state: Mutex<State>,
    timeout: Duration,
    browser: Option<Arc<dyn Fn(&str) -> Result<()> + Send + Sync>>,
}
struct Activity {
    service: Arc<Service>,
    source: String,
    cancel: Arc<AtomicBool>,
}
impl Drop for Activity {
    fn drop(&mut self) {
        let mut s = self.service.state.lock().unwrap();
        if s.active
            .get(&self.source)
            .is_some_and(|v| Arc::ptr_eq(v, &self.cancel))
        {
            s.active.remove(&self.source);
        }
    }
}
struct Lease {
    service: Arc<Service>,
    source: String,
    _file: Option<File>,
    cancel: Arc<AtomicBool>,
    metadata: Value,
    home: PathBuf,
}
impl Drop for Lease {
    fn drop(&mut self) {
        drop(self._file.take());
        let mut s = self.service.state.lock().unwrap();
        if s.active
            .get(&self.source)
            .is_some_and(|v| Arc::ptr_eq(v, &self.cancel))
        {
            s.active.remove(&self.source);
        }
    }
}
impl Service {
    fn new(root: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            root,
            state: Mutex::new(State::default()),
            timeout: LOGIN_TIMEOUT,
            browser: Some(Arc::new(open_auth_url)),
        })
    }
    #[cfg(test)]
    fn for_test(root: PathBuf, cli: PathBuf, timeout: Duration) -> Arc<Self> {
        Arc::new(Self {
            root,
            state: Mutex::new(State {
                verified: Some(binding(&cli).unwrap()),
                bound: Some(cli),
                ..Default::default()
            }),
            timeout,
            browser: None,
        })
    }
    fn activity(self: &Arc<Self>, id: &str) -> Result<Activity> {
        let mut s = self.state.lock().unwrap();
        if s.shutdown {
            return Err(Error::new("shutdown"));
        }
        if s.active.contains_key(id) {
            return Err(Error::new("busy"));
        }
        let cancel = Arc::new(AtomicBool::new(false));
        s.active.insert(id.into(), cancel.clone());
        Ok(Activity {
            service: self.clone(),
            source: id.into(),
            cancel,
        })
    }
    fn root_ready(&self) -> Result<()> {
        safe_path(&self.root)?;
        if !self.root.exists() {
            fs::create_dir(&self.root).map_err(|_| Error::new("isolation_failed"))?;
            acl(&self.root, true, false)?;
            let mut f = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.root.join(".monitor-root"))
                .map_err(|_| Error::new("isolation_failed"))?;
            f.write_all(OWNER.as_bytes())
                .map_err(|_| Error::new("isolation_failed"))?;
        }
        acl(&self.root, false, false)?;
        safe_path(&self.root.join(".monitor-root"))?;
        if fs::read_to_string(self.root.join(".monitor-root"))
            .ok()
            .as_deref()
            != Some(OWNER)
        {
            return Err(Error::new("isolation_failed"));
        }
        Ok(())
    }
    fn create(&self) -> Result<Value> {
        let s = self.state.lock().unwrap();
        if s.shutdown {
            return Err(Error::new("shutdown"));
        }
        let cli = s.bound.clone().ok_or(Error::new("unsupported"))?;
        if s.verified.as_ref() != Some(&binding(&cli)?) {
            return Err(Error::new("unavailable"));
        }
        self.root_ready()?;
        let id = opaque("profile");
        let home = self.root.join(&id);
        fs::create_dir(&home).map_err(|_| Error::new("isolation_failed"))?;
        acl(&home, true, false)?;
        let metadata = json!({"owner":OWNER,"sourceId":id,"cli":binding(&cli)?});
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(home.join(".monitor-profile.json"))
            .map_err(|_| Error::new("isolation_failed"))?;
        f.write_all(metadata.to_string().as_bytes())
            .map_err(|_| Error::new("isolation_failed"))?;
        Ok(json!({"sourceId":id}))
    }
    fn owned_profile(&self, id: &str) -> Result<(PathBuf, Value)> {
        source(id)?;
        self.root_ready()?;
        let home = self.root.join(id);
        safe_tree(&home)?;
        if !home.is_dir() {
            return Err(Error::new("not_found"));
        }
        acl(&home, false, true)?;
        let marker = home.join(".monitor-profile.json");
        if fs::metadata(&marker)
            .map_err(|_| Error::new("isolation_failed"))?
            .len()
            > 16384
        {
            return Err(Error::new("isolation_failed"));
        }
        let meta: Value =
            serde_json::from_slice(&fs::read(marker).map_err(|_| Error::new("isolation_failed"))?)
                .map_err(|_| Error::new("isolation_failed"))?;
        if meta["owner"] != OWNER || meta["sourceId"] != id {
            return Err(Error::new("isolation_failed"));
        }
        Ok((home, meta))
    }
    fn profile(&self, id: &str) -> Result<(PathBuf, PathBuf)> {
        let (home, metadata) = self.owned_profile(id)?;
        Ok((home, fixed_cli(&metadata)?))
    }
    fn lease(self: &Arc<Self>, id: &str) -> Result<Lease> {
        source(id)?;
        let mut s = self.state.lock().unwrap();
        if s.shutdown {
            return Err(Error::new("shutdown"));
        }
        if s.active.contains_key(id) {
            return Err(Error::new("busy"));
        }
        // Ownership and exclusive deletion must survive an absent/updated CLI.
        // Executing callers validate the fixed binding separately after leasing.
        let (home, metadata) = self.owned_profile(id)?;
        let mut o = OpenOptions::new();
        o.read(true).write(true).create(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            o.share_mode(0);
        }
        let lock_path = self.root.join(format!(".lease-{id}"));
        safe_path(&lock_path)?;
        let file = o.open(lock_path).map_err(|_| Error::new("busy"))?;
        let cancel = Arc::new(AtomicBool::new(false));
        s.active.insert(id.into(), cancel.clone());
        Ok(Lease {
            service: self.clone(),
            source: id.into(),
            _file: Some(file),
            cancel,
            metadata,
            home,
        })
    }
    fn usage(self: &Arc<Self>, id: &str) -> Result<Value> {
        let lease = self.lease(id)?;
        let cli = fixed_cli(&lease.metadata)?;
        let mut rpc = Rpc::start_options(
            &cli,
            Duration::from_secs(60),
            Some(&lease.home),
            lease.cancel.clone(),
        )
        .map_err(|_| Error::new("unavailable"))?;
        let v = account_usage::read_typed(&mut rpc, false)?;
        if lease.cancel.load(Ordering::SeqCst) {
            return Err(Error::new("cancelled"));
        }
        Ok(json!({"sourceId":id,"queriedAtMs":now(),"usage":v}))
    }
    fn login(self: &Arc<Self>, id: &str) -> Result<Value> {
        source(id)?;
        {
            let s = self.state.lock().unwrap();
            if s.jobs
                .values()
                .any(|j| ["starting", "waiting"].contains(&j.state))
            {
                return Err(Error::new("busy"));
            }
        }
        let lease = self.lease(id)?;
        let cli = fixed_cli(&lease.metadata)?;
        let job = opaque("login");
        {
            let mut s = self.state.lock().unwrap();
            if s.jobs
                .values()
                .any(|j| ["starting", "waiting"].contains(&j.state))
            {
                return Err(Error::new("busy"));
            }
            s.jobs.insert(
                id.into(),
                Job {
                    id: job.clone(),
                    state: "starting",
                    error: None,
                    cancel: lease.cancel.clone(),
                },
            );
        }
        let service = self.clone();
        let source_id = id.to_owned();
        let job_id = job.clone();
        thread::spawn(move || {
            let result = (|| -> Result<()> {
                // A persisted source retains its original CLI. Revalidate that
                // binding in an empty home before any authentication starts.
                service.verify_cli(&cli, lease.cancel.clone())?;
                let mut rpc = Rpc::start_options(
                    &cli,
                    service.timeout,
                    Some(&lease.home),
                    lease.cancel.clone(),
                )
                .map_err(|_| Error::new("unavailable"))?;
                rpc.initialize()?;
                let start = rpc.call("account/login/start", json!({"type":"chatgpt"}))?;
                let login_id = start["loginId"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or(Error::new("unsupported"))?;
                let auth = start["authUrl"].as_str().ok_or(Error::new("unsupported"))?;
                validate_auth_url(auth)?;
                if lease.cancel.load(Ordering::SeqCst) {
                    return Err(Error::new("cancelled"));
                }
                service.dispatch_browser(&source_id, &job_id, auth)?;
                if !rpc.login_completion(login_id)? {
                    return Err(Error::new("auth_failed"));
                }
                if lease.cancel.load(Ordering::SeqCst) {
                    return Err(Error::new("cancelled"));
                }
                // Metadata only: never read the CLI's credential contents.
                if !lease.home.join("auth.json").is_file() {
                    return Err(Error::new("isolation_failed"));
                }
                drop(rpc);
                service.profile(&source_id)?;
                if lease.cancel.load(Ordering::SeqCst) {
                    return Err(Error::new("cancelled"));
                }
                Ok(())
            })();
            let mut s = service.state.lock().unwrap();
            if let Some(j) = s.jobs.get_mut(&source_id) {
                if j.id == job_id && ["starting", "waiting"].contains(&j.state) {
                    match result {
                        Ok(()) if !j.cancel.load(Ordering::SeqCst) => j.state = "succeeded",
                        Ok(()) => j.state = "cancelled",
                        Err(e) => {
                            j.state = match e.kind {
                                "cancelled" => "cancelled",
                                "timeout" => "timed_out",
                                _ => "failed",
                            };
                            j.error = Some(e);
                        }
                    }
                }
            }
            drop(s);
            drop(lease);
        });
        Ok(json!({"sourceId":id,"jobId":job,"state":"starting"}))
    }
    fn status(&self, id: &str, job: &str) -> Result<Value> {
        source(id)?;
        let s = self.state.lock().unwrap();
        let j = s
            .jobs
            .get(id)
            .filter(|j| j.id == job)
            .ok_or(Error::new("not_found"))?;
        Ok(
            json!({"sourceId":id,"jobId":job,"state":j.state,"error":j.error.as_ref().map(|e|e.value())}),
        )
    }
    fn dispatch_browser(&self, id: &str, job: &str, auth: &str) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.shutdown {
            return Err(Error::new("cancelled"));
        }
        let live = state
            .jobs
            .get_mut(id)
            .filter(|j| j.id == job && j.state == "starting" && !j.cancel.load(Ordering::SeqCst))
            .ok_or(Error::new("cancelled"))?;
        live.state = "waiting";
        // The transition and browser dispatch share the cancellation lock.
        // Cleanup either wins first and forbids dispatch, or follows a dispatch
        // that was already accepted; it cannot win in between these steps.
        if let Some(open) = &self.browser {
            open(auth)?;
        }
        drop(state);
        Ok(())
    }
    fn cancel(&self, id: &str, job: &str) -> Result<Value> {
        source(id)?;
        {
            let mut s = self.state.lock().unwrap();
            let j = s
                .jobs
                .get_mut(id)
                .filter(|j| j.id == job)
                .ok_or(Error::new("not_found"))?;
            if ["starting", "waiting"].contains(&j.state) {
                j.cancel.store(true, Ordering::SeqCst);
                j.state = "cancelled";
            }
        }
        self.wait_idle(Some(id))?;
        self.status(id, job)
    }
    fn wait_idle(&self, id: Option<&str>) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let busy = {
                let s = self.state.lock().unwrap();
                match id {
                    Some(id) => s.active.contains_key(id),
                    None => !s.active.is_empty(),
                }
            };
            if !busy {
                return Ok(());
            }
            if Instant::now() > deadline {
                return Err(Error::new("busy"));
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn remove(self: &Arc<Self>, id: &str) -> Result<Value> {
        source(id)?;
        {
            let mut s = self.state.lock().unwrap();
            if let Some(c) = s.active.get(id) {
                c.store(true, Ordering::SeqCst)
            }
            if let Some(j) = s.jobs.get_mut(id) {
                if ["starting", "waiting"].contains(&j.state) {
                    j.state = "cancelled";
                }
            }
        }
        self.wait_idle(Some(id))?;
        let lease = self.lease(id)?;
        safe_tree(&lease.home)?;
        let home = lease.home.clone();
        let mut s = self.state.lock().unwrap();
        safe_tree(&home)?;
        fs::remove_dir_all(home).map_err(|_| Error::new("isolation_failed"))?;
        s.jobs.remove(id);
        drop(s);
        drop(lease);
        Ok(json!({"sourceId":id,"removed":true}))
    }
    fn shutdown(&self) -> Result<Value> {
        {
            let mut s = self.state.lock().unwrap();
            s.shutdown = true;
            for c in s.active.values() {
                c.store(true, Ordering::SeqCst)
            }
            for j in s.jobs.values_mut() {
                if ["starting", "waiting"].contains(&j.state) {
                    j.cancel.store(true, Ordering::SeqCst);
                    j.state = "cancelled";
                }
            }
        }
        self.wait_idle(None)?;
        Ok(json!({"shutdown":true}))
    }
    fn probe(self: &Arc<Self>) -> Result<Value> {
        {
            let s = self.state.lock().unwrap();
            if s.shutdown {
                return Err(Error::new("shutdown"));
            }
            if let Some(cli) = &s.bound {
                if s.verified.as_ref() != Some(&binding(cli)?) {
                    return Err(Error::new("unavailable"));
                }
                return Ok(json!({"supported":true,"managedLogin":true}));
            }
        }
        let activity = self.activity("__probe")?;
        let cli = account_usage::cli_paths(None)
            .map_err(|_| Error::new("unavailable"))?
            .into_iter()
            .next()
            .ok_or(Error::new("unavailable"))?;
        self.verify_cli(&cli, activity.cancel.clone())?;
        let mut s = self.state.lock().unwrap();
        if s.shutdown || activity.cancel.load(Ordering::SeqCst) {
            return Err(Error::new("shutdown"));
        }
        s.verified = Some(binding(&cli)?);
        s.bound = Some(cli);
        Ok(json!({"supported":true,"managedLogin":true}))
    }
    fn verify_cli(&self, cli: &Path, cancel: Arc<AtomicBool>) -> Result<()> {
        self.root_ready()?;
        let tmp = tempfile::Builder::new()
            .prefix(".capability-")
            .tempdir_in(&self.root)
            .map_err(|_| Error::new("isolation_failed"))?;
        acl(tmp.path(), true, false)?;
        let mut c = Command::new(cli);
        isolate_command(&mut c, tmp.path());
        c.args(["app-server", "generate-json-schema", "--out"])
            .arg(tmp.path().join("schema"));
        quiet(&mut c);
        let mut child = c.spawn().map_err(|_| Error::new("unsupported"))?;
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if cancel.load(Ordering::SeqCst) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::new("cancelled"));
            }
            match child.try_wait() {
                Ok(Some(s)) if s.success() => break,
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(Error::new("unsupported"));
                }
            }
        }
        let req = fs::read_to_string(tmp.path().join("schema/ClientRequest.json"))
            .map_err(|_| Error::new("unsupported"))?;
        let notices = fs::read_to_string(tmp.path().join("schema/ServerNotification.json"))
            .map_err(|_| Error::new("unsupported"))?;
        for method in [
            "config/read",
            "account/login/start",
            "account/login/cancel",
            "account/read",
            "account/rateLimits/read",
        ] {
            if !req.contains(&format!("\"{method}\"")) {
                return Err(Error::new("unsupported"));
            }
        }
        if !notices.contains("\"account/login/completed\"") {
            return Err(Error::new("unsupported"));
        }
        let mut rpc = Rpc::start_options(cli, Duration::from_secs(15), Some(tmp.path()), cancel)
            .map_err(|_| Error::new("unsupported"))?;
        rpc.initialize()?;
        if !rpc.call("account/read", json!({"refreshToken":false}))?["account"].is_null() {
            return Err(Error::new("isolation_failed"));
        }
        Ok(())
    }
}
fn validate_auth_url(raw: &str) -> Result<()> {
    let url = url::Url::parse(raw).map_err(|_| Error::new("unsupported"))?;
    if url.scheme() != "https"
        || ![Some("auth.openai.com"), Some("chatgpt.com")].contains(&url.host_str())
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
    {
        return Err(Error::new("unsupported"));
    }
    Ok(())
}
fn open_auth_url(raw: &str) -> Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows::{
            core::{w, PCWSTR},
            Win32::{
                Foundation::HWND,
                UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL},
            },
        };
        let wide = std::ffi::OsStr::new(raw)
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        let r = unsafe {
            ShellExecuteW(
                Some(HWND::default()),
                w!("open"),
                PCWSTR(wide.as_ptr()),
                None,
                None,
                SW_SHOWNORMAL,
            )
        };
        if r.0 as usize <= 32 {
            return Err(Error::new("unavailable"));
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = raw;
        Err(Error::new("unsupported"))
    }
}
fn global() -> Result<&'static Arc<Service>> {
    static SERVICE: OnceLock<Arc<Service>> = OnceLock::new();
    if let Some(s) = SERVICE.get() {
        return Ok(s);
    }
    let root = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.join("account-profiles")))
        .ok_or(Error::new("unavailable"))?;
    Ok(SERVICE.get_or_init(|| Service::new(root)))
}
pub(crate) fn execute(command: &str, payload: Value) -> std::result::Result<Value, String> {
    let result = (|| -> Result<Value> {
        let s = global()?;
        let id = payload["sourceId"].as_str().unwrap_or_default();
        let job = payload["jobId"].as_str().unwrap_or_default();
        match command {
            "account_source_probe" => s.probe(),
            "account_source_create" => s.create(),
            "account_source_login_start" => s.login(id),
            "account_source_login_status" => s.status(id, job),
            "account_source_login_cancel" => s.cancel(id, job),
            "account_source_remove" => s.remove(id),
            "account_source_shutdown" => s.shutdown(),
            "account_source_usage" => {
                if id == "current" {
                    let activity = s.activity(id)?;
                    #[cfg(windows)]
                    let result = crate::windows::account_usage_typed(
                        payload.clone(),
                        activity.cancel.clone(),
                    );
                    #[cfg(target_os = "macos")]
                    let result =
                        crate::macos::account_usage_typed(payload.clone(), activity.cancel.clone());
                    #[cfg(not(any(windows, target_os = "macos")))]
                    let result: std::result::Result<Value, RpcError> = Err(RpcError::Unsupported);
                    result
                        .map(|v| json!({"sourceId":id,"queriedAtMs":now(),"usage":v}))
                        .map_err(Into::into)
                } else if payload["details"] == true {
                    Err(Error::new("unsupported"))
                } else {
                    s.usage(id)
                }
            }
            _ => Err(Error::new("unsupported")),
        }
    })();
    Ok(match result {
        Ok(mut value) => {
            value["ok"] = json!(true);
            value
        }
        Err(e) => json!({"ok":false,"error":e.value()}),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        path::PathBuf,
        process::Command,
        sync::OnceLock,
        time::{Duration, Instant},
    };
    fn fixture(mode: &str) -> PathBuf {
        static FIXTURE: OnceLock<tempfile::TempDir> = OnceLock::new();
        let root = FIXTURE.get_or_init(|| {
            let root = tempfile::tempdir().unwrap();
            let source = root.path().join("profile_cli.rs");
            fs::write(&source, include_str!("../tests/fixtures/profile_cli.rs")).unwrap();
            let exe = root.path().join(if cfg!(windows) {
                "success.exe"
            } else {
                "success"
            });
            assert!(Command::new("rustc")
                .arg("--edition=2021")
                .arg(source)
                .arg("-o")
                .arg(&exe)
                .status()
                .unwrap()
                .success());
            for mode in [
                "early",
                "failure",
                "timeout",
                "auth",
                "limits_failure",
                "switched",
                "partial",
                "query_timeout",
                "probe_leak",
                "probe_timeout",
                "missing_protocol",
                "revalidate_timeout",
                "store_keyring",
                "store_auto",
                "store_missing",
                "store_unsupported",
                "profile_keyring",
            ] {
                fs::copy(
                    &exe,
                    root.path().join(if cfg!(windows) {
                        format!("{mode}.exe")
                    } else {
                        mode.into()
                    }),
                )
                .unwrap();
            }
            root
        });
        root.path().join(if cfg!(windows) {
            format!("{mode}.exe")
        } else {
            mode.into()
        })
    }
    fn service(mode: &str) -> (tempfile::TempDir, std::sync::Arc<Service>) {
        let root = tempfile::tempdir().unwrap();
        let s = Service::for_test(
            root.path().join("account-profiles"),
            fixture(mode),
            Duration::from_millis(500),
        );
        (root, s)
    }
    fn create(s: &Service) -> String {
        s.create().unwrap()["sourceId"].as_str().unwrap().into()
    }
    fn terminal(s: &Service, id: &str, job: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let v = s.status(id, job).unwrap();
            if !["starting", "waiting"].contains(&v["state"].as_str().unwrap()) {
                return v;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[test]
    fn inherited_auth_provider_overrides_are_removed_but_network_and_cert_environment_survive() {
        for key in [
            "CODEX_HOME",
            "CODEX_AUTH_TOKEN",
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
            "AZURE_OPENAI_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CHATGPT_ACCESS_TOKEN",
            "GOOGLE_API_KEY",
        ] {
            assert!(is_auth_override(key));
        }
        for key in [
            "PATH",
            "SystemRoot",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "SSL_CERT_FILE",
            "NODE_EXTRA_CA_CERTS",
        ] {
            assert!(!is_auth_override(key));
        }
    }
    #[test]
    fn source_guards_reject_default_paths_and_unowned_homes() {
        let (root, s) = service("success");
        for id in [
            "current",
            "default",
            "../external",
            "profile-..",
            "C:\\outside",
            "",
        ] {
            assert!(s.remove(id).is_err());
        }
        let external = root.path().join("external");
        fs::create_dir(&external).unwrap();
        fs::write(external.join("keep"), "keep").unwrap();
        assert!(s.usage("profile-0000000000000000").is_err());
        assert!(external.join("keep").exists());
    }
    #[test]
    fn explicit_home_file_store_and_cwd_never_default_and_usage_has_source_affinity() {
        let (_root, s) = service("success");
        let id = create(&s);
        let v = s.usage(&id).unwrap();
        assert_eq!(v["sourceId"], id);
        assert_eq!(v["usage"]["account"]["planType"], "plus");
        assert!(v["usage"]["tokenUsage"].is_null());
        assert!(v["queriedAtMs"].as_u64().unwrap() > 0);
        assert!(!v.to_string().contains("SECRET"));
    }
    #[test]
    fn completion_before_start_response_is_retained_and_repeated_completion_is_terminal() {
        let (_root, s) = service("early");
        let id = create(&s);
        let job = s.login(&id).unwrap()["jobId"].as_str().unwrap().to_owned();
        assert_eq!(terminal(&s, &id, &job)["state"], "succeeded");
        assert_eq!(s.cancel(&id, &job).unwrap()["state"], "succeeded");
    }
    #[test]
    fn login_failure_timeout_and_server_secrets_are_typed() {
        for (mode, state, kind) in [
            ("failure", "failed", "auth_failed"),
            ("timeout", "timed_out", "timeout"),
        ] {
            let (_root, s) = service(mode);
            let id = create(&s);
            let job = s.login(&id).unwrap()["jobId"].as_str().unwrap().to_owned();
            let v = terminal(&s, &id, &job);
            assert_eq!(v["state"], state);
            assert_eq!(v["error"]["kind"], kind);
            assert!(!v.to_string().contains("SECRET"));
        }
    }
    #[test]
    fn cancel_remove_shutdown_invalidate_late_login_and_enforce_exclusive_source() {
        let (_root, s) = service("timeout");
        let a = create(&s);
        let b = create(&s);
        let j = s.login(&a).unwrap()["jobId"].as_str().unwrap().to_owned();
        assert_eq!(s.login(&b).unwrap_err().kind, "busy");
        assert_eq!(s.usage(&a).unwrap_err().kind, "busy");
        assert_eq!(s.cancel(&a, &j).unwrap()["state"], "cancelled");
        assert_eq!(terminal(&s, &a, &j)["state"], "cancelled");
        s.remove(&a).unwrap();
        assert!(s.status(&a, &j).is_err());
        let j = s.login(&b).unwrap()["jobId"].as_str().unwrap().to_owned();
        s.shutdown().unwrap();
        assert_eq!(s.status(&b, &j).unwrap()["state"], "cancelled");
        assert_eq!(s.create().unwrap_err().kind, "shutdown");
    }
    #[test]
    fn auth_rate_limit_partial_and_identity_changes_are_typed_without_raw_error() {
        for (mode, kind) in [
            ("auth", "auth_required"),
            ("limits_failure", "rate_limited"),
            ("switched", "identity_changed"),
        ] {
            let (_root, s) = service(mode);
            let id = create(&s);
            let e = s.usage(&id).unwrap_err();
            assert_eq!(e.kind, kind);
            assert!(!e.value().to_string().contains("SECRET"));
        }
        let (_root, s) = service("partial");
        let id = create(&s);
        let v = s.usage(&id).unwrap();
        assert!(v["usage"]["limits"]["rateLimitsByLimitId"].is_object());
    }
    #[cfg(windows)]
    fn create_junction(link: &Path, target: &Path) {
        use std::os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::AsRawHandle};
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn DeviceIoControl(
                handle: *mut std::ffi::c_void,
                code: u32,
                input: *const std::ffi::c_void,
                input_size: u32,
                output: *mut std::ffi::c_void,
                output_size: u32,
                returned: *mut u32,
                overlapped: *mut std::ffi::c_void,
            ) -> i32;
        }
        fs::create_dir(link).unwrap();
        let file = OpenOptions::new()
            .write(true)
            .custom_flags(0x0220_0000)
            .open(link)
            .unwrap();
        let print = target.as_os_str().encode_wide().collect::<Vec<_>>();
        let substitute = std::ffi::OsString::from(format!(r"\??\{}", target.display()))
            .encode_wide()
            .collect::<Vec<_>>();
        let data_length = 8 + (substitute.len() + 1 + print.len() + 1) * 2;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0xA0000003u32.to_le_bytes());
        for word in [
            data_length as u16,
            0,
            0,
            (substitute.len() * 2) as u16,
            ((substitute.len() + 1) * 2) as u16,
            (print.len() * 2) as u16,
        ] {
            bytes.extend_from_slice(&word.to_le_bytes());
        }
        for word in substitute.into_iter().chain([0]).chain(print).chain([0]) {
            bytes.extend_from_slice(&word.to_le_bytes());
        }
        let mut returned = 0;
        let ok = unsafe {
            DeviceIoControl(
                file.as_raw_handle(),
                0x000900A4,
                bytes.as_ptr().cast(),
                bytes.len() as u32,
                std::ptr::null_mut(),
                0,
                &mut returned,
                std::ptr::null_mut(),
            )
        };
        assert_ne!(
            ok,
            0,
            "junction creation failed: {}",
            std::io::Error::last_os_error()
        );
    }
    #[cfg(windows)]
    #[test]
    fn reparse_and_foreign_acl_fail_before_mutation() {
        let (root, s) = service("success");
        let id = create(&s);
        let home = s.root.join(&id);
        let external = root.path().join("external");
        fs::create_dir(&external).unwrap();
        fs::write(external.join("keep"), "keep").unwrap();
        // Junctions/symlinks inside an owned home must never be traversed on removal.
        let link = home.join("link");
        create_junction(&link, &external);
        assert_eq!(s.remove(&id).unwrap_err().kind, "isolation_failed");
        assert!(external.join("keep").exists());
        fs::remove_dir(link).unwrap();
        fs::write(home.join(".monitor-profile.json"), "{}").unwrap();
        assert_eq!(s.usage(&id).unwrap_err().kind, "isolation_failed");
    }
    #[test]
    fn inherited_override_is_stripped_at_real_child_boundary() {
        let home = tempfile::tempdir().unwrap();
        let mut c = Command::new(fixture("success"));
        c.env("OPENAI_API_KEY", "SECRET")
            .env("OPENAI_BASE_URL", "https://invalid.example")
            .env("CODEX_AUTH_TOKEN", "SECRET");
        isolate_command(&mut c, home.path());
        c.args(["app-server", "--listen", "stdio://"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        assert!(c.status().unwrap().success());
    }
    #[cfg(windows)]
    #[test]
    fn credential_file_acl_is_checked_and_never_repaired() {
        let (_root, s) = service("success");
        let id = create(&s);
        let auth = s.root.join(&id).join("auth.json");
        fs::write(&auth, "synthetic").unwrap();
        let script="$p=$env:CTZ_TEST_ACL_PATH;$a=[IO.File]::GetAccessControl($p);$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Read','Allow'));[IO.File]::SetAccessControl($p,$a)";
        let mut c = Command::new(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32/WindowsPowerShell/v1.0/powershell.exe"),
        );
        c.args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("CTZ_TEST_ACL_PATH", &auth);
        quiet(&mut c);
        assert!(c.status().unwrap().success());
        assert_eq!(s.usage(&id).unwrap_err().kind, "isolation_failed");
    }
    #[test]
    fn restart_preserves_fixed_cli_binding_and_exclusive_lease() {
        let (_root, s) = service("timeout");
        let id = create(&s);
        let lease = s.lease(&id).unwrap();
        let restarted =
            Service::for_test(s.root.clone(), fixture("success"), Duration::from_secs(1));
        assert_eq!(restarted.usage(&id).unwrap_err().kind, "busy");
        drop(lease);
        assert!(restarted.usage(&id).is_ok());
    }
    #[test]
    fn authorization_url_rejects_lookalikes_userinfo_custom_ports_and_http() {
        for u in [
            "https://auth.openai.com/authorize?state=SECRET",
            "https://chatgpt.com/codex/authorize",
        ] {
            assert!(validate_auth_url(u).is_ok());
        }
        for u in [
            "http://auth.openai.com/authorize",
            "https://auth.openai.com.evil.example/a",
            "https://u@auth.openai.com/a",
            "https://chatgpt.com:444/a",
            "file:///C:/a",
        ] {
            assert!(validate_auth_url(u).is_err());
        }
    }
    #[test]
    fn changed_cli_after_probe_rejects_new_profile_without_rebinding() {
        let root = tempfile::tempdir().unwrap();
        let cli = root
            .path()
            .join(if cfg!(windows) { "fixed.exe" } else { "fixed" });
        fs::copy(fixture("success"), &cli).unwrap();
        let s = Service::for_test(
            root.path().join("account-profiles"),
            cli.clone(),
            Duration::from_secs(1),
        );
        let id = create(&s);
        let mut f = OpenOptions::new().append(true).open(&cli).unwrap();
        f.write_all(b"changed").unwrap();
        drop(f);
        assert_eq!(s.create().unwrap_err().kind, "unavailable");
        assert_eq!(s.usage(&id).unwrap_err().kind, "unavailable");
    }
    #[test]
    fn removing_inflight_usage_cancels_owned_child_and_cannot_restore_profile() {
        let (_root, s) = service("query_timeout");
        let id = create(&s);
        let worker = s.clone();
        let source = id.clone();
        let thread = thread::spawn(move || worker.usage(&source));
        let until = Instant::now() + Duration::from_secs(5);
        while !s.state.lock().unwrap().active.contains_key(&id) {
            assert!(Instant::now() < until);
            thread::sleep(Duration::from_millis(5));
        }
        s.remove(&id).unwrap();
        assert_eq!(thread.join().unwrap().unwrap_err().kind, "cancelled");
        assert!(!s.root.join(id).exists());
    }
    #[test]
    fn capability_probe_checks_protocol_and_empty_isolated_account_without_querying_limits() {
        for (mode, kind) in [("success", None), ("probe_leak", Some("isolation_failed"))] {
            let root = tempfile::tempdir().unwrap();
            let s = Service::new(root.path().join("account-profiles"));
            let result = s.verify_cli(&fixture(mode), Arc::new(AtomicBool::new(false)));
            match kind {
                None => assert!(result.is_ok()),
                Some(k) => assert_eq!(result.unwrap_err().kind, k),
            }
            assert!(s.state.lock().unwrap().bound.is_none());
        }
    }
    #[test]
    fn shutdown_cancels_capability_child_and_observational_activity() {
        let root = tempfile::tempdir().unwrap();
        let s = Service::new(root.path().join("account-profiles"));
        let activity = s.activity("__probe").unwrap();
        let cancelled = activity.cancel.clone();
        let worker = s.clone();
        let handle = thread::spawn(move || {
            let result = worker.verify_cli(&fixture("probe_timeout"), activity.cancel.clone());
            drop(activity);
            result
        });
        s.shutdown().unwrap();
        assert!(cancelled.load(Ordering::SeqCst));
        assert_eq!(handle.join().unwrap().unwrap_err().kind, "cancelled");
    }
    #[test]
    fn login_revalidates_persisted_cli_protocol_before_any_authentication() {
        let (_root, s) = service("missing_protocol");
        let id = create(&s);
        let job = s.login(&id).unwrap()["jobId"].as_str().unwrap().to_owned();
        let v = terminal(&s, &id, &job);
        assert_eq!(v["state"], "failed");
        assert_eq!(v["error"]["kind"], "unsupported");
        assert!(!s.root.join(id).join("auth.json").exists());
    }
    #[test]
    fn cancelling_login_during_capability_revalidation_never_starts_authentication() {
        let (_root, s) = service("revalidate_timeout");
        let id = create(&s);
        let job = s.login(&id).unwrap()["jobId"].as_str().unwrap().to_owned();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !s.root.join(".probe-started").exists() {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(s.cancel(&id, &job).unwrap()["state"], "cancelled");
        assert!(!s.root.join(id).join("auth.json").exists());
    }
    #[test]
    fn effective_non_file_store_denies_login_and_usage_before_account_access() {
        for mode in [
            "store_keyring",
            "store_auto",
            "store_missing",
            "store_unsupported",
            "profile_keyring",
        ] {
            let (_root, s) = service(mode);
            let id = create(&s);
            let error = s.usage(&id).unwrap_err();
            assert_eq!(error.kind, "isolation_failed");
            let job = s.login(&id).unwrap()["jobId"].as_str().unwrap().to_owned();
            let v = terminal(&s, &id, &job);
            assert_eq!(v["state"], "failed");
            assert_eq!(v["error"]["kind"], "isolation_failed");
            assert!(!v.to_string().contains("SECRET"));
            assert!(!s.root.join(&id).join("auth.json").exists());
            assert!(!s.root.join(".account-rpc-reached").exists());
        }
    }
    #[test]
    fn codex_certificate_override_survives_at_real_child_boundary() {
        assert!(!is_auth_override("codex_ca_certificate"));
        let home = tempfile::tempdir().unwrap();
        let certificate = home.path().join("synthetic-ca.pem");
        fs::write(&certificate, "synthetic certificate fixture").unwrap();
        let mut c = Command::new(fixture("success"));
        c.env("CODEX_CA_CERTIFICATE", &certificate)
            .env("CTZ_EXPECT_CA_CERTIFICATE", &certificate)
            .env("CODEX_AUTH_TOKEN", "SECRET");
        isolate_command(&mut c, home.path());
        c.args(["app-server", "--listen", "stdio://"]);
        quiet(&mut c);
        assert!(c.status().unwrap().success());
    }
    #[test]
    fn owned_profile_removal_survives_deleted_or_replaced_cli_but_execution_stays_denied() {
        for deleted in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let cli = root
                .path()
                .join(if cfg!(windows) { "fixed.exe" } else { "fixed" });
            fs::copy(fixture("success"), &cli).unwrap();
            let s = Service::for_test(
                root.path().join("account-profiles"),
                cli.clone(),
                Duration::from_secs(1),
            );
            let id = create(&s);
            fs::write(
                s.root.join(&id).join("auth.json"),
                "synthetic credential marker",
            )
            .unwrap();
            if deleted {
                fs::remove_file(&cli).unwrap();
            } else {
                let mut f = OpenOptions::new().append(true).open(&cli).unwrap();
                f.write_all(b"replaced").unwrap();
            }
            assert_eq!(s.usage(&id).unwrap_err().kind, "unavailable");
            assert_eq!(s.login(&id).unwrap_err().kind, "unavailable");
            assert_eq!(s.remove(&id).unwrap()["removed"], true);
            assert!(!s.root.join(id).exists());
        }
    }
    #[test]
    fn cancelled_removed_or_shutdown_job_never_dispatches_browser_after_cleanup_wins() {
        for action in ["cancel", "remove", "shutdown"] {
            let (_root, mut s) = service("success");
            let calls = Arc::new(AtomicU64::new(0));
            let opened = calls.clone();
            Arc::get_mut(&mut s).unwrap().browser = Some(Arc::new(move |_| {
                opened.fetch_add(1, Ordering::SeqCst);
                Ok(())
            }));
            let id = create(&s);
            let job = "synthetic-job".to_owned();
            let cancel = Arc::new(AtomicBool::new(false));
            let mut state = s.state.lock().unwrap();
            state.jobs.insert(
                id.clone(),
                Job {
                    id: job.clone(),
                    state: "starting",
                    error: None,
                    cancel: cancel.clone(),
                },
            );
            let barrier = Arc::new(std::sync::Barrier::new(2));
            let gate = barrier.clone();
            let worker = s.clone();
            let source = id.clone();
            let generation = job.clone();
            let dispatch = thread::spawn(move || {
                gate.wait();
                worker.dispatch_browser(
                    &source,
                    &generation,
                    "https://auth.openai.com/authorize?synthetic",
                )
            });
            barrier.wait();
            // Hold the exact cancellation lock while cleanup wins. Dispatch is blocked behind it.
            match action {
                "cancel" => {
                    let j = state.jobs.get_mut(&id).unwrap();
                    j.state = "cancelled";
                    j.cancel.store(true, Ordering::SeqCst);
                }
                "remove" => {
                    state.jobs.remove(&id);
                    cancel.store(true, Ordering::SeqCst);
                }
                _ => {
                    state.shutdown = true;
                    let j = state.jobs.get_mut(&id).unwrap();
                    j.state = "cancelled";
                    j.cancel.store(true, Ordering::SeqCst);
                }
            }
            drop(state);
            assert_eq!(dispatch.join().unwrap().unwrap_err().kind, "cancelled");
            assert_eq!(calls.load(Ordering::SeqCst), 0);
        }
    }
    #[test]
    fn browser_dispatch_keeps_cancel_lock_until_fake_opener_is_invoked() {
        let (_root, mut s) = service("success");
        let entered = Arc::new(std::sync::Barrier::new(2));
        let release = Arc::new(std::sync::Barrier::new(2));
        let gate = entered.clone();
        let finish = release.clone();
        let calls = Arc::new(AtomicU64::new(0));
        let opened = calls.clone();
        Arc::get_mut(&mut s).unwrap().browser = Some(Arc::new(move |_| {
            opened.fetch_add(1, Ordering::SeqCst);
            gate.wait();
            finish.wait();
            Ok(())
        }));
        let id = create(&s);
        let job = "synthetic-job".to_owned();
        s.state.lock().unwrap().jobs.insert(
            id.clone(),
            Job {
                id: job.clone(),
                state: "starting",
                error: None,
                cancel: Arc::new(AtomicBool::new(false)),
            },
        );
        let worker = s.clone();
        let source = id.clone();
        let generation = job.clone();
        let dispatch = thread::spawn(move || {
            worker.dispatch_browser(
                &source,
                &generation,
                "https://auth.openai.com/authorize?synthetic",
            )
        });
        entered.wait();
        let dispatch_owns_cancel_lock = s.state.try_lock().is_err();
        let cleanup = s.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let cancel = thread::spawn(move || {
            let v = cleanup.cancel(&id, &job);
            tx.send(v).unwrap();
        });
        release.wait();
        dispatch.join().unwrap().unwrap();
        assert!(
            dispatch_owns_cancel_lock,
            "browser dispatch must own the same lock as cancellation"
        );
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(2)).unwrap().unwrap()["state"],
            "cancelled"
        );
        cancel.join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
}
