#![allow(dead_code)]
#[path = "../src/benchmark/collector.rs"]
mod collector;
#[path = "../src/benchmark/metrics.rs"]
mod metrics;
#[path = "../src/benchmark/types.rs"]
mod types;

use collector::Collector;
use serde_json::Value;
use types::{ContentKind, FinishReason, StreamEvent, TokenUsage};

fn content(c: &mut Collector, t: u64, kind: ContentKind, first: Option<u64>) {
    c.observe(
        t,
        StreamEvent::Content {
            kind,
            first_chunk_tokens: first,
        },
    )
    .unwrap();
}
fn usage(c: &mut Collector, output: u64, reasoning: Option<u64>) {
    c.observe(
        3_000_000_000,
        StreamEvent::Usage(TokenUsage {
            input_tokens: Some(7),
            output_tokens: output,
            reasoning_tokens: reasoning,
        }),
    )
    .unwrap();
}
fn ended(first: Option<u64>, output: u64, reasoning: Option<u64>) -> Collector {
    let mut c = Collector::new();
    content(&mut c, 500_000_000, ContentKind::Text, first);
    content(&mut c, 2_500_000_000, ContentKind::Text, None);
    c.observe(2_500_000_000, StreamEvent::Finish(FinishReason::Stop))
        .unwrap();
    usage(&mut c, output, reasoning);
    c.observe(3_100_000_000, StreamEvent::Done).unwrap();
    c.http_end(3_500_000_000).unwrap();
    c
}
fn metric<'a>(v: &'a Value, name: &str) -> &'a Value {
    &v["metrics"][name]
}
fn approx(v: &Value, expected: f64) {
    assert!(
        (v.as_f64().unwrap() - expected).abs() < 1e-9,
        "{v} != {expected}"
    );
}
fn no_rates(v: &Value) {
    assert_eq!(v["successfulSample"], false);
    for key in [
        "streamTokensPerSecond",
        "e2eTokensPerSecond",
        "fullResponseTokensPerSecond",
    ] {
        assert!(metric(v, key)["value"].is_null(), "{key}: {v}");
    }
}

// Catches collapsing last content, usage, DONE, and real HTTP EOF into one time.
#[test]
fn exact_first_chunk_preserves_all_boundaries_and_rates() {
    let v = ended(Some(4), 100, Some(0)).snapshot();
    assert_eq!(v["successfulSample"], true);
    approx(&metric(&v, "ttftMs")["value"], 500.0);
    approx(&metric(&v, "ttfoMs")["value"], 500.0);
    approx(&metric(&v, "streamTokensPerSecond")["value"], 48.0);
    approx(&metric(&v, "e2eTokensPerSecond")["value"], 100.0 / 3.5);
    approx(&metric(&v, "fullResponseTokensPerSecond")["value"], 32.0);
    assert_eq!(metric(&v, "streamTokensPerSecond")["quality"], "reported");
    assert_eq!(metric(&v, "streamTokensPerSecond")["numeratorTokens"], 96);
    assert_eq!(
        metric(&v, "streamTokensPerSecond")["denominatorNs"],
        2_000_000_000_u64
    );
    assert_eq!(metric(&v, "streamTokensPerSecond")["unit"], "tokens/s");
    assert_eq!(
        v["timingsNs"],
        serde_json::json!({"start":0,"firstContent":500_000_000,
        "lastContent":2_500_000_000_u64,"firstVisible":500_000_000,"lastVisible":2_500_000_000_u64,
        "usage":3_000_000_000_u64,"done":3_100_000_000_u64,"httpEnd":3_500_000_000_u64})
    );
}

#[test]
fn missing_first_chunk_is_49_5_and_explicitly_estimated() {
    let v = ended(None, 100, Some(0)).snapshot();
    let m = metric(&v, "streamTokensPerSecond");
    approx(&m["value"], 49.5);
    assert_eq!(m["quality"], "estimated");
    assert!(m["reasons"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("first_chunk_assumed_one")));
}

#[test]
fn reasoning_is_first_content_but_prose_is_first_visible() {
    let mut c = Collector::new(); // Role at .1s emits no event in adapter.
    content(&mut c, 500_000_000, ContentKind::Reasoning, None);
    content(&mut c, 1_500_000_000, ContentKind::Text, None);
    let v = c.snapshot();
    approx(&metric(&v, "ttftMs")["value"], 500.0);
    approx(&metric(&v, "ttfoMs")["value"], 1500.0);
    assert!(metric(&v, "streamTokensPerSecond")["value"].is_null());
}

#[test]
fn tool_only_and_reasoning_only_have_no_ttfo() {
    for kind in [ContentKind::Tool, ContentKind::Reasoning] {
        let mut c = Collector::new();
        content(&mut c, 500_000_000, kind, None);
        let v = c.snapshot();
        approx(&metric(&v, "ttftMs")["value"], 500.0);
        assert!(metric(&v, "ttfoMs")["value"].is_null());
    }
}

#[test]
fn reasoning_subset_is_not_added_and_disables_stream_scope() {
    let v = ended(Some(4), 20, Some(5)).snapshot();
    assert_eq!(v["usage"]["outputTokens"], 20);
    approx(&metric(&v, "e2eTokensPerSecond")["value"], 20.0 / 3.5);
    assert_eq!(metric(&v, "e2eTokensPerSecond")["numeratorTokens"], 20);
    assert!(metric(&v, "streamTokensPerSecond")["value"].is_null());
    assert!(metric(&v, "fullResponseTokensPerSecond")["value"].is_null());
}

#[test]
fn absent_reasoning_detail_remains_unknown_and_stream_estimated() {
    let v = ended(Some(4), 100, None).snapshot();
    assert!(v["usage"]["reasoningTokens"].is_null());
    approx(&metric(&v, "streamTokensPerSecond")["value"], 49.5);
    assert_eq!(metric(&v, "streamTokensPerSecond")["quality"], "estimated");
    assert!(metric(&v, "streamTokensPerSecond")["reasons"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("reasoning_scope_unknown")));
}

#[test]
fn zero_one_have_no_stream_but_valid_reported_e2e() {
    for output in [0, 1] {
        let v = ended(None, output, Some(0)).snapshot();
        assert_eq!(v["successfulSample"], true);
        assert!(metric(&v, "streamTokensPerSecond")["value"].is_null());
        assert!(metric(&v, "fullResponseTokensPerSecond")["value"].is_null());
        approx(
            &metric(&v, "e2eTokensPerSecond")["value"],
            output as f64 / 3.5,
        );
        assert_eq!(metric(&v, "e2eTokensPerSecond")["quality"], "reported");
    }
}

#[test]
fn empty_zero_token_completion_reports_e2e_without_inventing_content() {
    let mut c = Collector::new();
    c.observe(100, StreamEvent::Finish(FinishReason::Stop))
        .unwrap();
    c.observe(
        100,
        StreamEvent::Usage(TokenUsage {
            input_tokens: Some(1),
            output_tokens: 0,
            reasoning_tokens: None,
        }),
    )
    .unwrap();
    c.observe(200, StreamEvent::Done).unwrap();
    c.http_end(300).unwrap();
    let v = c.snapshot();
    assert_eq!(v["successfulSample"], true);
    approx(&metric(&v, "e2eTokensPerSecond")["value"], 0.0);
    for key in [
        "ttftMs",
        "ttfoMs",
        "streamTokensPerSecond",
        "fullResponseTokensPerSecond",
    ] {
        assert!(metric(&v, key)["value"].is_null());
    }
}

#[test]
fn unusable_first_counts_disable_stream_but_preserve_reported_e2e() {
    for (first, output, reasoning) in [
        (Some(100), 100, Some(0)),
        (Some(101), 100, Some(0)),
        (Some(0), 100, Some(0)),
    ] {
        let mut c = Collector::new();
        content(&mut c, 500_000_000, ContentKind::Text, first);
        content(&mut c, 2_500_000_000, ContentKind::Text, None);
        c.observe(2_500_000_000, StreamEvent::Finish(FinishReason::Stop))
            .unwrap();
        let _ = c.observe(
            3_000_000_000,
            StreamEvent::Usage(TokenUsage {
                input_tokens: None,
                output_tokens: output,
                reasoning_tokens: reasoning,
            }),
        );
        let _ = c.observe(3_100_000_000, StreamEvent::Done);
        let _ = c.http_end(3_500_000_000);
        let v = c.snapshot();
        assert_eq!(v["successfulSample"], true);
        approx(
            &metric(&v, "e2eTokensPerSecond")["value"],
            output as f64 / 3.5,
        );
        assert!(metric(&v, "streamTokensPerSecond")["value"].is_null());
        assert!(metric(&v, "fullResponseTokensPerSecond")["value"].is_null());
    }
}

#[test]
fn all_output_in_first_chunk_keeps_e2e_for_one_and_one_hundred_tokens() {
    for output in [1, 100] {
        let mut c = Collector::new();
        content(&mut c, 500_000_000, ContentKind::Text, Some(output));
        c.observe(500_000_000, StreamEvent::Finish(FinishReason::Stop))
            .unwrap();
        usage(&mut c, output, Some(0));
        c.observe(3_100_000_000, StreamEvent::Done).unwrap();
        c.http_end(3_500_000_000).unwrap();
        let v = c.snapshot();
        assert_eq!(v["successfulSample"], true);
        let e2e = metric(&v, "e2eTokensPerSecond");
        approx(&e2e["value"], output as f64 / 3.5);
        assert_eq!(e2e["quality"], "reported");
        for key in ["streamTokensPerSecond", "fullResponseTokensPerSecond"] {
            let m = metric(&v, key);
            assert!(m["value"].is_null());
            assert!(m["reasons"]
                .as_array()
                .unwrap()
                .contains(&serde_json::json!("first_chunk_count_not_usable")));
        }
    }
}

#[test]
fn invalid_final_reasoning_subset_invalidates_the_whole_sample() {
    let mut c = Collector::new();
    content(&mut c, 500_000_000, ContentKind::Text, Some(4));
    assert!(c
        .observe(
            3_000_000_000,
            StreamEvent::Usage(TokenUsage {
                input_tokens: None,
                output_tokens: 20,
                reasoning_tokens: Some(21)
            })
        )
        .is_err());
    no_rates(&c.snapshot());
}

#[test]
fn incomplete_cancelled_failed_and_truncated_never_produce_rates() {
    for variant in 0..8 {
        let mut c = Collector::new();
        content(&mut c, 500_000_000, ContentKind::Text, Some(4));
        content(&mut c, 2_500_000_000, ContentKind::Text, None);
        if variant != 7 {
            c.observe(
                2_500_000_000,
                StreamEvent::Finish(if variant == 4 {
                    FinishReason::Length
                } else {
                    FinishReason::Stop
                }),
            )
            .unwrap();
        }
        if variant != 0 {
            usage(&mut c, 100, Some(0));
        }
        if variant != 1 {
            c.observe(3_100_000_000, StreamEvent::Done).unwrap();
        }
        if variant != 2 {
            let _ = c.http_end(3_500_000_000);
        }
        if variant == 3 {
            c.fail("cancelled");
        }
        if variant == 5 {
            c.fail("transport_failed");
        }
        if variant == 6 {
            c.fail("interrupted");
        }
        let v = c.snapshot();
        no_rates(&v);
        approx(&metric(&v, "ttftMs")["value"], 500.0);
        assert!(!v["reasons"].as_array().unwrap().is_empty());
    }
}

#[test]
fn reversed_and_zero_intervals_keep_request_and_stream_validity_separate() {
    for (first, last, end) in [(500, 400, 900), (500, 500, 900), (0, 0, 0)] {
        let mut c = Collector::new();
        let _ = c.observe(
            first,
            StreamEvent::Content {
                kind: ContentKind::Text,
                first_chunk_tokens: Some(4),
            },
        );
        let _ = c.observe(
            last,
            StreamEvent::Content {
                kind: ContentKind::Text,
                first_chunk_tokens: None,
            },
        );
        let _ = c.observe(last, StreamEvent::Finish(FinishReason::Stop));
        let _ = c.observe(
            last,
            StreamEvent::Usage(TokenUsage {
                input_tokens: None,
                output_tokens: 100,
                reasoning_tokens: Some(0),
            }),
        );
        let _ = c.observe(last, StreamEvent::Done);
        let _ = c.http_end(end);
        let v = c.snapshot();
        if first == last && end > 0 {
            assert_eq!(v["successfulSample"], true);
            approx(
                &metric(&v, "e2eTokensPerSecond")["value"],
                100.0 * 1_000_000_000.0 / end as f64,
            );
            assert!(metric(&v, "streamTokensPerSecond")["value"].is_null());
        } else {
            no_rates(&v);
        }
    }
}

#[test]
fn conflicting_usage_and_content_after_done_are_sticky_errors() {
    let mut c = ended(Some(4), 100, Some(0));
    assert!(c
        .observe(
            3_600_000_000,
            StreamEvent::Content {
                kind: ContentKind::Text,
                first_chunk_tokens: None
            }
        )
        .is_err());
    no_rates(&c.snapshot());
    let mut c = Collector::new();
    usage(&mut c, 100, Some(0));
    usage(&mut c, 100, Some(0)); // exact repeated usage is idempotent
    assert_eq!(c.snapshot()["timingsNs"]["usage"], 3_000_000_000_u64);
    assert!(c
        .observe(
            3_000_000_000,
            StreamEvent::Usage(TokenUsage {
                input_tokens: Some(7),
                output_tokens: 101,
                reasoning_tokens: Some(0)
            })
        )
        .is_err());
    no_rates(&c.snapshot());
}

#[test]
fn frozen_source_oracle_projections_match_project_metrics_and_quality() {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/benchmark/aiperf-m2-golden.json")).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let start = case["startNs"].as_u64().unwrap();
        let end = case["endNs"].as_u64().unwrap() - start;
        let mut c = Collector::new();
        let mut last = 0;
        for (index, row) in case["content"].as_array().unwrap().iter().enumerate() {
            let at = row[0].as_u64().unwrap() - start;
            last = at;
            let kind = match row[1].as_str().unwrap() {
                "text" => ContentKind::Text,
                "reasoning" => ContentKind::Reasoning,
                "tool" => ContentKind::Tool,
                _ => panic!("unknown golden kind"),
            };
            content(
                &mut c,
                at,
                kind,
                if index == 0 {
                    case["firstChunkTokens"].as_u64()
                } else {
                    None
                },
            );
        }
        c.observe(last, StreamEvent::Finish(FinishReason::Stop))
            .unwrap();
        let usage_ns = case["usageNs"].as_u64().map(|v| v - start).unwrap_or(last);
        c.observe(
            usage_ns,
            StreamEvent::Usage(TokenUsage {
                input_tokens: None,
                output_tokens: case["outputTokens"].as_u64().unwrap(),
                reasoning_tokens: case["reasoningTokens"].as_u64(),
            }),
        )
        .unwrap();
        c.observe(
            case["doneNs"]
                .as_u64()
                .map(|v| v - start)
                .unwrap_or(usage_ns),
            StreamEvent::Done,
        )
        .unwrap();
        c.http_end(end).unwrap();
        let v = c.snapshot();
        for key in [
            "ttftMs",
            "ttfoMs",
            "streamTokensPerSecond",
            "fullResponseTokensPerSecond",
            "e2eTokensPerSecond",
        ] {
            let actual = &metric(&v, key)["value"];
            let want = &case["project"][key];
            if want.is_null() {
                assert!(actual.is_null(), "{} {key}", case["id"]);
            } else {
                let a = actual.as_f64().unwrap();
                let b = want.as_f64().unwrap();
                assert!(
                    (a - b).abs() <= b.abs().max(1.0) * 1e-12,
                    "{} {key}: {a} != {b}",
                    case["id"]
                );
            }
        }
        assert_eq!(
            metric(&v, "streamTokensPerSecond")["quality"],
            case["project"]["streamQuality"]
        );
        assert_eq!(metric(&v, "ttftMs")["unit"], "ms");
        assert_eq!(metric(&v, "e2eTokensPerSecond")["unit"], "tokens/s");
    }
}
