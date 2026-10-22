// Standalone harness until the benchmark production module is wired by Task 3.
#[allow(dead_code)]
#[path = "../src/benchmark/chat.rs"]
mod chat;
#[allow(dead_code)]
#[path = "../src/benchmark/sse.rs"]
mod sse;
#[allow(dead_code)]
#[path = "../src/benchmark/types.rs"]
mod types;

use chat::ChatAdapter;
use serde_json::{json, Value};
use sse::SseDecoder;
use types::{ContentKind, FinishReason, SseMessage, StreamEvent, TokenUsage};

fn message(value: Value) -> SseMessage {
    SseMessage {
        event: None,
        data: value.to_string(),
    }
}
fn chunk(delta: Value) -> Value {
    json!({"id":"synthetic-response", "model":"response-model", "object":"chat.completion.chunk",
        "choices":[{"index":0,"delta":delta,"finish_reason":null}]})
}
fn usage(value: Value) -> Value {
    json!({"id":"synthetic-response", "model":"response-model", "object":"chat.completion.chunk",
        "choices":[],"usage":value})
}
fn content(kind: ContentKind, first_chunk_tokens: Option<u64>) -> StreamEvent {
    StreamEvent::Content {
        kind,
        first_chunk_tokens,
    }
}
fn decode(parts: &[&[u8]]) -> Vec<SseMessage> {
    let mut decoder = SseDecoder::new();
    let mut messages = Vec::new();
    for part in parts {
        messages.extend(decoder.push(part).unwrap());
    }
    decoder.finish().unwrap();
    messages
}

// Catches byte-decoding before complete UTF8 and framing that depends on read boundaries.
#[test]
fn sse_every_byte_and_every_split_preserve_unicode_and_frames() {
    let raw =
        "\u{feff}:心跳\r\nevent: message\rdata: 第一🙂\rdata: 第二\r\rdata: tail\n\n".as_bytes();
    let expected = vec![
        SseMessage {
            event: Some("message".into()),
            data: "第一🙂\n第二".into(),
        },
        SseMessage {
            event: None,
            data: "tail".into(),
        },
    ];
    assert_eq!(decode(&[raw]), expected);
    assert_eq!(decode(&raw.chunks(1).collect::<Vec<_>>()), expected);
    for at in 0..=raw.len() {
        assert_eq!(decode(&[&raw[..at], &raw[at..]]), expected);
    }
}

#[test]
fn sse_comments_unknown_fields_and_empty_data_follow_event_framing() {
    let raw = b": ping\n\nid: 9\nretry: 100\nunknown: ignored\ndata:\n\ndata: x\n\n";
    assert_eq!(
        decode(&[raw]),
        vec![
            SseMessage {
                event: None,
                data: String::new()
            },
            SseMessage {
                event: None,
                data: "x".into()
            }
        ]
    );
}

#[test]
fn sse_eof_never_dispatches_incomplete_data_and_errors_are_safe() {
    for raw in [
        b"data: secret".as_slice(),
        b"data: secret\n",
        b"data: \xff\n\n",
    ] {
        let mut decoder = SseDecoder::new();
        let error = match decoder.push(raw) {
            Err(error) => error,
            Ok(frames) => {
                assert!(frames.is_empty());
                decoder.finish().unwrap_err()
            }
        };
        assert!(["incomplete_sse", "invalid_utf8"].contains(&error.code.as_str()));
        assert!(!serde_json::to_string(&error).unwrap().contains("secret"));
    }
}

#[test]
fn sse_bounds_pending_event_and_total_input_even_for_comments() {
    let mut decoder = SseDecoder::new();
    assert_eq!(
        decoder.push(&vec![b'x'; 1024 * 1024 + 1]).unwrap_err().code,
        "sse_event_too_large"
    );
    let mut decoder = SseDecoder::new();
    let comment = b":\n\n";
    for _ in 0..(8 * 1024 * 1024 / 3) {
        decoder.push(comment).unwrap();
    }
    assert_eq!(
        decoder.push(comment).unwrap_err().code,
        "sse_input_too_large"
    );
}

#[test]
fn chat_control_text_reasoning_tools_and_usage_are_distinct() {
    let mut adapter = ChatAdapter::new();
    assert!(adapter
        .accept(message(chunk(json!({"role":"assistant","content":""}))))
        .unwrap()
        .is_empty());
    assert_eq!(
        adapter
            .accept(message(chunk(json!({"reasoning_content":"想"}))))
            .unwrap(),
        vec![content(ContentKind::Reasoning, None)]
    );
    assert_eq!(
        adapter
            .accept(message(chunk(json!({"reasoning":"考", "content":"字"}))))
            .unwrap(),
        vec![
            content(ContentKind::Reasoning, None),
            content(ContentKind::Text, None)
        ]
    );
    assert_eq!(adapter.accept(message(chunk(json!({"tool_calls":[{"index":0,"id":"call","type":"function","function":{"name":"f","arguments":"{}"}}]})))).unwrap(),
        vec![content(ContentKind::Tool,None)]);
    assert_eq!(adapter.response_model(), Some("response-model"));
    let mut finished = chunk(json!({}));
    finished["choices"][0]["finish_reason"] = json!("stop");
    assert_eq!(
        adapter.accept(message(finished)).unwrap(),
        vec![StreamEvent::Finish(FinishReason::Stop)]
    );
    assert_eq!(
        adapter
            .accept(message(usage(
                json!({"prompt_tokens":2,"completion_tokens":7,"total_tokens":9,
        "completion_tokens_details":{"reasoning_tokens":3}})
            )))
            .unwrap(),
        vec![StreamEvent::Usage(TokenUsage {
            input_tokens: Some(2),
            output_tokens: 7,
            reasoning_tokens: Some(3)
        })]
    );
    assert_eq!(
        adapter
            .accept(SseMessage {
                event: None,
                data: "[DONE]".into()
            })
            .unwrap(),
        vec![StreamEvent::Done]
    );
    assert!(adapter
        .accept(message(chunk(json!({"content":"late"}))))
        .is_err());
}

#[test]
fn chat_segmentation_never_becomes_token_counts() {
    let frames = [
        chunk(json!({"role":"assistant"})),
        chunk(json!({"content":"你好🙂"})),
        usage(json!({"completion_tokens":8})),
    ];
    let raw = format!(
        "{}data: [DONE]\n\n",
        frames
            .iter()
            .map(|v| format!("data: {v}\n\n"))
            .collect::<String>()
    );
    let expected = vec![
        content(ContentKind::Text, None),
        StreamEvent::Usage(TokenUsage {
            input_tokens: None,
            output_tokens: 8,
            reasoning_tokens: None,
        }),
        StreamEvent::Done,
    ];
    for size in [1, 2, 7, raw.len()] {
        let mut adapter = ChatAdapter::new();
        let mut actual = vec![];
        for frame in decode(&raw.as_bytes().chunks(size).collect::<Vec<_>>()) {
            actual.extend(adapter.accept(frame).unwrap());
        }
        assert_eq!(actual, expected);
    }
}

#[test]
fn chat_only_first_visible_text_logprobs_are_a_count_candidate() {
    let mut adapter = ChatAdapter::new();
    let mut role = chunk(json!({"role":"assistant"}));
    role["choices"][0]["logprobs"] = json!({"content":[{"token":"x"}]});
    assert!(adapter.accept(message(role)).unwrap().is_empty());
    let mut first = chunk(json!({"content":"字🙂"}));
    first["choices"][0]["logprobs"] = json!({"content":[{"token":"字"},{"token":"🙂"}]});
    assert_eq!(
        adapter.accept(message(first.clone())).unwrap(),
        vec![content(ContentKind::Text, Some(2))]
    );
    assert_eq!(
        adapter.accept(message(first)).unwrap(),
        vec![content(ContentKind::Text, None)]
    );
    let mut adapter = ChatAdapter::new();
    let mut mixed = chunk(json!({"reasoning":"r","content":"字"}));
    mixed["choices"][0]["logprobs"] = json!({"content":[{"token":"字"}]});
    assert_eq!(
        adapter.accept(message(mixed)).unwrap(),
        vec![
            content(ContentKind::Reasoning, None),
            content(ContentKind::Text, None)
        ]
    );
}

#[test]
fn chat_rejects_identity_choice_unknown_schema_and_malformed_json() {
    let invalid = vec![
        json!({}),
        json!({"error":{"message":"secret"}}),
        {
            let mut v = chunk(json!({}));
            v["choices"][0]["index"] = json!(1);
            v
        },
        {
            let mut v = chunk(json!({}));
            v["choices"]
                .as_array_mut()
                .unwrap()
                .push(json!({"index":1,"delta":{}}));
            v
        },
        chunk(json!({"audio":{"data":"secret"}})),
        chunk(json!({"content":["secret"]})),
        {
            let mut v = chunk(json!({}));
            v["object"] = json!("chat.completion");
            v
        },
    ];
    for value in invalid {
        assert!(ChatAdapter::new().accept(message(value)).is_err());
    }
    let mut adapter = ChatAdapter::new();
    adapter.accept(message(chunk(json!({})))).unwrap();
    for field in ["id", "model"] {
        let mut v = chunk(json!({"content":"secret"}));
        v[field] = json!("different");
        assert_eq!(
            adapter.accept(message(v)).unwrap_err().code,
            "response_identity_changed"
        );
    }
    let error = ChatAdapter::new()
        .accept(SseMessage {
            event: None,
            data: "{secret".into(),
        })
        .unwrap_err();
    assert_eq!(error.code, "invalid_chat_json");
    assert!(!serde_json::to_string(&error).unwrap().contains("secret"));
}

#[test]
fn chat_validates_counts_consistency_and_does_not_invent_hidden_reasoning() {
    for invalid in [
        json!({"completion_tokens":-1}),
        json!({"completion_tokens":1.5}),
        json!({"completion_tokens":"2"}),
        json!({"completion_tokens":9007199254740992u64}),
        json!({"completion_tokens":2,"completion_tokens_details":{"reasoning_tokens":3}}),
        json!({"prompt_tokens":3,"completion_tokens":2,"total_tokens":6}),
        json!({"completion_tokens":2,"total_tokens":1}),
        json!({"prompt_tokens":1}),
    ] {
        assert!(ChatAdapter::new().accept(message(usage(invalid))).is_err());
    }
    let mut adapter = ChatAdapter::new();
    let final_usage = usage(json!({"completion_tokens":0}));
    assert_eq!(
        adapter.accept(message(final_usage.clone())).unwrap(),
        vec![StreamEvent::Usage(TokenUsage {
            input_tokens: None,
            output_tokens: 0,
            reasoning_tokens: None
        })]
    );
    assert!(adapter.accept(message(final_usage)).unwrap().is_empty());
    assert_eq!(
        adapter
            .accept(message(usage(json!({"completion_tokens":1}))))
            .unwrap_err()
            .code,
        "conflicting_usage"
    );
}

#[test]
fn chat_finish_reasons_and_content_after_finish_are_validated() {
    for (wire, reason) in [
        ("stop", FinishReason::Stop),
        ("length", FinishReason::Length),
        ("tool_calls", FinishReason::ToolCalls),
        ("content_filter", FinishReason::Filtered),
    ] {
        let mut adapter = ChatAdapter::new();
        let mut value = chunk(json!({}));
        value["choices"][0]["finish_reason"] = json!(wire);
        assert_eq!(
            adapter.accept(message(value)).unwrap(),
            vec![StreamEvent::Finish(reason)]
        );
        assert!(adapter
            .accept(message(chunk(json!({"content":"late"}))))
            .is_err());
    }
    let mut value = chunk(json!({}));
    value["choices"][0]["finish_reason"] = json!("unknown");
    assert!(ChatAdapter::new().accept(message(value)).is_err());
}

// Catches a skipped second extension validation and contradictory repeated totals.
#[test]
fn chat_validates_both_reasoning_fields() {
    assert!(ChatAdapter::new()
        .accept(message(chunk(json!({
            "reasoning_content":"valid", "reasoning":{"unknown":"secret"}
        }))))
        .is_err());
}

#[test]
fn chat_validates_repeated_total_scope() {
    let mut adapter = ChatAdapter::new();
    adapter
        .accept(message(usage(
            json!({"completion_tokens":2,"total_tokens":5}),
        )))
        .unwrap();
    assert_eq!(
        adapter
            .accept(message(usage(
                json!({"completion_tokens":2,"total_tokens":6})
            )))
            .unwrap_err()
            .code,
        "conflicting_usage"
    );
}
