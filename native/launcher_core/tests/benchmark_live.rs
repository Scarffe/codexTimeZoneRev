//! Public production FFI -> live admission -> loopback HTTP/SSE, synthetic key only.
use codex_timezone_core::{launcher_call, launcher_free};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    io::{Read, Write},
    net::TcpListener,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const KEY: &str = "synthetic-m4-secret-sentinel";
const PROMPT: &str = "synthetic-m4-prompt-sentinel";
const SSE: &str = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";

fn call(command: &str, payload: Value) -> Value {
    let input =
        CString::new(json!({"version":1,"command":command,"payload":payload}).to_string()).unwrap();
    unsafe {
        let out = launcher_call(input.as_ptr());
        assert!(!out.is_null());
        let response = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        launcher_free(out);
        response
    }
}
fn ok(command: &str, payload: Value) -> Value {
    let response = call(command, payload);
    // Do not print request payloads: they contain an in-memory credential.
    assert_eq!(response["ok"], true, "{command}: {response}");
    response["data"].clone()
}
fn request(base: &str, protocol: &str) -> Value {
    json!({"mode":"live","protocol":protocol,"baseUrl":base,"model":"vendor/model:preview",
        "prompt":PROMPT,"apiKey":KEY,"resolvedProxy":"DIRECT","timeoutMs":2000,"idleTimeoutMs":500})
}
fn wait(id: &str, predicate: impl Fn(&Value) -> bool) -> Value {
    let end = Instant::now() + Duration::from_secs(4);
    loop {
        let value = ok("benchmark_status", json!({"runId":id}));
        if predicate(&value) {
            return value;
        }
        assert!(Instant::now() < end, "bounded status wait: {value}");
        thread::sleep(Duration::from_millis(3));
    }
}
fn finish(id: &str) -> Value {
    wait(id, |v| v["cleanupPending"] == false)
}
fn clear(id: &str) {
    finish(id);
    ok("benchmark_clear", json!({"runId":id}));
}
fn private_snapshot(snapshot: &Value, base: &str) {
    let text = snapshot.to_string();
    for forbidden in [
        KEY,
        PROMPT,
        base,
        "Authorization",
        "resolvedProxy",
        "baseUrl",
        "apiKey",
    ] {
        assert!(
            !text.contains(forbidden),
            "public snapshot leaked private request material"
        );
    }
    assert_eq!(snapshot["executionMode"], "live");
    assert_eq!(snapshot["engineVersion"], "m4-rust-v1+aiperf-b1746a84");
    assert_eq!(
        snapshot["source"],
        json!({"kind":"user_endpoint","scenarioId":null,"networkScope":"user_configured_endpoint"})
    );
}

struct Server {
    base: String,
    stop: Arc<AtomicBool>,
    count: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<String>>>,
    worker: Option<JoinHandle<()>>,
}
impl Server {
    fn new(header: String, body: String, stall: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base = format!("http://{}/v1", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let count = Arc::new(AtomicUsize::new(0));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let (signal, hits, captures) = (stop.clone(), count.clone(), requests.clone());
        let worker = thread::spawn(move || {
            while !signal.load(Ordering::SeqCst) {
                let Ok((mut socket, _)) = listener.accept() else {
                    thread::sleep(Duration::from_millis(2));
                    continue;
                };
                hits.fetch_add(1, Ordering::SeqCst);
                socket
                    .set_read_timeout(Some(Duration::from_millis(20)))
                    .unwrap();
                socket
                    .set_write_timeout(Some(Duration::from_millis(100)))
                    .unwrap();
                let deadline = Instant::now() + Duration::from_secs(2);
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                while Instant::now() < deadline && !signal.load(Ordering::SeqCst) {
                    match socket.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => bytes.extend_from_slice(&buffer[..n]),
                        Err(e)
                            if [std::io::ErrorKind::WouldBlock, std::io::ErrorKind::TimedOut]
                                .contains(&e.kind()) =>
                        {
                            continue
                        }
                        Err(_) => break,
                    }
                    if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        let header = String::from_utf8_lossy(&bytes[..end]).to_ascii_lowercase();
                        let length: usize = header
                            .lines()
                            .find_map(|l| {
                                l.strip_prefix("content-length:")
                                    .and_then(|s| s.trim().parse().ok())
                            })
                            .unwrap_or(0);
                        if bytes.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                captures
                    .lock()
                    .unwrap()
                    .push(String::from_utf8(bytes).unwrap());
                if socket.write_all(header.as_bytes()).is_err() {
                    continue;
                }
                if !body.is_empty() {
                    let _ = socket.write_all(body.as_bytes());
                }
                if stall {
                    while !signal.load(Ordering::SeqCst) {
                        match socket.read(&mut buffer) {
                            Ok(0) => break,
                            Err(e)
                                if [
                                    std::io::ErrorKind::WouldBlock,
                                    std::io::ErrorKind::TimedOut,
                                ]
                                .contains(&e.kind()) =>
                            {
                                ()
                            }
                            _ => break,
                        }
                    }
                }
            }
        });
        Self {
            base,
            stop,
            count,
            requests,
            worker: Some(worker),
        }
    }
    fn captured(&self) -> String {
        self.requests.lock().unwrap()[0].clone()
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.worker.take().unwrap().join().unwrap();
    }
}
fn chat() -> String {
    [
        json!({"choices":[{"index":0,"delta":{"content":"synthetic"},"finish_reason":null}]}),
        json!({"choices":[{"index":0,"delta":{"content":" text"},"finish_reason":null}]}),
        json!({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}),
        json!({"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4}}),
    ]
    .into_iter()
    .map(|mut v| {
        v["id"] = json!("m4-chat-response");
        v["model"] = json!("vendor/response:preview");
        v["object"] = json!("chat.completion.chunk");
        format!("data: {v}\n\n")
    })
    .collect::<String>()
        + "data: [DONE]\n\n"
}
fn responses() -> String {
    [
        json!({"type":"response.created","sequence_number":0,"response":{"id":"m4-resp","model":"vendor/response:preview","status":"in_progress","output":[]}}),
        json!({"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg","type":"message","role":"assistant","content":[]}}),
        json!({"type":"response.output_text.delta","sequence_number":2,"item_id":"msg","output_index":0,"content_index":0,"delta":"synthetic text"}),
        json!({"type":"response.completed","sequence_number":3,"response":{"id":"m4-resp","model":"vendor/response:preview","status":"completed","output":[{"id":"msg","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic text"}]}],"usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}}),
    ].into_iter().map(|v| format!("event: {}\ndata: {v}\n\n", v["type"].as_str().unwrap())).collect()
}

// Catches the old blanket live hardgate, wrong endpoint/body/auth and relabelled/secret snapshots.
#[test]
fn public_live_transport_routes_authenticates_and_cleans_owned_requests() {
    for (protocol, body, suffix, token_field) in [
        (
            "chat_completions",
            chat(),
            "/chat/completions",
            "max_completion_tokens",
        ),
        ("responses", responses(), "/responses", "max_output_tokens"),
    ] {
        let server = Server::new(SSE.into(), body, false);
        let initial = ok("benchmark_start", request(&server.base, protocol));
        private_snapshot(&initial, &server.base);
        let id = initial["runId"].as_str().unwrap();
        let done = finish(id);
        private_snapshot(&done, &server.base);
        assert_eq!(done["state"], "completed", "{done}");
        assert_eq!(done["usage"]["outputTokens"], 4);
        let raw = server.captured();
        assert!(raw.starts_with(&format!("POST /v1{suffix} HTTP/1.1\r\n")));
        let (headers, body) = raw.split_once("\r\n\r\n").unwrap();
        assert!(headers
            .to_ascii_lowercase()
            .contains(&format!("authorization: Bearer {KEY}").to_ascii_lowercase()));
        assert!(!headers.to_ascii_lowercase().contains("proxy-authorization"));
        let body: Value = serde_json::from_str(body).unwrap();
        assert_eq!(body[token_field], 256);
        assert_eq!(body["store"], false);
        assert_eq!(body["stream"], true);
        assert!(!body.to_string().contains(KEY));
        assert_eq!(server.count.load(Ordering::SeqCst), 1);
        clear(id);
    }

    // Explicit proxy sends to the selected loopback proxy, with no target listener/fallback.
    let proxy = Server::new(SSE.into(), chat(), false);
    let mut proxied = request("http://127.0.0.1:1/api", "chat_completions");
    proxied["resolvedProxy"] = json!(format!(
        "PROXY {}",
        proxy
            .base
            .strip_prefix("http://")
            .unwrap()
            .strip_suffix("/v1")
            .unwrap()
    ));
    let initial = ok("benchmark_start", proxied);
    let id = initial["runId"].as_str().unwrap();
    assert_eq!(finish(id)["state"], "completed");
    assert!(proxy
        .captured()
        .starts_with("POST http://127.0.0.1:1/api/chat/completions HTTP/1.1"));
    clear(id);

    let no_fallback_target = Server::new(SSE.into(), chat(), false);
    let denied_proxy = Server::new(
        "HTTP/1.1 503 Proxy Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
        String::new(),
        false,
    );
    let mut proxied = request(&no_fallback_target.base, "responses");
    proxied["resolvedProxy"] = json!(format!(
        "PROXY {}",
        denied_proxy
            .base
            .strip_prefix("http://")
            .unwrap()
            .strip_suffix("/v1")
            .unwrap()
    ));
    let initial = ok("benchmark_start", proxied);
    let id = initial["runId"].as_str().unwrap();
    assert_eq!(finish(id)["state"], "failed");
    assert_eq!(denied_proxy.count.load(Ordering::SeqCst), 1);
    assert_eq!(
        no_fallback_target.count.load(Ordering::SeqCst),
        0,
        "proxy failure must never fall back to direct"
    );
    clear(id);

    let target = Server::new(SSE.into(), chat(), false);
    let redirect = Server::new(format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: {}/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", target.base), String::new(), false);
    let initial = ok(
        "benchmark_start",
        request(&redirect.base, "chat_completions"),
    );
    let id = initial["runId"].as_str().unwrap();
    assert!(finish(id)["reasons"]
        .as_array()
        .unwrap()
        .contains(&json!("http_status")));
    assert_eq!(
        target.count.load(Ordering::SeqCst),
        0,
        "redirect must not forward the key"
    );
    clear(id);

    for status in [401, 429, 503] {
        let server = Server::new(
            format!(
                "HTTP/1.1 {status} Mock Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            ),
            String::new(),
            false,
        );
        let initial = ok("benchmark_start", request(&server.base, "chat_completions"));
        let id = initial["runId"].as_str().unwrap();
        let done = finish(id);
        assert_eq!(done["state"], "failed");
        assert!(done["reasons"]
            .as_array()
            .unwrap()
            .contains(&json!("http_status")));
        assert_eq!(
            server.count.load(Ordering::SeqCst),
            1,
            "errors must never auto-retry"
        );
        private_snapshot(&done, &server.base);
        clear(id);
    }

    for (body, reason) in [
        (chat().replace(&format!("data: {}\n\n", json!({"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4},"id":"m4-chat-response","model":"vendor/response:preview","object":"chat.completion.chunk"})), ""), "missing_usage"),
        ("data: {\"object\":\"chat.completion.chunk\"".to_owned(), "incomplete_sse"),
    ] {
        let server = Server::new(SSE.into(), body, false);
        let initial = ok("benchmark_start", request(&server.base, "chat_completions"));
        let id = initial["runId"].as_str().unwrap();
        let done = finish(id);
        assert_eq!(done["state"], "failed");
        assert!(done["reasons"].as_array().unwrap().contains(&json!(reason)), "{done}");
        private_snapshot(&done, &server.base);
        clear(id);
    }

    let stall = Server::new(SSE.into(), String::new(), true);
    let initial = ok("benchmark_start", request(&stall.base, "chat_completions"));
    let id = initial["runId"].as_str().unwrap();
    wait(id, |v| v["state"] == "streaming");
    assert_eq!(
        call("benchmark_start", request(&stall.base, "chat_completions"))["error"],
        "benchmark_busy"
    );
    assert_eq!(
        ok("benchmark_cancel", json!({"runId":id}))["state"],
        "cancelled"
    );
    assert_eq!(finish(id)["state"], "cancelled");
    clear(id);

    let initial = ok("benchmark_start", request(&stall.base, "chat_completions"));
    let id = initial["runId"].as_str().unwrap();
    let done = finish(id);
    assert_eq!(done["state"], "failed");
    assert!(done["reasons"]
        .as_array()
        .unwrap()
        .contains(&json!("body_idle_timeout")));
    clear(id);

    // Invalid inputs fail admission before any HTTP request is possible.
    for base in [
        "http://remote.invalid/v1",
        "http://localhost:1/v1",
        "http://127.1/v1",
        "http://127.0.0.1:1/v1?key=x",
        "http://u:p@127.0.0.1:1/v1",
        "https://provider.invalid/v1/responses",
    ] {
        let value = call("benchmark_start", request(base, "chat_completions"));
        assert_eq!(value["ok"], false);
        assert!(!value.to_string().contains(KEY));
    }
    for route in [
        "PROXY user:pass@127.0.0.1:1",
        "PROXY 127.0.0.1:1; DIRECT",
        "SOCKS 127.0.0.1:1",
    ] {
        let mut value = request(&stall.base, "responses");
        value["resolvedProxy"] = json!(route);
        assert_eq!(call("benchmark_start", value)["ok"], false);
    }
    let mut invalid = request(&stall.base, "responses");
    invalid["apiKey"] = json!("synthetic\r\nX-Leak: forbidden");
    assert_eq!(call("benchmark_start", invalid)["ok"], false);

    let catalog = ok("benchmark_catalog", json!({}));
    assert_eq!(catalog["liveExecutionEnabled"], true);
    assert_eq!(catalog["scenarios"].as_array().unwrap().len(), 12);
    let initial = ok("benchmark_start", request(&stall.base, "responses"));
    let id = initial["runId"].as_str().unwrap();
    wait(id, |v| v["state"] == "streaming");
    assert_eq!(
        ok("benchmark_shutdown", json!({"runId":id}))["cleanupComplete"],
        true
    );
    assert_eq!(finish(id)["state"], "cancelled");
}
