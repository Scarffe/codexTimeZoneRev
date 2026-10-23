#[allow(dead_code)]
#[path = "../src/benchmark/collector.rs"]
mod collector;
#[allow(dead_code)]
#[path = "../src/benchmark/metrics.rs"]
mod metrics;
#[allow(dead_code)]
#[path = "../src/benchmark/responses.rs"]
mod responses;
#[allow(dead_code)]
#[path = "../src/benchmark/sse.rs"]
mod sse;
#[allow(dead_code)]
#[path = "../src/benchmark/types.rs"]
mod types;
use collector::Collector;
use responses::ResponsesAdapter;
use serde_json::{json, Value};
use types::SseMessage;

fn event(a: &mut ResponsesAdapter, c: &mut Collector, at: u64, value: Value) {
    let name = value["type"].as_str().unwrap().to_owned();
    for e in a
        .accept(SseMessage {
            event: Some(name),
            data: value.to_string(),
        })
        .unwrap()
    {
        c.observe(at, e).unwrap();
    }
}
fn created(a: &mut ResponsesAdapter, c: &mut Collector) {
    event(
        a,
        c,
        0,
        json!({"type":"response.created","sequence_number":0,"response":{"id":"r","model":"fixture","status":"in_progress","output":[]}}),
    );
}
fn item(a: &mut ResponsesAdapter, c: &mut Collector, index: u64, kind: &str, id: &str) {
    event(
        a,
        c,
        0,
        json!({"type":"response.output_item.added","sequence_number":index+1,"output_index":index,"item":{"id":id,"type":kind,"role":"assistant","content":[],"summary":[]}}),
    );
}
fn delta(
    a: &mut ResponsesAdapter,
    c: &mut Collector,
    seq: u64,
    at: u64,
    kind: &str,
    id: &str,
    index: u64,
) {
    let mut value = json!({"type":kind,"sequence_number":seq,"item_id":id,"output_index":index,"delta":"synthetic"});
    value[if kind.contains("summary") {
        "summary_index"
    } else {
        "content_index"
    }] = json!(0);
    event(a, c, at, value);
}
fn terminal(
    a: &mut ResponsesAdapter,
    c: &mut Collector,
    seq: u64,
    kind: &str,
    output: Value,
    usage: Value,
) {
    let status = kind.strip_prefix("response.").unwrap();
    event(
        a,
        c,
        3_000_000_000,
        json!({"type":kind,"sequence_number":seq,"response":{"id":"r","model":"fixture","status":status,"output":output,"usage":usage}}),
    );
}
fn usage(reasoning: Value) -> Value {
    json!({"input_tokens":10,"output_tokens":100,"total_tokens":110,"output_tokens_details":{"reasoning_tokens":reasoning}})
}
fn text_output() -> Value {
    json!([{"id":"msg","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic"}]}])
}

// Catches control/done frames being counted as content and opaque reasoning being hidden.
#[test]
fn reasoning_and_text_times_are_distinct_and_done_never_recounts() {
    let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
    created(&mut a, &mut c);
    item(&mut a, &mut c, 0, "reasoning", "reason");
    item(&mut a, &mut c, 1, "message", "msg");
    assert!(c.snapshot()["timingsNs"]["firstContent"].is_null());
    delta(
        &mut a,
        &mut c,
        3,
        500_000_000,
        "response.reasoning_summary_text.delta",
        "reason",
        0,
    );
    delta(
        &mut a,
        &mut c,
        4,
        1_500_000_000,
        "response.output_text.delta",
        "msg",
        1,
    );
    event(
        &mut a,
        &mut c,
        2_000_000_000,
        json!({"type":"response.output_text.done","sequence_number":5,"item_id":"msg","output_index":1,"content_index":0,"text":"synthetic"}),
    );
    terminal(
        &mut a,
        &mut c,
        6,
        "response.completed",
        json!([{"id":"reason","type":"reasoning","summary":[{"type":"summary_text","text":"synthetic"}]},{"id":"msg","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic"}]}]),
        usage(json!(20)),
    );
    assert_eq!(c.snapshot()["successfulSample"], false);
    c.http_end(4_000_000_000).unwrap();
    let v = c.snapshot();
    assert_eq!(v["metrics"]["ttftMs"]["value"], 500.0);
    assert_eq!(v["metrics"]["ttfoMs"]["value"], 1500.0);
    assert_eq!(v["timingsNs"]["lastContent"], 1_500_000_000u64);
    assert_eq!(
        v["metrics"]["streamTokensPerSecond"]["quality"],
        "unavailable"
    );
    assert_eq!(v["metrics"]["e2eTokensPerSecond"]["value"], 25.0);
    assert_eq!(v["protocolTerminal"], "response.completed");
}
// Catches fabricated exact first-chunk counts and completion-token source labels.
#[test]
fn text_rate_is_estimated_49_point_5_and_output_count_source() {
    let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
    created(&mut a, &mut c);
    item(&mut a, &mut c, 0, "message", "msg");
    delta(
        &mut a,
        &mut c,
        2,
        500_000_000,
        "response.output_text.delta",
        "msg",
        0,
    );
    delta(
        &mut a,
        &mut c,
        3,
        2_500_000_000,
        "response.output_text.delta",
        "msg",
        0,
    );
    terminal(
        &mut a,
        &mut c,
        4,
        "response.completed",
        text_output(),
        usage(json!(0)),
    );
    c.http_end(4_000_000_000).unwrap();
    let v = c.snapshot();
    assert_eq!(v["successfulSample"], true);
    assert_eq!(v["metrics"]["streamTokensPerSecond"]["value"], 49.5);
    assert_eq!(
        v["metrics"]["streamTokensPerSecond"]["quality"],
        "estimated"
    );
    assert_eq!(
        v["metrics"]["e2eTokensPerSecond"]["countSource"],
        "reported_output_tokens_including_reasoning"
    );
}
// Catches throwing away terminal usage, and treating failed/incomplete/error as success.
#[test]
fn unsuccessful_terminals_preserve_usage_and_never_succeed() {
    for kind in ["response.failed", "response.incomplete"] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        terminal(&mut a, &mut c, 1, kind, json!([]), usage(json!(0)));
        c.http_end(4_000_000_000).unwrap();
        let v = c.snapshot();
        assert_eq!(v["usage"]["outputTokens"], 100);
        assert_eq!(v["successfulSample"], false);
        assert_eq!(v["protocolTerminal"], kind);
    }
    let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
    created(&mut a, &mut c);
    event(
        &mut a,
        &mut c,
        1,
        json!({"type":"error","sequence_number":1,"code":"upstream_private_text","message":"secret"}),
    );
    c.http_end(2).unwrap();
    assert_eq!(c.snapshot()["protocolTerminal"], "error");
    assert!(!c.snapshot().to_string().contains("secret"));
}
// Catches accepting malformed identity/index/sequence/type/usage and events after terminal.
#[test]
fn malformed_frames_fail_closed() {
    for frame in [
        json!({"type":"response.output_text.delta","sequence_number":2,"item_id":"wrong","output_index":0,"content_index":0,"delta":"x"}),
        json!({"type":"response.output_text.delta","sequence_number":1,"item_id":"msg","output_index":0,"content_index":0,"delta":"x"}),
        json!({"type":"response.output_text.delta","sequence_number":2,"item_id":"msg","output_index":-1,"delta":"x"}),
        json!({"type":"response.unknown","sequence_number":2}),
        json!({"type":"response.completed","sequence_number":2,"response":{"id":"other","model":"fixture","status":"completed","output":[],"usage":usage(json!(0))}}),
        json!({"type":"response.completed","sequence_number":2,"response":{"id":"r","model":"fixture","status":"completed","output":[],"usage":usage(json!(101))}}),
    ] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        item(&mut a, &mut c, 0, "message", "msg");
        assert!(
            a.accept(SseMessage {
                event: None,
                data: frame.to_string()
            })
            .is_err(),
            "{frame}"
        );
    }
    let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
    created(&mut a, &mut c);
    terminal(
        &mut a,
        &mut c,
        1,
        "response.completed",
        json!([]),
        Value::Null,
    );
    assert!(a
        .accept(SseMessage {
            event: None,
            data: json!({"type":"response.output_text.delta","sequence_number":2,"delta":"late"})
                .to_string()
        })
        .is_err());
    assert_eq!(c.snapshot()["successfulSample"], false);
}
// Catches final-only hidden/tool output manufacturing arrival times or usable stream scope.
#[test]
fn final_only_scope_disables_stream_without_losing_e2e() {
    for extra in [
        json!({"id":"opaque","type":"reasoning","summary":[]}),
        json!({"id":"tool","type":"function_call","name":"f","arguments":"{}","call_id":"call"}),
    ] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        item(&mut a, &mut c, 0, "message", "msg");
        delta(
            &mut a,
            &mut c,
            2,
            500_000_000,
            "response.output_text.delta",
            "msg",
            0,
        );
        delta(
            &mut a,
            &mut c,
            3,
            2_500_000_000,
            "response.output_text.delta",
            "msg",
            0,
        );
        let mut output = text_output();
        output.as_array_mut().unwrap().push(extra);
        terminal(
            &mut a,
            &mut c,
            4,
            "response.completed",
            output,
            usage(json!(0)),
        );
        c.http_end(4_000_000_000).unwrap();
        let v = c.snapshot();
        assert_eq!(v["successfulSample"], true);
        assert_eq!(
            v["metrics"]["streamTokensPerSecond"]["quality"],
            "unavailable"
        );
        assert_eq!(v["metrics"]["e2eTokensPerSecond"]["value"], 25.0);
    }
}
// Catches terminal output rewriting indexes or omitting previously observed item scopes.
#[test]
fn terminal_output_cannot_reassign_or_omit_observed_items() {
    for output in [
        json!([]),
        json!([{"id":"other","type":"message","role":"assistant","content":[]}]),
        json!([{"id":"msg","type":"reasoning","summary":[]}]),
        json!([{"id":"msg","type":"message","role":"assistant","content":[]}]),
    ] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        item(&mut a, &mut c, 0, "message", "msg");
        delta(&mut a, &mut c, 2, 1, "response.output_text.delta", "msg", 0);
        let v = json!({"type":"response.completed","sequence_number":3,"response":{"id":"r","model":"fixture","status":"completed","output":output,"usage":usage(json!(0))}});
        assert!(
            a.accept(SseMessage {
                event: None,
                data: v.to_string()
            })
            .is_err(),
            "{v}"
        );
    }
}
// Catches non-counter usage, inconsistent totals and accepting event/type mismatch.
#[test]
fn usage_counters_and_event_type_are_strict() {
    for bad in [
        json!({"output_tokens":-1}),
        json!({"output_tokens":1.5}),
        json!({"output_tokens":9007199254740992u64}),
        json!({"input_tokens":10,"output_tokens":100,"total_tokens":100}),
        json!({"input_tokens":1,"output_tokens":2,"input_tokens_details":{"cached_tokens":2}}),
    ] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        let value = json!({"type":"response.completed","sequence_number":1,"response":{"id":"r","model":"fixture","status":"completed","output":[],"usage":bad}});
        assert!(a
            .accept(SseMessage {
                event: None,
                data: value.to_string()
            })
            .is_err());
    }
    let value = json!({"type":"response.created","sequence_number":0,"response":{"id":"r","model":"fixture","status":"in_progress","output":[]}});
    assert!(ResponsesAdapter::new()
        .accept(SseMessage {
            event: Some("response.completed".into()),
            data: value.to_string()
        })
        .is_err());
}
// Catches late content after per-part/item done silently extending generation time.
#[test]
fn content_after_part_or_item_done_is_rejected() {
    for done in [
        json!({"type":"response.output_text.done","sequence_number":2,"item_id":"msg","output_index":0,"content_index":0,"text":"synthetic"}),
        json!({"type":"response.content_part.done","sequence_number":2,"item_id":"msg","output_index":0,"content_index":0,"part":{"type":"output_text","text":"synthetic"}}),
        json!({"type":"response.output_item.done","sequence_number":2,"output_index":0,"item":{"id":"msg","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic"}]}}),
    ] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        item(&mut a, &mut c, 0, "message", "msg");
        event(&mut a, &mut c, 1, done);
        let late = json!({"type":"response.output_text.delta","sequence_number":3,"item_id":"msg","output_index":0,"content_index":0,"delta":"late"});
        assert!(a
            .accept(SseMessage {
                event: None,
                data: late.to_string()
            })
            .is_err());
    }
}
// Catches conflating summary_index=0 with reasoning content_index=0 in one item.
#[test]
fn reasoning_summary_and_reasoning_text_have_separate_index_domains() {
    let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
    created(&mut a, &mut c);
    item(&mut a, &mut c, 0, "reasoning", "reason");
    delta(
        &mut a,
        &mut c,
        2,
        500_000_000,
        "response.reasoning_summary_text.delta",
        "reason",
        0,
    );
    delta(
        &mut a,
        &mut c,
        3,
        700_000_000,
        "response.reasoning_text.delta",
        "reason",
        0,
    );
    terminal(
        &mut a,
        &mut c,
        4,
        "response.completed",
        json!([{"id":"reason","type":"reasoning","summary":[{"type":"summary_text","text":"summary"}],"content":[{"type":"reasoning_text","text":"reasoning"}]}]),
        usage(json!(20)),
    );
    c.http_end(4_000_000_000).unwrap();
    assert_eq!(c.snapshot()["successfulSample"], true);
    assert!(c.snapshot()["timingsNs"]["firstVisible"].is_null());
}
// Catches silently accepting unknown token scopes and unrecognized content-bearing fields.
#[test]
fn unsupported_fields_and_token_details_fail_closed() {
    for extra in [
        json!({"output_tokens":100,"output_tokens_details":{"reasoning_tokens":0,"audio_tokens":80}}),
        json!({"output_tokens":100,"unexpected_tokens":1}),
    ] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        let value = json!({"type":"response.completed","sequence_number":1,"response":{"id":"r","model":"fixture","status":"completed","output":[],"usage":extra}});
        assert!(a
            .accept(SseMessage {
                event: None,
                data: value.to_string()
            })
            .is_err());
    }
    let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
    created(&mut a, &mut c);
    item(&mut a, &mut c, 0, "message", "msg");
    let value = json!({"type":"response.output_text.delta","sequence_number":2,"item_id":"msg","output_index":0,"content_index":0,"delta":"x","unknown_content":"hidden"});
    assert!(a
        .accept(SseMessage {
            event: None,
            data: value.to_string()
        })
        .is_err());
}
// Uses the actual decoder at every byte boundary; counts come only from usage.
#[test]
fn responses_utf8_sse_and_zero_one_token_edges() {
    let raw="event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":10,\"response\":{\"id\":\"r\",\"model\":\"模型\",\"status\":\"in_progress\",\"output\":[]}}\n\n";
    let mut decoder = sse::SseDecoder::new();
    let mut adapter = ResponsesAdapter::new();
    for byte in raw.as_bytes() {
        for msg in decoder.push(&[*byte]).unwrap() {
            assert!(adapter.accept(msg).unwrap().is_empty());
        }
    }
    decoder.finish().unwrap();
    assert_eq!(adapter.response_model(), Some("模型"));
    for n in [0, 1] {
        let (mut a, mut c) = (ResponsesAdapter::new(), Collector::for_responses());
        created(&mut a, &mut c);
        terminal(
            &mut a,
            &mut c,
            1,
            "response.completed",
            json!([]),
            json!({"output_tokens":n,"output_tokens_details":{"reasoning_tokens":0}}),
        );
        c.http_end(4_000_000_000).unwrap();
        let v = c.snapshot();
        assert_eq!(v["successfulSample"], true);
        assert_eq!(v["usage"]["outputTokens"], n);
        assert_eq!(
            v["metrics"]["streamTokensPerSecond"]["quality"],
            "unavailable"
        );
        assert!(v["metrics"]["e2eTokensPerSecond"]["value"].is_number());
    }
}
