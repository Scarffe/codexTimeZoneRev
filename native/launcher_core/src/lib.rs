//! Versioned, ownership-explicit C ABI shared by the Flutter desktop runners.
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

mod account_sources;
mod account_usage;
mod benchmark;
#[path = "platform/common.rs"]
mod common;
mod desktop_auth;
#[cfg(test)]
mod desktop_auth_contract_tests;
#[cfg(windows)]
mod desktop_runtime_client;
#[cfg(all(test, windows))]
mod desktop_runtime_contract_tests;
#[cfg(windows)]
mod desktop_runtime_transport;
mod global_live;
mod global_monitor;
#[cfg(test)]
mod global_monitor_contract_tests;
#[cfg(windows)]
mod helper_control;
#[cfg(windows)]
mod helper_host;
#[cfg(target_os = "macos")]
#[path = "platform/mac/mod.rs"]
mod macos;
mod owned_stdio;
#[cfg(windows)]
mod proxy;
mod runtime_helper;
mod runtime_bootstrap;
mod session_metrics;
mod session_names;
mod task_protocol;
mod tasks;
// K3.0 is an offline contract experiment, absent from release dispatch/binaries.
#[cfg(test)]
mod task_execution;
#[cfg(all(test, windows))]
mod task_process;
#[cfg(windows)]
#[path = "platform/win/mod.rs"]
mod windows;

static REQUEST_LOCK: Mutex<()> = Mutex::new(());

#[derive(Deserialize)]
struct Request {
    version: u32,
    command: String,
    #[serde(default)]
    payload: Value,
}

fn dispatch(request: &str) -> Result<Value, String> {
    let request: Request = serde_json::from_str(request).map_err(|e| format!("请求无效：{e}"))?;
    if request.version != 1 {
        return Err("原生接口版本不匹配，请重新构建应用。".into());
    }
    // Proxy discovery is read-only and can block on PAC/WPAD. It must never
    // hold the lock protecting settings and process launches.
    #[cfg(windows)]
    if request.command == "proxy_for_url" {
        return proxy::resolve(request.payload["url"].as_str().unwrap_or_default())
            .map(|proxy| json!({"proxy": proxy}));
    }
    if request.command == "session_metrics" {
        return session_metrics::execute(request.payload);
    }
    #[cfg(windows)]
    if request.command == "desktop_runtime" {
        return desktop_runtime_client::execute(request.payload);
    }
    if request.command == "global_monitor" {
        return global_monitor::execute(request.payload);
    }
    if request.command == "global_live" {
        return global_live::execute(request.payload);
    }
    if request.command == "desktop_auth_capabilities" {
        return Ok(desktop_auth::capabilities());
    }
    // Benchmark jobs own a separate runtime; never wait on REQUEST_LOCK.
    if request.command.starts_with("benchmark_") {
        return benchmark::execute(&request.command, request.payload);
    }
    if request.command.starts_with("account_source_") {
        return account_sources::execute(&request.command, request.payload);
    }
    if request.command.starts_with("task_") {
        return tasks::execute(&request.command, request.payload);
    }
    // Account reads can wait on the network. Never hold the settings/launch lock.
    if request.command == "account_usage" {
        #[cfg(windows)]
        return windows::account_usage(request.payload);
        #[cfg(target_os = "macos")]
        return macos::account_usage(request.payload);
        #[cfg(not(any(windows, target_os = "macos")))]
        return Err("仅支持 Windows 和 macOS。".into());
    }
    // Reject unknown commands before initializing OS services or touching files.
    if ![
        "bootstrap",
        "discover",
        "validate",
        "save",
        "launch",
        "launch_antigravity",
        "check_launch",
        "repair_launch",
        "create_shortcut",
        "launch_dream_skin",
        "reapply_dream_skin",
    ]
    .contains(&request.command.as_str())
    {
        return Err(format!("未知命令：{}", request.command));
    }
    let _guard = REQUEST_LOCK
        .lock()
        .map_err(|_| "系统功能锁不可用，请重启启动器。".to_string())?;
    #[cfg(windows)]
    {
        windows::execute(&request.command, request.payload)
    }
    #[cfg(target_os = "macos")]
    {
        macos::execute(&request.command, request.payload)
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        Err("仅支持 Windows 和 macOS。".into())
    }
}

fn response(request: &str) -> String {
    let result = std::panic::catch_unwind(|| dispatch(request));
    let envelope = match result {
        Ok(Ok(data)) => json!({"version":1,"ok":true,"data":data}),
        Ok(Err(error)) => json!({"version":1,"ok":false,"error":error}),
        Err(_) => json!({"version":1,"ok":false,"error":"系统操作异常，请重启启动器后重试。"}),
    };
    envelope.to_string()
}

#[no_mangle]
pub extern "C" fn launcher_abi_version() -> u32 {
    1
}

/// Returns an owned UTF-8 JSON string. Free exactly once with launcher_free.
///
/// # Safety
/// A non-null request must point to a live NUL-terminated UTF-8 string for the
/// duration of this call. Invoke off the UI thread; calls can block for 45s+.
#[no_mangle]
pub unsafe extern "C" fn launcher_call(request: *const c_char) -> *mut c_char {
    let value = if request.is_null() {
        json!({"version":1,"ok":false,"error":"请求不能为空。"}).to_string()
    } else {
        match CStr::from_ptr(request).to_str() {
            Ok(request) => response(request),
            Err(_) => json!({"version":1,"ok":false,"error":"请求必须是 UTF-8。"}).to_string(),
        }
    };
    // JSON serialization escapes all embedded NULs.
    CString::new(value)
        .expect("JSON contains no raw NUL")
        .into_raw()
}

/// # Safety
/// pointer must be null or an unfreed pointer returned by launcher_call.
#[no_mangle]
pub unsafe extern "C" fn launcher_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_source_guard_bypasses_settings_lock_without_auth_mutation() {
        let guard = REQUEST_LOCK.lock().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let request = json!({"version":1,"command":"account_source_remove","payload":{"sourceId":"current"}});
            tx.send(dispatch(&request.to_string())).unwrap();
        });
        let result = rx.recv_timeout(std::time::Duration::from_millis(500));
        drop(guard);
        worker.join().unwrap();
        let data = result
            .expect("source command blocked behind settings lock")
            .unwrap();
        assert_eq!(data["ok"], false);
        assert_eq!(data["error"]["kind"], "protected_source");
    }

    #[test]
    fn benchmark_fast_path_and_stalled_body_leave_settings_lock_available() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::mpsc;
        use std::time::{Duration, Instant};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let request = json!({"version":1,"command":"benchmark_start","payload":{
            "mode":"local_replay","protocol":"chat_completions","baseUrl":format!("http://{}/v1",listener.local_addr().unwrap()),
            "model":"fixture","prompt":"synthetic","resolvedProxy":"DIRECT","timeoutMs":2000,"idleTimeoutMs":1000}}).to_string();
        let guard = REQUEST_LOCK.lock().unwrap();
        let (tx, rx) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            let _ = tx.send(dispatch(&request));
        });
        let result = rx.recv_timeout(Duration::from_millis(200));
        // Always release before join/assert, including when regression blocks.
        drop(guard);
        thread.join().unwrap();
        let result = result
            .expect("benchmark_start blocked behind REQUEST_LOCK")
            .unwrap();
        let id = result["runId"].as_str().unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut socket = loop {
            if let Ok((socket, _)) = listener.accept() {
                break socket;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        };
        // Windows accepted sockets inherit the nonblocking listener mode.
        // Use a bounded blocking read so connect-before-POST is not a race.
        socket.set_nonblocking(false).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let mut buffer = [0; 4096];
        assert!(socket.read(&mut buffer).unwrap() > 0);
        socket
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let snapshot = benchmark::execute("benchmark_status", json!({"runId":id})).unwrap();
            if snapshot["state"] == "streaming" {
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        let settings_available = REQUEST_LOCK.try_lock().is_ok();
        benchmark::execute("benchmark_shutdown", json!({"runId":id})).unwrap();
        assert!(
            settings_available,
            "stalled HTTP body must not own settings lock"
        );
    }

    #[test]
    fn invalid_requests_are_errors_without_platform_side_effects() {
        for request in [
            "not json",
            r#"{"version":2,"command":"bootstrap"}"#,
            r#"{"version":1,"command":"invalid"}"#,
        ] {
            let value: Value = serde_json::from_str(&response(request)).unwrap();
            assert_eq!(value["ok"], false);
            assert_eq!(value["version"], 1);
            assert!(!value["error"].as_str().unwrap().is_empty());
        }
    }

    #[test]
    fn ffi_round_trip_and_null_handling() {
        unsafe {
            for _ in 0..100 {
                let request = CString::new(r#"{"version":1,"command":"中文未知命令"}"#).unwrap();
                let pointer = launcher_call(request.as_ptr());
                let result: Value =
                    serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap();
                assert!(result["error"].as_str().unwrap().contains("中文未知命令"));
                launcher_free(pointer);
            }
            let pointer = launcher_call(std::ptr::null());
            assert!(!pointer.is_null());
            launcher_free(pointer);
            launcher_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn timezone_contract_preserves_posix_sign_and_bounds() {
        let mut settings = common::Settings::default();
        settings.mode = "offset".into();
        for (offset, expected) in [(-12, "Etc/GMT+12"), (0, "Etc/UTC"), (14, "Etc/GMT-14")] {
            settings.offset = offset;
            assert_eq!(common::tz(&settings).unwrap(), expected);
        }
        settings.offset = 15;
        assert!(common::tz(&settings).is_err());
        settings.mode = "zone".into();
        settings.zone_id = "not/a/zone".into();
        assert!(common::tz(&settings).is_err());
    }
}

/// Entry for the colocated native owner process; no public credential dispatcher.
#[doc(hidden)]
pub fn helper_entry() -> i32 {
    #[cfg(windows)]
    {
        helper_host::main_entry()
    }
    #[cfg(not(windows))]
    {
        2
    }
}
