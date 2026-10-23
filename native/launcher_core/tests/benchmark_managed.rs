use codex_timezone_core::{launcher_call, launcher_free};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    thread,
    time::{Duration, Instant},
};
fn call(command: &str, payload: Value) -> Value {
    let input =
        CString::new(json!({"version":1,"command":command,"payload":payload}).to_string()).unwrap();
    unsafe {
        let out = launcher_call(input.as_ptr());
        let v = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        launcher_free(out);
        v
    }
}
fn ok(command: &str, payload: Value) -> Value {
    let v = call(command, payload);
    assert_eq!(v["ok"], true, "{v}");
    v["data"].clone()
}
fn wait(id: &str) -> Value {
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        let v = ok("benchmark_status", json!({"runId":id}));
        if v["cleanupPending"] == false {
            return v;
        }
        assert!(Instant::now() < end, "{v}");
        thread::sleep(Duration::from_millis(5));
    }
}
// Checks catalog metadata, unsafe admission, stale identity, metadata drift,
// terminal-before-EOF success, detached fixture/client cleanup, and terminal resurrection.
#[test]
fn managed_catalog_admission_dual_protocol_and_owned_cleanup() {
    let catalog = ok("benchmark_catalog", json!({}));
    eprintln!("M3_CATALOG={catalog}");
    assert_eq!(catalog["offlineOnly"], true);
    assert_eq!(catalog["liveExecutionEnabled"], false);
    assert_eq!(
        call("benchmark_start", json!({"mode":"live"}))["error"],
        "live_execution_disabled"
    );
    for payload in [
        json!({"mode":"offline_replay","protocol":"responses","scenarioId":"responses_text_complete","baseUrl":"http://example.com"}),
        json!({"mode":"offline_replay","protocol":"responses","scenarioId":"chat_text_complete"}),
        json!({"mode":"offline_replay","protocol":"responses"}),
    ] {
        assert_eq!(call("benchmark_start", payload)["ok"], false);
    }
    let mut previous = String::new();
    for scenario in catalog["scenarios"].as_array().unwrap() {
        let id_s = scenario["scenarioId"].as_str().unwrap();
        let protocol = scenario["protocol"].as_str().unwrap();
        let start = ok(
            "benchmark_start",
            json!({"mode":"offline_replay","protocol":protocol,"scenarioId":id_s}),
        );
        if id_s == "responses_text_complete" {
            eprintln!("M3_START_SNAPSHOT={start}");
        }
        let id = start["runId"].as_str().unwrap();
        assert_ne!(id, previous);
        assert_eq!(start["protocol"], protocol);
        assert_eq!(start["executionMode"], "offline_replay");
        assert_eq!(start["source"]["scenarioId"], id_s);
        assert_eq!(start["source"]["networkScope"], "literal_loopback_only");
        assert!(start["metrics"].is_object());
        assert!(start["timingsNs"].is_object());
        assert_eq!(
            call(
                "benchmark_start",
                json!({"mode":"offline_replay","protocol":protocol,"scenarioId":id_s})
            )["error"],
            "benchmark_busy"
        );
        if !previous.is_empty() {
            assert_eq!(
                call("benchmark_cancel", json!({"runId":previous}))["error"],
                "unknown_benchmark_run"
            );
        }
        if id_s.ends_with("slow") {
            assert_eq!(
                call("benchmark_clear", json!({"runId":id}))["error"],
                "benchmark_busy"
            );
            let command = if protocol == "responses" {
                "benchmark_interrupt"
            } else {
                "benchmark_cancel"
            };
            let frozen = ok(command, json!({"runId":id}));
            let done = wait(id);
            assert_eq!(done["state"], frozen["state"]);
            assert_eq!(done["successfulSample"], false);
            assert_eq!(done["timingsNs"], frozen["timingsNs"]);
        } else {
            let done = wait(id);
            assert_eq!(done["source"], start["source"]);
            assert_eq!(done["protocol"], start["protocol"]);
            if id_s == "responses_text_complete" {
                eprintln!("M3_FINAL_SNAPSHOT={done}");
            }
            let good = id_s.ends_with("complete") && !id_s.ends_with("incomplete");
            assert_eq!(done["successfulSample"], good, "{id_s}: {done}");
            if good {
                assert_eq!(done["state"], "completed");
                assert!(done["timingsNs"]["httpEnd"].is_u64());
                assert!(done["protocolTerminal"].is_string());
            } else {
                assert_eq!(done["state"], "failed");
            }
        }
        ok("benchmark_clear", json!({"runId":id}));
        previous = id.to_owned();
    }
    let start = ok(
        "benchmark_start",
        json!({"mode":"offline_replay","protocol":"responses","scenarioId":"responses_slow"}),
    );
    let id = start["runId"].as_str().unwrap();
    let before = Instant::now();
    let stopped = ok("benchmark_shutdown", json!({"runId":id}));
    // Manager enforces a 500ms internal cleanup deadline. The 600ms external
    // observation includes 100ms scheduler/FFI return tolerance; it does not
    // establish a strict externally measured 500ms maximum.
    assert!(before.elapsed() < Duration::from_millis(600));
    assert_eq!(stopped["cleanupComplete"], true);
    assert_eq!(
        call(
            "benchmark_start",
            json!({"mode":"offline_replay","protocol":"responses","scenarioId":"responses_slow"})
        )["error"],
        "benchmark_shutdown"
    );
}
