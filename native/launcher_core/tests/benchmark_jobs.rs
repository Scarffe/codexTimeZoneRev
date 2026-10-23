//! Real FFI + literal-loopback fixtures. No desktop process or credentials.
use codex_timezone_core::{launcher_call, launcher_free};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

fn call(command: &str, payload: Value) -> Value {
    let request =
        CString::new(json!({"version":1,"command":command,"payload":payload}).to_string()).unwrap();
    unsafe {
        let pointer = launcher_call(request.as_ptr());
        assert!(!pointer.is_null());
        let result = serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap();
        launcher_free(pointer);
        result
    }
}
fn ok(command: &str, payload: Value) -> Value {
    let response = call(command, payload);
    assert_eq!(response["ok"], true, "{command}: {response}");
    response["data"].clone()
}
fn request(base: &str) -> Value {
    json!({"mode":"local_replay","protocol":"chat_completions","baseUrl":base,
        "model":"fixture-model","prompt":"SENSITIVE_FIXTURE_PROMPT","maxOutputTokens":256,
        "resolvedProxy":"DIRECT","timeoutMs":2000,"idleTimeoutMs":500})
}
fn wait_for(id: &str, predicate: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        let status = ok("benchmark_status", json!({"runId":id}));
        if predicate(&status) {
            return status;
        }
        assert!(Instant::now() < deadline, "bounded status wait: {status}");
        thread::sleep(Duration::from_millis(4));
    }
}
fn terminal(id: &str) -> Value {
    wait_for(id, |v| v["cleanupPending"] == false)
}
fn clear(id: &str) {
    terminal(id);
    ok("benchmark_clear", json!({"runId":id}));
}

struct Fixture {
    base: String,
    stop: Arc<AtomicBool>,
    accepts: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<String>>>,
    thread: Option<JoinHandle<()>>,
}
impl Fixture {
    fn new(header: &str, pieces: Vec<(u64, Vec<u8>)>, keep_open: bool) -> Self {
        Self::bind("127.0.0.1:0", header, pieces, keep_open)
    }
    fn bind(address: &str, header: &str, pieces: Vec<(u64, Vec<u8>)>, keep_open: bool) -> Self {
        let listener = TcpListener::bind(address).unwrap();
        listener.set_nonblocking(true).unwrap();
        let base = format!("http://{}/v1", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let accepts = Arc::new(AtomicUsize::new(0));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let (signal, count, captured) = (stop.clone(), accepts.clone(), requests.clone());
        let header = header.to_owned();
        let worker = thread::spawn(move || {
            while !signal.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut socket, _)) => {
                        count.fetch_add(1, Ordering::SeqCst);
                        socket
                            .set_read_timeout(Some(Duration::from_millis(20)))
                            .unwrap();
                        socket
                            .set_write_timeout(Some(Duration::from_millis(100)))
                            .unwrap();
                        if let Some(raw) = read_request(&mut socket, &signal) {
                            captured.lock().unwrap().push(raw);
                        }
                        if socket.write_all(header.as_bytes()).is_err() {
                            continue;
                        }
                        for (delay, bytes) in &pieces {
                            if !delay_until(*delay, &signal) || socket.write_all(bytes).is_err() {
                                break;
                            }
                        }
                        if keep_open {
                            let mut byte = [0];
                            while !signal.load(Ordering::SeqCst) {
                                match socket.read(&mut byte) {
                                    Ok(0) => break,
                                    Err(e)
                                        if e.kind() == std::io::ErrorKind::WouldBlock
                                            || e.kind() == std::io::ErrorKind::TimedOut =>
                                    {
                                        ()
                                    }
                                    _ => break,
                                }
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            base,
            stop,
            accepts,
            requests,
            thread: Some(worker),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.thread.take() {
            handle.join().unwrap();
        }
    }
}
fn delay_until(ms: u64, stop: &AtomicBool) -> bool {
    let deadline = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < deadline {
        if stop.load(Ordering::SeqCst) {
            return false;
        }
        thread::sleep(Duration::from_millis(2));
    }
    !stop.load(Ordering::SeqCst)
}
fn read_request(socket: &mut TcpStream, stop: &AtomicBool) -> Option<String> {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    while !stop.load(Ordering::SeqCst) && Instant::now() < deadline {
        match socket.read(&mut buffer) {
            Ok(0) => return None,
            Ok(n) => bytes.extend_from_slice(&buffer[..n]),
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                continue
            }
            Err(_) => return None,
        }
        if let Some(end) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
            let headers = String::from_utf8_lossy(&bytes[..end]);
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|v| v.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            if bytes.len() >= end + 4 + length {
                return String::from_utf8(bytes).ok();
            }
        }
    }
    None
}
const SSE: &str = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
fn frame(mut value: Value) -> Vec<u8> {
    value["id"] = json!("fixture-response");
    value["model"] = json!("response-model");
    value["object"] = json!("chat.completion.chunk");
    format!("data: {value}\n\n").into_bytes()
}
fn content(text: &str) -> Vec<u8> {
    frame(
        json!({"model":"response-model","choices":[{"index":0,"delta":{"content":text},"finish_reason":null}]}),
    )
}
fn finish() -> Vec<u8> {
    frame(json!({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}))
}
fn usage(tokens: u64) -> Vec<u8> {
    frame(json!({"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":tokens}}))
}

// One lifecycle owns the process-global manager, including its final shutdown.
// Catches blocking start, premature EOF/DONE completion, stale-ID reuse, privacy,
// implicit retries/proxy/auth, and cancellation releasing admission too early.
#[test]
fn ffi_owned_replay_lifecycle_and_transport_boundaries() {
    let stall = Fixture::new(SSE, vec![], true);
    let started = Instant::now();
    let first = ok("benchmark_start", request(&stall.base));
    assert!(
        started.elapsed() < Duration::from_millis(200),
        "start must enqueue promptly"
    );
    assert_eq!(first["state"], "queued");
    assert_eq!(first["measurementKind"], "independent_api");
    let id = first["runId"].as_str().unwrap();
    assert_eq!(call("benchmark_start", request(&stall.base))["ok"], false);
    assert_eq!(call("benchmark_clear", json!({"runId":id}))["ok"], false);
    wait_for(id, |s| s["state"] == "streaming");
    let copied = ok("benchmark_status", json!({"runId":id}));
    let started = Instant::now();
    let cancelled = ok("benchmark_cancel", json!({"runId":id}));
    assert!(started.elapsed() < Duration::from_millis(200));
    assert_eq!(cancelled["state"], "cancelled");
    let cancelled = terminal(id);
    assert_eq!(cancelled["state"], "cancelled");
    assert_eq!(copied["state"], "streaming");
    assert_eq!(
        ok("benchmark_interrupt", json!({"runId":id}))["state"],
        "cancelled"
    );
    assert_eq!(terminal(id), cancelled, "terminal facts remain immutable");
    clear(id);
    assert_eq!(call("benchmark_status", json!({"runId":id}))["ok"], false);
    assert_eq!(stall.accepts.load(Ordering::SeqCst), 1);

    let mut bytes = content("跨字节");
    bytes.extend(finish());
    let mut tail = usage(3);
    tail.extend(b"data: [DONE]\n\n");
    // Split in the middle of UTF-8 and SSE/JSON; delayed EOF after DONE.
    let split = bytes.iter().position(|byte| *byte >= 128).unwrap() + 1;
    let full = Fixture::new(
        SSE,
        vec![
            (0, bytes[..split].to_vec()),
            (8, bytes[split..].to_vec()),
            (55, tail),
        ],
        true,
    );
    let run = ok("benchmark_start", request(&full.base));
    let next = run["runId"].as_str().unwrap();
    assert_ne!(next, id);
    assert_eq!(call("benchmark_cancel", json!({"runId":id}))["ok"], false);
    wait_for(next, |s| s["timingsNs"]["done"].is_number());
    assert_eq!(
        ok("benchmark_status", json!({"runId":next}))["state"],
        "streaming",
        "DONE is not HTTP EOF"
    );
    drop(full);
    let final_value = terminal(next);
    assert_eq!(final_value["state"], "completed", "{final_value}");
    assert_eq!(final_value["successfulSample"], true);
    assert_eq!(final_value["requestedModel"], "fixture-model");
    assert_eq!(final_value["responseModel"], "response-model");
    assert!(final_value["metrics"]["e2eTokensPerSecond"]["value"].is_number());
    let frozen = final_value.clone();
    thread::sleep(Duration::from_millis(10));
    assert_eq!(ok("benchmark_cancel", json!({"runId":next})), frozen);
    assert!(!frozen.to_string().contains("SENSITIVE_FIXTURE_PROMPT"));
    clear(next);

    // Responses keeps local_replay's exact literal loopback/DIRECT admission,
    // uses its own request schema, and does not confuse protocol terminal with EOF.
    let responses_bytes = b"event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":4,\"response\":{\"id\":\"r\",\"model\":\"response-model\",\"status\":\"in_progress\",\"output\":[]}}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":8,\"response\":{\"id\":\"r\",\"model\":\"response-model\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"total_tokens\":10,\"output_tokens_details\":{\"reasoning_tokens\":0}}}}\n\n";
    let responses = Fixture::new(SSE, vec![(0, responses_bytes.to_vec())], true);
    let mut response_request = request(&responses.base);
    response_request["protocol"] = json!("responses");
    let run = ok("benchmark_start", response_request.clone());
    let rid = run["runId"].as_str().unwrap();
    let pending = wait_for(rid, |s| s["protocolTerminal"] == "response.completed");
    assert_eq!(pending["state"], "streaming");
    assert_eq!(pending["successfulSample"], false);
    assert!(pending["timingsNs"]["httpEnd"].is_null());
    let captured = responses.requests.lock().unwrap()[0].clone();
    assert!(captured.starts_with("POST /v1/responses HTTP/1.1\r\n"));
    assert!(!captured.to_ascii_lowercase().contains("authorization:"));
    let body: Value = serde_json::from_str(captured.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body["input"], "SENSITIVE_FIXTURE_PROMPT");
    assert_eq!(body["max_output_tokens"], 256);
    assert_eq!(body["store"], false);
    assert_eq!(body["stream"], true);
    assert!(body.get("messages").is_none());
    drop(responses);
    let finished = terminal(rid);
    assert_eq!(finished["state"], "completed");
    assert_eq!(finished["usage"]["outputTokens"], 0);
    clear(rid);
    for base in [
        "http://localhost:1/v1",
        "http://127.1:1/v1",
        "http://2130706433:1/v1",
        "http://192.0.2.1/v1",
        "http://127.0.0.1:1/v1/responses",
        "http://127.0.0.1:1/v1/chat/completions",
    ] {
        response_request["baseUrl"] = json!(base);
        assert_eq!(
            call("benchmark_start", response_request.clone())["ok"],
            false,
            "{base}"
        );
    }

    // Valid zero and one-token completions retain reported whole-request rates.
    for tokens in [0, 1] {
        let mut data = if tokens == 0 {
            Vec::new()
        } else {
            content("x")
        };
        data.extend(finish());
        data.extend(usage(tokens));
        data.extend(b"data: [DONE]\n\n");
        let fixture = Fixture::new(SSE, vec![(8, data)], false);
        let run = ok("benchmark_start", request(&fixture.base));
        let id = run["runId"].as_str().unwrap();
        let result = terminal(id);
        assert_eq!(result["state"], "completed", "{result}");
        assert_eq!(result["successfulSample"], true);
        assert_eq!(
            result["metrics"]["e2eTokensPerSecond"]["quality"],
            "reported"
        );
        assert!(result["metrics"]["e2eTokensPerSecond"]["value"].is_number());
        assert_eq!(
            result["metrics"]["streamTokensPerSecond"]["quality"],
            "unavailable"
        );
        clear(id);
    }

    let mut v6data = content("ipv6");
    v6data.extend(finish());
    v6data.extend(usage(2));
    v6data.extend(b"data: [DONE]\n\n");
    let ipv6 = Fixture::bind("[::1]:0", SSE, vec![(4, v6data)], false);
    let v6run = ok("benchmark_start", request(&ipv6.base));
    let v6id = v6run["runId"].as_str().unwrap();
    assert_eq!(terminal(v6id)["state"], "completed");
    clear(v6id);

    // The winner of cancel versus actual EOF is terminal and cannot be changed
    // by a second cancel/interrupt or any queued worker publication.
    for _ in 0..8 {
        let mut bytes = content("race");
        bytes.extend(finish());
        bytes.extend(usage(2));
        bytes.extend(b"data: [DONE]\n\n");
        let fixture = Fixture::new(SSE, vec![(0, bytes)], false);
        let run = ok("benchmark_start", request(&fixture.base));
        let id = run["runId"].as_str().unwrap();
        thread::sleep(Duration::from_millis(2));
        let cancelled = ok("benchmark_cancel", json!({"runId":id}));
        assert!(["completed", "cancelled"].contains(&cancelled["state"].as_str().unwrap()));
        let frozen = terminal(id);
        assert_eq!(ok("benchmark_interrupt", json!({"runId":id})), frozen);
        clear(id);
    }

    let validation = Fixture::new(SSE, vec![], false);
    let good = request(&validation.base);
    for field in [
        "mode",
        "protocol",
        "baseUrl",
        "model",
        "prompt",
        "resolvedProxy",
    ] {
        let mut invalid = good.clone();
        invalid.as_object_mut().unwrap().remove(field);
        assert_eq!(
            call("benchmark_start", invalid)["ok"],
            false,
            "missing {field}"
        );
    }
    for (field, value) in [
        ("mode", json!("live")),
        ("protocol", json!("unsupported_protocol")),
        ("resolvedProxy", json!("PROXY 127.0.0.1:9")),
        ("apiKey", json!("SENSITIVE_FIXTURE_KEY")),
        ("maxOutputTokens", json!(0)),
        ("timeoutMs", json!(99)),
        ("idleTimeoutMs", json!(3000)),
        ("model", json!("")),
        ("prompt", json!("")),
    ] {
        let mut invalid = good.clone();
        invalid[field] = value;
        let error = call("benchmark_start", invalid);
        assert_eq!(error["ok"], false, "invalid {field}");
        assert!(!error.to_string().contains("SENSITIVE_FIXTURE"));
    }
    for url in [
        "http://example.com/v1",
        "http://localhost:80/v1",
        "http://192.0.2.1/v1",
        "http://user:pass@127.0.0.1/v1",
        "http://127.0.0.1/v1?q=private",
        "http://127.0.0.1/v1#private",
        "http://127.0.0.1/v1/chat/completions",
        "http://2130706433/v1",
    ] {
        let mut invalid = good.clone();
        invalid["baseUrl"] = json!(url);
        assert_eq!(
            call("benchmark_start", invalid)["ok"],
            false,
            "invalid URL {url}"
        );
    }
    assert_eq!(validation.accepts.load(Ordering::SeqCst), 0);

    for (header, pieces, expected) in [
        ("HTTP/1.1 503 Unavailable\r\nContent-Length: 22\r\nConnection: close\r\n\r\nSENSITIVE_FIXTURE_ERROR", vec![], "http_status"),
        ("HTTP/1.1 302 Found\r\nLocation: http://192.0.2.1/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", vec![], "http_status"),
        (SSE, vec![(0, b"data: {\"choices\":".to_vec())], "sse_truncated"),
        (SSE, vec![], "stream_incomplete"),
    ] {
        let fixture = Fixture::new(header, pieces, false);
        let run = ok("benchmark_start", request(&fixture.base));
        let id = run["runId"].as_str().unwrap();
        let failed = terminal(id);
        assert_eq!(failed["state"], "failed", "{expected}: {failed}");
        assert!(!failed.to_string().contains("SENSITIVE_FIXTURE"));
        assert!(!failed.to_string().contains("192.0.2.1"));
        assert_eq!(fixture.accepts.load(Ordering::SeqCst), 1, "no retries");
        clear(id);
    }

    let timeout = Fixture::new(SSE, vec![], true);
    let mut short = request(&timeout.base);
    short["timeoutMs"] = json!(200);
    short["idleTimeoutMs"] = json!(50);
    let run = ok("benchmark_start", short);
    let id = run["runId"].as_str().unwrap();
    assert_eq!(terminal(id)["state"], "failed");
    clear(id);
    let timed_pieces = (0..12).map(|_| (35, b": heartbeat\n\n".to_vec())).collect();
    let total_timeout = Fixture::new(SSE, timed_pieces, true);
    let mut short = request(&total_timeout.base);
    short["timeoutMs"] = json!(140);
    short["idleTimeoutMs"] = json!(100);
    let run = ok("benchmark_start", short);
    let id = run["runId"].as_str().unwrap();
    let failed = terminal(id);
    assert_eq!(failed["state"], "failed");
    assert!(
        failed["reasons"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "request_timeout"),
        "{failed}"
    );
    clear(id);
    let run = ok("benchmark_start", request(&timeout.base));
    let id = run["runId"].as_str().unwrap();
    assert_eq!(
        ok("benchmark_interrupt", json!({"runId":id}))["state"],
        "interrupted"
    );
    clear(id);

    // Cancellation also races the connect/header await, before any response.
    let headers_stall = Fixture::new("", vec![], true);
    let run = ok("benchmark_start", request(&headers_stall.base));
    let id = run["runId"].as_str().unwrap();
    let accept_deadline = Instant::now() + Duration::from_secs(1);
    while headers_stall.accepts.load(Ordering::SeqCst) == 0 && Instant::now() < accept_deadline {
        thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(
        ok("benchmark_cancel", json!({"runId":id}))["state"],
        "cancelled"
    );
    clear(id);

    let heartbeat = b": heartbeat\n\n";
    let oversized: Vec<u8> = heartbeat
        .iter()
        .copied()
        .cycle()
        .take(8 * 1024 * 1024 + heartbeat.len())
        .collect();
    let huge = Fixture::new(SSE, vec![(0, oversized)], false);
    let run = ok("benchmark_start", request(&huge.base));
    let id = run["runId"].as_str().unwrap();
    let failed = terminal(id);
    assert_eq!(failed["state"], "failed");
    assert!(
        failed["reasons"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "body_too_large"),
        "{failed}"
    );
    clear(id);

    let run = ok("benchmark_start", request(&timeout.base));
    let id = run["runId"].as_str().unwrap();
    assert_eq!(
        call("benchmark_shutdown", json!({"runId":"stale"}))["ok"],
        false
    );
    let started = Instant::now();
    let shut = ok("benchmark_shutdown", json!({"runId":id}));
    assert!(started.elapsed() < Duration::from_millis(600));
    assert_eq!(shut["accepting"], false);
    assert_eq!(shut["cleanupComplete"], true);
    assert_eq!(call("benchmark_start", request(&timeout.base))["ok"], false);

    // Inspect the actual POST rather than a client builder or mock.
    let captured = stall.requests.lock().unwrap();
    assert_eq!(captured.len(), 1);
    let raw = &captured[0];
    let lower = raw.to_ascii_lowercase();
    assert!(raw.starts_with("POST /v1/chat/completions HTTP/1.1\r\n"));
    assert!(!lower.contains("authorization:"));
    assert!(!lower.contains("proxy-authorization:"));
    let body: Value = serde_json::from_str(raw.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body["max_completion_tokens"], 256);
    assert_eq!(body["n"], 1);
    assert_eq!(body["stream"], true);
    assert_eq!(body["stream_options"]["include_usage"], true);
    assert_eq!(body["store"], false);
    assert_eq!(body["messages"][0]["content"], "SENSITIVE_FIXTURE_PROMPT");
}
