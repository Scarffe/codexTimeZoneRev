//! Read account usage through the installed Codex protocol, without handling credentials.
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};

const MAX_LINE: u64 = 2 * 1024 * 1024;
const QUERY_TIMEOUT: Duration = Duration::from_secs(60);

fn bundled_candidates(desktop: &Path) -> Vec<PathBuf> {
    if cfg!(windows) {
        let root = desktop.parent().unwrap_or(desktop);
        vec![root.join("resources/codex.exe"), root.join("resources/bin/codex.exe")]
    } else {
        vec![desktop.join("Contents/Resources/codex"), desktop.join("Contents/Resources/bin/codex")]
    }
}

fn cli_paths(desktop: Option<&Path>) -> Result<Vec<PathBuf>, String> {
    let mut candidates = desktop.map(bundled_candidates).unwrap_or_default();
    #[cfg(windows)]
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        // The desktop app exports its current CLI into a versioned bin directory.
        if let Ok(entries) = fs::read_dir(PathBuf::from(local).join("OpenAI/Codex/bin")) {
            let mut installed: Vec<_> = entries.flatten().map(|e| e.path().join("codex.exe"))
                .filter(|p| p.is_file()).collect();
            installed.sort_by_key(|p| std::cmp::Reverse(fs::metadata(p).and_then(|m| m.modified()).ok()));
            candidates.extend(installed);
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for root in std::env::split_paths(&path) {
            let cli = root.join(if cfg!(windows) { "codex.exe" } else { "codex" });
            // Do not accidentally execute the desktop UI named Codex.exe.
            if !root.join("icudtl.dat").exists() { candidates.push(cli); }
        }
    }
    #[cfg(target_os = "macos")]
    candidates.extend([PathBuf::from("/opt/homebrew/bin/codex"), PathBuf::from("/usr/local/bin/codex")]);
    candidates.retain(|p| p.is_file());
    if candidates.is_empty() {
        Err("未找到 Codex 账号查询组件，请安装或更新 Codex 客户端 / Codex CLI 后重试。".into())
    } else { Ok(candidates) }
}

#[derive(Debug)]
enum RpcError { Unsupported, Auth, Timeout, Failed }
impl RpcError {
    fn message(&self) -> &'static str {
        match self {
            Self::Unsupported => "当前 Codex 版本不支持此统计，请更新客户端后重试。",
            Self::Auth => "登录状态已失效，请在 Codex 中重新登录后重试。",
            Self::Timeout => "查询超时，请检查 Codex 的网络或代理设置后重试。",
            Self::Failed => "无法读取账号数据，请检查 Codex 的登录状态和网络后重试。",
        }
    }
}

struct Rpc {
    child: Child,
    input: ChildStdin,
    output: Receiver<Result<Value, RpcError>>,
    next_id: u32,
    deadline: Instant,
}

impl Rpc {
    fn start(cli: &Path, timeout: Duration) -> Result<Self, String> {
        let mut command = Command::new(cli);
        command.args(["app-server", "--listen", "stdio://"])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        let mut child = command.spawn().map_err(|_| "无法启动 Codex 账号查询组件，请检查客户端安装。".to_string())?;
        let input = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let (sender, output) = mpsc::sync_channel(16);
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let read = reader.by_ref().take(MAX_LINE + 1).read_until(b'\n', &mut line);
                let result = match read {
                    Ok(0) | Err(_) => Err(RpcError::Failed),
                    Ok(_) if line.len() as u64 > MAX_LINE => Err(RpcError::Failed),
                    Ok(_) => serde_json::from_slice(&line).map_err(|_| RpcError::Failed),
                };
                let terminal = result.is_err();
                if sender.send(result).is_err() || terminal { break; }
            }
        });
        Ok(Self { child, input, output, next_id: 1, deadline: Instant::now() + timeout })
    }

    fn send(&mut self, value: Value) -> Result<(), RpcError> {
        writeln!(self.input, "{value}").and_then(|_| self.input.flush()).map_err(|_| RpcError::Failed)
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value, RpcError> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({"id": id, "method": method, "params": params}))?;
        let per_call = match method {
            "initialize" | "account/usage/read" => 15,
            "account/rateLimits/read" => 20,
            _ => 5,
        };
        let deadline = self.deadline.min(Instant::now() + Duration::from_secs(per_call));
        loop {
            let remaining = deadline.checked_duration_since(Instant::now()).ok_or(RpcError::Timeout)?;
            let message = self.output.recv_timeout(remaining).map_err(|e| match e {
                mpsc::RecvTimeoutError::Timeout => RpcError::Timeout,
                _ => RpcError::Failed,
            })??;
            if message["id"] != id { continue; }
            if let Some(error) = message.get("error") {
                // Raw server errors and stderr can contain sensitive data; never return or log them.
                let text = error["message"].as_str().unwrap_or_default().to_ascii_lowercase();
                return Err(if error["code"] == -32601 {
                    RpcError::Unsupported
                } else if text.contains("401") || text.contains("unauthorized") || text.contains("not authenticated") {
                    RpcError::Auth
                } else { RpcError::Failed });
            }
            return message.get("result").cloned().ok_or(RpcError::Failed);
        }
    }
}

impl Drop for Rpc {
    fn drop(&mut self) {
        // Own only this short-lived query process, never the running desktop client.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn read_usage(rpc: &mut Rpc) -> Result<Value, String> {
    rpc.call("initialize", json!({
        "clientInfo": {"name": "codex_timezone", "title": "Codex 时区启动器", "version": env!("CARGO_PKG_VERSION")},
        "capabilities": null
    })).map_err(|e| e.message())?;
    rpc.send(json!({"method": "initialized", "params": {}})).map_err(|e| e.message())?;
    let account = rpc.call("account/read", json!({"refreshToken": false})).map_err(|e| e.message())?["account"].clone();
    if account.is_null() { return Err("未检测到已登录账号，请先在 Codex 中登录 ChatGPT 账号。".into()); }
    if account["type"] != "chatgpt" {
        return Err("当前登录方式不支持 ChatGPT 账号用量查询，请在 Codex 中使用 ChatGPT 账号登录。".into());
    }
    let limits = rpc.call("account/rateLimits/read", json!({}));
    let tokens = rpc.call("account/usage/read", json!({}));
    let after = rpc.call("account/read", json!({"refreshToken": false})).map_err(|e| e.message())?;
    if after["account"] != account { return Err("查询期间账号已切换，请重新查询。".into()); }
    let (limits, limits_error) = match limits {
        Ok(v) => (json!({"rateLimits": v["rateLimits"], "rateLimitsByLimitId": v["rateLimitsByLimitId"]}), None),
        Err(e) => (Value::Null, Some(e.message())),
    };
    let (tokens, tokens_error) = match tokens {
        Ok(v) => (json!({"summary": v["summary"], "dailyUsageBuckets": v["dailyUsageBuckets"]}), None),
        Err(e) => (Value::Null, Some(e.message())),
    };
    if limits.is_null() && tokens.is_null() {
        return Err(limits_error.unwrap_or("账号用量暂不可用。").into());
    }
    Ok(json!({
        "account": {"email": account["email"], "planType": account["planType"]},
        "limits": limits, "tokenUsage": tokens,
        "limitsError": limits_error, "tokensError": tokens_error,
    }))
}

pub(crate) fn query(desktop: Option<&Path>) -> Result<Value, String> {
    for cli in cli_paths(desktop)? {
        // Store package ACLs can prohibit executing its bundled CLI outside package
        // identity. Try the app's exported CLI before asking the user to reinstall.
        if let Ok(mut rpc) = Rpc::start(&cli, QUERY_TIMEOUT) {
            return read_usage(&mut rpc);
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
            let executable = root.path().join(if cfg!(windows) { "success.exe" } else { "success" });
            let status = Command::new("rustc").arg("--edition=2021").arg(source).arg("-o").arg(&executable).status().unwrap();
            assert!(status.success());
            for mode in ["no_login", "api_key", "old", "limits_failure", "secret_failure", "switched", "timeout"] {
                let target = root.path().join(if cfg!(windows) { format!("{mode}.exe") } else { mode.into() });
                fs::copy(&executable, target).unwrap();
            }
            root
        });
        root.path().join(if cfg!(windows) { format!("{mode}.exe") } else { mode.into() })
    }
    fn read_fixture(mode: &str) -> Result<Value, String> {
        read_usage(&mut Rpc::start(&fixture(mode), Duration::from_secs(10)).unwrap())
    }
    #[test]
    fn desktop_and_query_components_are_distinct() {
        let path = if cfg!(windows) { Path::new("client/Codex.exe") } else { Path::new("Codex.app") };
        assert!(bundled_candidates(path).iter().all(|p| p != path));
        assert!(bundled_candidates(path)[0].to_string_lossy().contains("resources") || bundled_candidates(path)[0].to_string_lossy().contains("Resources"));
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
        assert!(read_fixture("no_login").unwrap_err().contains("未检测到已登录账号"));
        assert!(read_fixture("api_key").unwrap_err().contains("登录方式不支持"));
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
        assert!(!read_fixture("secret_failure").unwrap_err().contains("SECRET_DO_NOT_EXPOSE"));
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
