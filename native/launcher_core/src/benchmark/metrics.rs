// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
// Adapted AIPerf metric rules at b1746a84a4665810abebb5ab09a6677d371c9e22.
// Changes: fail-closed counts, explicit scope/quality, prose-only TTFO, HTTP-EOF E2E.
// See licenses/AIPerf-Apache-2.0.txt and THIRD_PARTY_NOTICES.md.
use super::types::{FinishReason, TokenUsage};
use serde_json::{json, Value};

pub const ENGINE_VERSION: &str = "m2-rust-v1+aiperf-b1746a84";

#[derive(Default)]
pub(crate) struct Facts {
    pub first_content: Option<u64>,
    pub last_content: Option<u64>,
    pub first_visible: Option<u64>,
    pub last_visible: Option<u64>,
    pub usage_at: Option<u64>,
    pub done: Option<u64>,
    pub http_end: Option<u64>,
    pub usage: Option<TokenUsage>,
    pub finish: Option<FinishReason>,
    pub first_chunk_tokens: Option<u64>,
    pub has_reasoning: bool,
    pub has_tool: bool,
    pub reasons: Vec<String>,
}

fn reason(reasons: &mut Vec<String>, code: &str) {
    if !reasons.iter().any(|r| r == code) {
        reasons.push(code.to_owned());
    }
}

fn metric(
    value: Option<f64>,
    unit: &str,
    quality: &str,
    reasons: &[String],
    numerator: Option<u64>,
    denominator: Option<u64>,
    source: &str,
) -> Value {
    json!({"value":value,"unit":unit,"quality":quality,"reasons":reasons,
        "numeratorTokens":numerator,"denominatorNs":denominator,"countSource":source})
}
fn latency(ns: Option<u64>, missing: &str) -> Value {
    match ns {
        Some(ns) => metric(
            Some(ns as f64 / 1_000_000.0),
            "ms",
            "measured",
            &[],
            None,
            Some(ns),
            "monotonic_clock",
        ),
        None => metric(
            None,
            "ms",
            "unavailable",
            &[missing.into()],
            None,
            None,
            "monotonic_clock",
        ),
    }
}
fn rate(tokens: u64, ns: u64, quality: &str, reasons: &[String], source: &str) -> Value {
    metric(
        Some(tokens as f64 * 1_000_000_000.0 / ns as f64),
        "tokens/s",
        quality,
        reasons,
        Some(tokens),
        Some(ns),
        source,
    )
}
fn unavailable(reasons: &[String]) -> Value {
    metric(
        None,
        "tokens/s",
        "unavailable",
        reasons,
        None,
        None,
        "reported_completion_tokens",
    )
}

pub(crate) fn snapshot(f: &Facts) -> Value {
    let mut reasons = f.reasons.clone();
    if f.finish != Some(FinishReason::Stop) {
        reason(
            &mut reasons,
            if f.finish.is_some() {
                "non_stop_finish"
            } else {
                "missing_finish"
            },
        );
    }
    if f.done.is_none() {
        reason(&mut reasons, "missing_done");
    }
    if f.http_end.is_none() {
        reason(&mut reasons, "missing_http_eof");
    }
    if f.usage.is_none() {
        reason(&mut reasons, "missing_usage");
    }
    if f.http_end == Some(0) {
        reason(&mut reasons, "nonpositive_http_duration");
    }
    if let Some(u) = &f.usage {
        if u.reasoning_tokens.is_some_and(|r| r > u.output_tokens) {
            reason(&mut reasons, "invalid_reasoning_count");
        }
    }
    let successful = reasons.is_empty();
    let mut stream = unavailable(&reasons);
    let mut full = unavailable(&reasons);
    let mut e2e = unavailable(&reasons);
    if successful {
        let u = f.usage.as_ref().expect("validated usage");
        let end = f.http_end.expect("validated HTTP EOF");
        e2e = rate(
            u.output_tokens,
            end,
            "reported",
            &[],
            "reported_completion_tokens_including_reasoning",
        );
        let mut scope = Vec::new();
        // A first-chunk candidate can be unusable for decoding without invalidating
        // final server usage or the independent full-request HTTP denominator.
        if let Some(first) = f.first_chunk_tokens {
            if first == 0 || first >= u.output_tokens {
                reason(&mut scope, "first_chunk_count_not_usable");
            }
        }
        if let (Some(first), Some(last)) = (f.first_content, f.last_content) {
            if last <= first {
                reason(&mut scope, "nonpositive_content_duration");
            }
        }
        if f.first_content.is_none() {
            reason(&mut scope, "missing_content");
        }
        if u.output_tokens < 2 {
            reason(&mut scope, "insufficient_output_tokens");
        }
        if f.has_reasoning || u.reasoning_tokens.is_some_and(|r| r > 0) {
            reason(&mut scope, "reasoning_generation_boundary_unknown");
        }
        if f.has_tool {
            reason(&mut scope, "tool_token_scope_unknown");
        }
        if scope.is_empty() {
            let exact = f.first_chunk_tokens.is_some() && u.reasoning_tokens == Some(0);
            let first = if exact {
                f.first_chunk_tokens.unwrap()
            } else {
                1
            };
            let mut estimates = Vec::new();
            if !exact {
                reason(&mut estimates, "first_chunk_assumed_one");
            }
            if u.reasoning_tokens.is_none() {
                reason(&mut estimates, "reasoning_scope_unknown");
            }
            let quality = if exact { "reported" } else { "estimated" };
            let source = if exact {
                "reported_completion_tokens_minus_first_text_logprobs"
            } else {
                "reported_completion_tokens_minus_assumed_one"
            };
            let first_ns = f.first_content.unwrap();
            stream = rate(
                u.output_tokens - first,
                f.last_content.unwrap() - first_ns,
                quality,
                &estimates,
                source,
            );
            full = rate(
                u.output_tokens - first,
                end - first_ns,
                quality,
                &estimates,
                source,
            );
        } else {
            stream = unavailable(&scope);
            full = unavailable(&scope);
        }
    }
    json!({"engineVersion":ENGINE_VERSION,"successfulSample":successful,"reasons":reasons,
        "timingsNs":{"start":0,"firstContent":f.first_content,"lastContent":f.last_content,
            "firstVisible":f.first_visible,"lastVisible":f.last_visible,"usage":f.usage_at,"done":f.done,"httpEnd":f.http_end},
        "usage":f.usage.as_ref().map(|u|json!({"inputTokens":u.input_tokens,"outputTokens":u.output_tokens,"reasoningTokens":u.reasoning_tokens})),
        "metrics":{"ttftMs":latency(f.first_content,"missing_content"),"ttfoMs":latency(f.first_visible,"missing_visible_text"),
            "streamTokensPerSecond":stream,"e2eTokensPerSecond":e2e,"fullResponseTokensPerSecond":full}})
}
