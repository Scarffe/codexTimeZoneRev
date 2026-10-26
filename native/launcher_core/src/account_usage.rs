//! Read account usage through the installed Codex protocol, without handling credentials.
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

const MAX_LINE: u64 = 2 * 1024 * 1024;
const QUERY_TIMEOUT: Duration = Duration::from_secs(60);

fn bundled_candidates(desktop: &Path) -> Vec<PathBuf> {
    if cfg!(windows) {
        let root = desktop.parent().unwrap_or(desktop);
        vec![
            root.join("resources/codex.exe"),
            root.join("resources/bin/codex.exe"),
        ]
    } else {
        vec![
            desktop.join("Contents/Resources/codex"),
            desktop.join("Contents/Resources/bin/codex"),
        ]
    }
}

pub(crate) fn cli_paths(desktop: Option<&Path>) -> Result<Vec<PathBuf>, String> {
    let mut candidates = desktop.map(bundled_candidates).unwrap_or_default();
    #[cfg(windows)]
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        // The desktop app exports its current CLI into a versioned bin directory.
        if let Ok(entries) = fs::read_dir(PathBuf::from(local).join("OpenAI/Codex/bin")) {
            let mut installed: Vec<_> = entries
                .flatten()
                .map(|e| e.path().join("codex.exe"))
                .filter(|p| p.is_file())
                .collect();
            installed.sort_by_key(|p| {
                std::cmp::Reverse(fs::metadata(p).and_then(|m| m.modified()).ok())
            });
            candidates.extend(installed);
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for root in std::env::split_paths(&path) {
            let cli = root.join(if cfg!(windows) { "codex.exe" } else { "codex" });
            // Do not accidentally execute the desktop UI named Codex.exe.
            if !root.join("icudtl.dat").exists() {
                candidates.push(cli);
            }
        }
    }
    #[cfg(target_os = "macos")]
    candidates.extend([
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
    ]);
    candidates.retain(|p| p.is_file());
    if candidates.is_empty() {
        Err("未找到 Codex 账号查询组件，请安装或更新 Codex 客户端 / Codex CLI 后重试。".into())
    } else {
        Ok(candidates)
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum RpcError {
    Unsupported,
    Auth,
    Timeout,
    RateLimited,
    Failed,
    Cancelled,
    IdentityChanged,
    Isolation,
}
impl RpcError {
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::Auth => "auth_required",
            Self::Timeout => "timeout",
            Self::RateLimited => "rate_limited",
            Self::Failed => "network",
            Self::Cancelled => "cancelled",
            Self::IdentityChanged => "identity_changed",
            Self::Isolation => "isolation_failed",
        }
    }
    fn message(&self) -> &'static str {
        match self {
            Self::Unsupported => "当前 Codex 版本不支持此统计，请更新客户端后重试。",
            Self::Auth => "登录状态已失效，请在 Codex 中重新登录后重试。",
            Self::Timeout => "查询超时，请检查 Codex 的网络或代理设置后重试。",
            Self::RateLimited => "查询受到限流，请稍后重试。",
            Self::Failed => "无法读取账号数据，请检查 Codex 的登录状态和网络后重试。",
            Self::Cancelled => "操作已取消。",
            Self::IdentityChanged => "查询期间账号已切换，请重新查询。",
            Self::Isolation => "账号凭据存储隔离验证失败，操作已停止。",
        }
    }
}

pub(crate) struct Rpc {
    #[cfg(windows)]
    _job: QueryJob,
    child: Child,
    input: ChildStdin,
    output: Receiver<Result<Value, RpcError>>,
    next_id: u32,
    deadline: Instant,
    cancel: Arc<AtomicBool>,
    notifications: std::collections::VecDeque<Value>,
    profile_home: Option<PathBuf>,
    strict_error_codes: bool,
}

// Kill only this query's app-server if the isolated launcher exits unexpectedly.
#[cfg(windows)]
struct QueryJob(windows::Win32::Foundation::HANDLE);
// SAFETY: a Job handle is a process-wide kernel object, not a thread-affine
// resource. Ownership moves with Rpc; its sole Drop closes it exactly once.
#[cfg(windows)]
unsafe impl Send for QueryJob {}
#[cfg(windows)]
impl QueryJob {
    fn attach(child: &Child) -> Result<Self, String> {
        use std::{mem::size_of, os::windows::io::AsRawHandle};
        use windows::Win32::{Foundation::HANDLE, System::JobObjects::*};
        unsafe {
            let job = Self(CreateJobObjectW(None, None).map_err(|_| "无法创建账号查询隔离环境。")?);
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
            .map_err(|_| "无法设置账号查询隔离环境。")?;
            AssignProcessToJobObject(job.0, HANDLE(child.as_raw_handle()))
                .map_err(|_| "无法隔离账号查询进程，已停止。")?;
            Ok(job)
        }
    }
}
#[cfg(windows)]
impl Drop for QueryJob {
    fn drop(&mut self) {
        unsafe {
            let _ = windows::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

impl Rpc {
    fn start(cli: &Path, timeout: Duration) -> Result<Self, String> {
        Self::start_options(cli, timeout, None, Arc::new(AtomicBool::new(false)))
    }

    pub(crate) fn start_options(
        cli: &Path,
        timeout: Duration,
        home: Option<&Path>,
        cancel: Arc<AtomicBool>,
    ) -> Result<Self, String> {
        let mut command = Command::new(cli);
        if let Some(home) = home {
            super::account_sources::isolate_command(&mut command, home);
        }
        command.arg("app-server");
        if home.is_some() {
            command.arg("--strict-config");
        }
        command
            .args(["--listen", "stdio://"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        let mut child = command
            .spawn()
            .map_err(|_| "无法启动 Codex 账号查询组件，请检查客户端安装。".to_string())?;
        #[cfg(windows)]
        let job = match QueryJob::attach(&child) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let input = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let (sender, output) = mpsc::sync_channel(16);
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let read = reader
                    .by_ref()
                    .take(MAX_LINE + 1)
                    .read_until(b'\n', &mut line);
                let result = match read {
                    Ok(0) | Err(_) => Err(RpcError::Failed),
                    Ok(_) if line.len() as u64 > MAX_LINE => Err(RpcError::Failed),
                    Ok(_) => serde_json::from_slice(&line).map_err(|_| RpcError::Failed),
                };
                let terminal = result.is_err();
                if sender.send(result).is_err() || terminal {
                    break;
                }
            }
        });
        Ok(Self {
            #[cfg(windows)]
            _job: job,
            child,
            input,
            output,
            next_id: 1,
            deadline: Instant::now() + timeout,
            cancel,
            notifications: Default::default(),
            profile_home: home.map(Path::to_path_buf),
            strict_error_codes: false,
        })
    }

    pub(crate) fn send(&mut self, value: Value) -> Result<(), RpcError> {
        writeln!(self.input, "{value}")
            .and_then(|_| self.input.flush())
            .map_err(|_| RpcError::Failed)
    }

    pub(crate) fn restrict_errors_to_codes(&mut self) {
        self.strict_error_codes = true;
    }

    pub(crate) fn renew_deadline(&mut self, timeout: Duration) -> Result<(), RpcError> {
        if self.cancel.load(Ordering::SeqCst) {
            return Err(RpcError::Cancelled);
        }
        self.deadline = Instant::now() + timeout;
        Ok(())
    }

    pub(crate) fn call(&mut self, method: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({"id": id, "method": method, "params": params}))?;
        let per_call = match method {
            "initialize" | "account/usage/read" => 15,
            "account/rateLimits/read" => 20,
            _ => 5,
        };
        let deadline = self
            .deadline
            .min(Instant::now() + Duration::from_secs(per_call));
        loop {
            let message = self.receive(deadline)?;
            if message["id"] != id {
                if message["method"] == "account/login/completed" && self.notifications.len() < 16 {
                    self.notifications.push_back(message);
                }
                continue;
            }
            if let Some(error) = message.get("error") {
                // Raw server errors and stderr can contain sensitive data; never return or log them.
                // Private credential consumers classify only protocol codes.
                // Existing observation adapters keep their compatibility path.
                let text = if self.strict_error_codes {
                    String::new()
                } else {
                    error["message"]
                        .as_str()
                        .unwrap_or_default()
                        .to_ascii_lowercase()
                };
                return Err(if error["code"] == -32601 {
                    RpcError::Unsupported
                } else if error["code"] == 401
                    || text.contains("401")
                    || text.contains("unauthorized")
                    || text.contains("not authenticated")
                {
                    RpcError::Auth
                } else if error["code"] == 429
                    || text.contains("429")
                    || text.contains("rate limit")
                {
                    RpcError::RateLimited
                } else {
                    RpcError::Failed
                });
            }
            return message.get("result").cloned().ok_or(RpcError::Failed);
        }
    }

    fn receive(&self, deadline: Instant) -> Result<Value, RpcError> {
        loop {
            if self.cancel.load(Ordering::SeqCst) {
                return Err(RpcError::Cancelled);
            }
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or(RpcError::Timeout)?;
            match self
                .output
                .recv_timeout(remaining.min(Duration::from_millis(50)))
            {
                Ok(v) => return v,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => return Err(RpcError::Failed),
            }
        }
    }
    pub(crate) fn initialize(&mut self) -> Result<(), RpcError> {
        let handshake = self.call("initialize",json!({"clientInfo":{"name":"codex_timezone","version":env!("CARGO_PKG_VERSION")},"capabilities":null}))?;
        if let Some(expected) = &self.profile_home {
            let reported = handshake["codexHome"].as_str().ok_or(RpcError::Isolation)?;
            let reported = std::fs::canonicalize(reported).map_err(|_| RpcError::Isolation)?;
            let expected = std::fs::canonicalize(expected).map_err(|_| RpcError::Isolation)?;
            if !reported.is_dir() || reported != expected {
                return Err(RpcError::Isolation);
            }
        }
        self.send(json!({"method":"initialized","params":{}}))?;
        if let Some(home) = self.profile_home.clone() {
            // Administrator policy may override -c. Inspect only the effective
            // store value, discard every other config field, and fail closed
            // before any account/auth RPC can consult shared credentials.
            let config = self
                .call("config/read", json!({"includeLayers":false,"cwd":home}))
                .map_err(|e| match e {
                    RpcError::Cancelled | RpcError::Timeout => e,
                    _ => RpcError::Isolation,
                })?;
            let file_store = config["config"]["cli_auth_credentials_store"] == "file";
            drop(config);
            if !file_store {
                return Err(RpcError::Isolation);
            }
        }
        Ok(())
    }
    pub(crate) fn login_completion(&mut self, login_id: &str) -> Result<bool, RpcError> {
        loop {
            let message = if let Some(v) = self.notifications.pop_front() {
                v
            } else {
                self.receive(self.deadline)?
            };
            if message["method"] == "account/login/completed"
                && message["params"]["loginId"].as_str() == Some(login_id)
            {
                return message["params"]["success"]
                    .as_bool()
                    .ok_or(RpcError::Failed);
            }
        }
    }
}

pub(crate) fn read_typed(rpc: &mut Rpc, details: bool) -> Result<Value, RpcError> {
    rpc.initialize()?;
    read_initialized_typed(rpc, details)
}

pub(crate) fn read_initialized_typed(rpc: &mut Rpc, details: bool) -> Result<Value, RpcError> {
    let account = rpc.call("account/read", json!({"refreshToken":false}))?["account"].clone();
    if account.is_null() {
        return Err(RpcError::Auth);
    }
    if account["type"] != "chatgpt" {
        return Err(RpcError::Unsupported);
    }
    let limits = rpc.call("account/rateLimits/read", json!({}));
    let tokens = if details {
        rpc.call("account/usage/read", json!({}))
    } else {
        Ok(Value::Null)
    };
    if rpc.call("account/read", json!({"refreshToken":false}))?["account"] != account {
        return Err(RpcError::IdentityChanged);
    }
    let (limits, le) = match limits {
        Ok(v) => (
            json!({"rateLimits":v["rateLimits"],"rateLimitsByLimitId":v["rateLimitsByLimitId"]}),
            None,
        ),
        Err(e) => (Value::Null, Some(e)),
    };
    let (tokens, te) = match tokens {
        Ok(v) if !v.is_null() => (
            json!({"summary":v["summary"],"dailyUsageBuckets":v["dailyUsageBuckets"]}),
            None,
        ),
        Ok(_) => (Value::Null, None),
        Err(e) => (Value::Null, Some(e)),
    };
    if matches!(le, Some(RpcError::Auth)) {
        return Err(RpcError::Auth);
    }
    if limits.is_null() && tokens.is_null() {
        return Err(le.unwrap_or(RpcError::Failed));
    }
    let observed =
        json!({"type":account["type"],"email":account["email"],"planType":account["planType"]});
    Ok(
        json!({"account":{"email":account["email"],"planType":account["planType"]},"identityKey":observed.to_string(),"detailsIncluded":details,"limits":limits,"tokenUsage":tokens,
        "limitsError":le.map(|e|e.message()),"tokensError":te.map(|e|e.message()),"limitsErrorKind":le.map(|e|e.kind()),"tokensErrorKind":te.map(|e|e.kind())}),
    )
}

pub(crate) fn query_typed(
    desktop: Option<&Path>,
    details: bool,
    cancel: Arc<AtomicBool>,
) -> Result<Value, RpcError> {
    for cli in cli_paths(desktop).map_err(|_| RpcError::Unsupported)? {
        if cancel.load(Ordering::SeqCst) {
            return Err(RpcError::Cancelled);
        }
        if let Ok(mut rpc) = Rpc::start_options(&cli, QUERY_TIMEOUT, None, cancel.clone()) {
            return read_typed(&mut rpc, details);
        }
    }
    Err(RpcError::Failed)
}

impl Drop for Rpc {
    fn drop(&mut self) {
        // Own only this short-lived query process, never the running desktop client.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn read_usage_mode(rpc: &mut Rpc, details: bool) -> Result<Value, String> {
    rpc.call("initialize", json!({
        "clientInfo": {"name": "codex_timezone", "title": "Codex 时区启动器", "version": env!("CARGO_PKG_VERSION")},
        "capabilities": null
    })).map_err(|e| e.message())?;
    rpc.send(json!({"method": "initialized", "params": {}}))
        .map_err(|e| e.message())?;
    let account = rpc
        .call("account/read", json!({"refreshToken": false}))
        .map_err(|e| e.message())?["account"]
        .clone();
    if account.is_null() {
        return Err("未检测到已登录账号，请先在 Codex 中登录 ChatGPT 账号。".into());
    }
    if account["type"] != "chatgpt" {
        return Err(
            "当前登录方式不支持 ChatGPT 账号用量查询，请在 Codex 中使用 ChatGPT 账号登录。".into(),
        );
    }
    let limits = rpc.call("account/rateLimits/read", json!({}));
    let tokens = if details {
        rpc.call("account/usage/read", json!({}))
    } else {
        Ok(Value::Null)
    };
    let after = rpc
        .call("account/read", json!({"refreshToken": false}))
        .map_err(|e| e.message())?;
    if after["account"] != account {
        return Err("查询期间账号已切换，请重新查询。".into());
    }
    let (limits, limits_error) = match limits {
        Ok(v) => (
            json!({"rateLimits": v["rateLimits"], "rateLimitsByLimitId": v["rateLimitsByLimitId"]}),
            None,
        ),
        Err(e) => (Value::Null, Some(e.message())),
    };
    let (tokens, tokens_error) = if !details {
        (Value::Null, None)
    } else {
        match tokens {
            Ok(v) => (
                json!({"summary": v["summary"], "dailyUsageBuckets": v["dailyUsageBuckets"]}),
                None,
            ),
            Err(e) => (Value::Null, Some(e.message())),
        }
    };
    if limits.is_null() && tokens.is_null() {
        return Err(limits_error.unwrap_or("账号用量暂不可用。").into());
    }
    Ok(json!({
        "account": {"email": account["email"], "planType": account["planType"]},
        "identityKey": account.to_string(), "detailsIncluded": details,
        "limits": limits, "tokenUsage": tokens,
        "limitsError": limits_error, "tokensError": tokens_error,
    }))
}

#[cfg(test)]
fn read_usage(rpc: &mut Rpc) -> Result<Value, String> {
    read_usage_mode(rpc, true)
}

pub(crate) fn query(desktop: Option<&Path>, details: bool) -> Result<Value, String> {
    for cli in cli_paths(desktop)? {
        // Store package ACLs can prohibit executing its bundled CLI outside package
        // identity. Try the app's exported CLI before asking the user to reinstall.
        if let Ok(mut rpc) = Rpc::start(&cli, QUERY_TIMEOUT) {
            return read_usage_mode(&mut rpc, details);
        }
    }
    Err("无法启动 Codex 账号查询组件，请检查客户端安装。".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::OnceLock;
    fn fixture(mode: &str) -> PathBuf {
        static FIXTURES: OnceLock<tempfile::TempDir> = OnceLock::new();
        let root = FIXTURES.get_or_init(|| {
            let root = tempfile::tempdir().unwrap();
            let source = root.path().join("usage_cli.rs");
            fs::write(&source, include_str!("../tests/fixtures/usage_cli.rs")).unwrap();
            let executable = root.path().join(if cfg!(windows) {
                "success.exe"
            } else {
                "success"
            });
            let status = Command::new("rustc")
                .arg("--edition=2021")
                .arg(source)
                .arg("-o")
                .arg(&executable)
                .status()
                .unwrap();
            assert!(status.success());
            for mode in [
                "no_login",
                "api_key",
                "old",
                "limits_failure",
                "secret_failure",
                "switched",
                "timeout",
                "limits_only",
                "rate_limited",
                "current_args",
            ] {
                let target = root.path().join(if cfg!(windows) {
                    format!("{mode}.exe")
                } else {
                    mode.into()
                });
                fs::copy(&executable, target).unwrap();
            }
            root
        });
        root.path().join(if cfg!(windows) {
            format!("{mode}.exe")
        } else {
            mode.into()
        })
    }
    fn read_fixture(mode: &str) -> Result<Value, String> {
        read_usage(&mut Rpc::start(&fixture(mode), Duration::from_secs(10)).unwrap())
    }
    #[test]
    fn desktop_and_query_components_are_distinct() {
        let path = if cfg!(windows) {
            Path::new("client/Codex.exe")
        } else {
            Path::new("Codex.app")
        };
        assert!(bundled_candidates(path).iter().all(|p| p != path));
        assert!(
            bundled_candidates(path)[0]
                .to_string_lossy()
                .contains("resources")
                || bundled_candidates(path)[0]
                    .to_string_lossy()
                    .contains("Resources")
        );
    }
    #[test]
    fn lightweight_query_never_requests_full_token_statistics() {
        let mut rpc = Rpc::start(&fixture("limits_only"), Duration::from_secs(10)).unwrap();
        let value = read_usage_mode(&mut rpc, false).unwrap();
        assert!(value["tokenUsage"].is_null());
        assert_eq!(value["detailsIncluded"], false);
        assert!(value["identityKey"]
            .as_str()
            .unwrap()
            .contains("tester@example.com"));
    }
    #[test]
    fn current_observation_child_keeps_existing_startup_arguments() {
        let mut rpc = Rpc::start(&fixture("current_args"), Duration::from_secs(10)).unwrap();
        let value = read_typed(&mut rpc, false).unwrap();
        assert!(!value["limits"].is_null());
    }
    #[test]
    fn rate_limit_failure_is_sanitized_and_light_query_fails() {
        let mut rpc = Rpc::start(&fixture("rate_limited"), Duration::from_secs(10)).unwrap();
        let error = read_usage_mode(&mut rpc, false).unwrap_err();
        assert!(error.contains("限流"));
        assert!(!error.contains("SECRET"));
    }
    #[test]
    fn typed_current_adapter_keeps_details_and_partial_error_kinds() {
        let mut rpc = Rpc::start(&fixture("success"), Duration::from_secs(10)).unwrap();
        let full = read_typed(&mut rpc, true).unwrap();
        assert_eq!(full["tokenUsage"]["summary"]["lifetimeTokens"], 1234567);
        assert_eq!(full["detailsIncluded"], true);
        let mut rpc = Rpc::start(&fixture("old"), Duration::from_secs(10)).unwrap();
        let partial = read_typed(&mut rpc, true).unwrap();
        assert!(!partial["limits"].is_null());
        assert_eq!(partial["tokensErrorKind"], "unsupported");
        assert!(partial["tokenUsage"].is_null());
    }
    #[test]
    fn typed_current_adapter_auth_and_raw_failure_are_sanitized() {
        for (mode, kind) in [
            ("limits_failure", "auth_required"),
            ("secret_failure", "network"),
        ] {
            let mut rpc = Rpc::start(&fixture(mode), Duration::from_secs(10)).unwrap();
            let error = read_typed(&mut rpc, true).unwrap_err();
            assert_eq!(error.kind(), kind);
            assert!(!error.message().contains("SECRET"));
        }
    }
    #[cfg(windows)]
    #[test]
    fn query_job_closure_cleans_its_child() {
        let mut child = Command::new(fixture("timeout"))
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let job = QueryJob::attach(&child).unwrap();
        drop(job);
        let start = Instant::now();
        child.wait().unwrap();
        assert!(start.elapsed() < Duration::from_secs(3));
    }
    #[test]
    fn protocol_reads_account_limits_and_tokens_despite_notifications() {
        let result = read_fixture("success").unwrap();
        assert_eq!(result["account"]["email"], "tester@example.com");
        assert_eq!(result["limits"]["rateLimits"]["primary"]["usedPercent"], 8);
        assert_eq!(result["tokenUsage"]["summary"]["lifetimeTokens"], 1234567);
    }
    #[test]
    fn logged_out_and_api_key_accounts_are_explained() {
        assert!(read_fixture("no_login")
            .unwrap_err()
            .contains("未检测到已登录账号"));
        assert!(read_fixture("api_key")
            .unwrap_err()
            .contains("登录方式不支持"));
    }
    #[test]
    fn partial_stats_are_retained_on_old_versions_or_network_failure() {
        let old = read_fixture("old").unwrap();
        assert!(!old["limits"].is_null());
        assert!(old["tokenUsage"].is_null());
        assert!(old["tokensError"].as_str().unwrap().contains("版本不支持"));
        let partial = read_fixture("limits_failure").unwrap();
        assert!(partial["limits"].is_null());
        assert_eq!(partial["tokenUsage"]["summary"]["lifetimeTokens"], 1234567);
    }
    #[test]
    fn switches_are_rejected_and_server_error_secrets_are_not_returned() {
        assert!(read_fixture("switched").unwrap_err().contains("账号已切换"));
        assert!(!read_fixture("secret_failure")
            .unwrap_err()
            .contains("SECRET_DO_NOT_EXPOSE"));
    }
    #[test]
    fn timeout_kills_only_the_owned_query_process() {
        let executable = fixture("timeout");
        let start = Instant::now();
        let result = read_usage(&mut Rpc::start(&executable, Duration::from_millis(100)).unwrap());
        assert!(result.unwrap_err().contains("超时"));
        assert!(start.elapsed() < Duration::from_secs(3));
    }
}
