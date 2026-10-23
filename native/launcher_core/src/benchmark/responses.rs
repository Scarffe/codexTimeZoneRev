//! Supported Responses text-stream normalization. No response text is retained.
use super::types::{ContentKind, FinishReason, SseMessage, StreamError, StreamEvent, TokenUsage};
use serde_json::Value;
use std::{
    collections::{hash_map::DefaultHasher, BTreeMap, BTreeSet},
    hash::Hasher,
};
type Result<T> = std::result::Result<T, StreamError>;
const MAX: u64 = 9_007_199_254_740_991;
#[derive(Clone)]
struct Item {
    id: String,
    kind: String,
}
// Fixed-size per-part comparison metadata; never accumulate response strings.
// Write raw bytes, not Hash::hash(str): chunk boundaries must not affect the digest.
#[derive(Clone, Default)]
struct ObservedText {
    bytes: usize,
    digest: DefaultHasher,
}
impl ObservedText {
    fn append(&mut self, text: &str) -> Result<()> {
        self.bytes = self.bytes.checked_add(text.len()).ok_or_else(schema)?;
        self.digest.write(text.as_bytes());
        Ok(())
    }
    fn matches(&self, text: &str) -> bool {
        let mut snapshot = DefaultHasher::new();
        snapshot.write(text.as_bytes());
        self.bytes == text.len() && self.digest.finish() == snapshot.finish()
    }
}
#[derive(Clone, Default)]
pub struct ResponsesAdapter {
    id: Option<String>,
    model: Option<String>,
    sequence: Option<u64>,
    items: BTreeMap<u64, Item>,
    parts: BTreeMap<(u64, bool, u64), String>,
    closed_items: BTreeSet<u64>,
    closed_parts: BTreeSet<(u64, bool, u64)>,
    observed_text_parts: BTreeMap<(u64, u64), ObservedText>,
    terminal: bool,
}
impl ResponsesAdapter {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn response_model(&self) -> Option<&str> {
        self.model.as_deref()
    }
    pub fn accept(&mut self, message: SseMessage) -> Result<Vec<StreamEvent>> {
        // Transactional validation: rejected frames cannot partially advance identity or facts.
        let mut next = self.clone();
        let events = next.frame(message)?;
        *self = next;
        Ok(events)
    }
    fn frame(&mut self, message: SseMessage) -> Result<Vec<StreamEvent>> {
        if self.terminal {
            return Err(err("responses_after_terminal"));
        }
        if message.data.len() > 1024 * 1024 {
            return Err(err("responses_message_too_large"));
        }
        let v: Value =
            serde_json::from_str(&message.data).map_err(|_| err("invalid_responses_json"))?;
        let kind = text(&v, "type")?;
        let common = ["type", "sequence_number"];
        let fields: &[&str] = match kind {
            "response.created"
            | "response.in_progress"
            | "response.completed"
            | "response.failed"
            | "response.incomplete" => &["response"],
            "response.output_item.added" | "response.output_item.done" => &["item", "output_index"],
            "error" => &["code", "message", "param"],
            "response.reasoning_summary_part.added" | "response.reasoning_summary_part.done" => {
                &["item_id", "output_index", "summary_index", "part"]
            }
            "response.content_part.added" | "response.content_part.done" => {
                &["item_id", "output_index", "content_index", "part"]
            }
            "response.function_call_arguments.delta" | "response.function_call_arguments.done" => {
                &[
                    "item_id",
                    "output_index",
                    "delta",
                    "arguments",
                    "name",
                    "obfuscation",
                ]
            }
            "response.reasoning_summary_text.delta" | "response.reasoning_summary_text.done" => &[
                "item_id",
                "output_index",
                "summary_index",
                "delta",
                "text",
                "obfuscation",
            ],
            _ => &[
                "item_id",
                "output_index",
                "content_index",
                "delta",
                "text",
                "logprobs",
                "obfuscation",
            ],
        };
        known(
            &v,
            &common
                .iter()
                .chain(fields.iter())
                .copied()
                .collect::<Vec<_>>(),
        )?;
        if message.event.as_deref().is_some_and(|s| s != kind) {
            return Err(err("responses_event_type_mismatch"));
        }
        let seq = count(v.get("sequence_number").ok_or_else(schema)?)?;
        if self.sequence.is_some_and(|old| seq <= old) {
            return Err(err("invalid_responses_sequence"));
        }
        self.sequence = Some(seq);
        let mut events = vec![];
        match kind {
            "response.created" | "response.in_progress" => {
                let r = v.get("response").ok_or_else(schema)?;
                self.identity(r)?;
                if text(r, "status")? != "in_progress" {
                    return Err(schema());
                }
                self.output(r, &mut events, false)?;
            }
            "response.output_item.added" | "response.output_item.done" => {
                self.require_identity()?;
                let index = index(&v, "output_index")?;
                let item = v.get("item").ok_or_else(schema)?;
                if self.closed_items.contains(&index) {
                    return Err(err("responses_item_after_done"));
                }
                scope_item(item, &mut events)?;
                self.snapshot_item(index, item, &mut events)?;
                if kind.ends_with(".done") {
                    self.closed_items.insert(index);
                }
            }
            "response.content_part.added"
            | "response.content_part.done"
            | "response.reasoning_summary_part.added"
            | "response.reasoning_summary_part.done" => {
                self.require_identity()?;
                let output = self.item(&v)?;
                let item = self.items.get(&output).unwrap();
                if self.closed_items.contains(&output) {
                    return Err(err("responses_item_after_done"));
                }
                let reasoning = kind.starts_with("response.reasoning_");
                if item.kind != if reasoning { "reasoning" } else { "message" } {
                    return Err(schema());
                }
                let part_index = index(
                    &v,
                    if reasoning {
                        "summary_index"
                    } else {
                        "content_index"
                    },
                )?;
                let part = v.get("part").ok_or_else(schema)?;
                let ty = text(part, "type")?;
                if ty
                    != if reasoning {
                        "summary_text"
                    } else {
                        "output_text"
                    }
                {
                    return Err(schema());
                }
                if let Some(s) = part.get("text") {
                    let data = s.as_str().ok_or_else(schema)?;
                    if !reasoning {
                        self.text_snapshot(output, part_index, data, &mut events);
                    }
                }
                if self.parts.len() >= 4096 {
                    return Err(schema());
                }
                if self
                    .parts
                    .get(&(output, reasoning, part_index))
                    .is_some_and(|old| old != ty)
                {
                    return Err(schema());
                }
                self.parts
                    .insert((output, reasoning, part_index), ty.into());
                if kind.ends_with(".done") {
                    self.closed_parts.insert((output, reasoning, part_index));
                }
            }
            "response.output_text.delta"
            | "response.output_text.done"
            | "response.reasoning_text.delta"
            | "response.reasoning_text.done"
            | "response.reasoning_summary_text.delta"
            | "response.reasoning_summary_text.done"
            | "response.function_call_arguments.delta"
            | "response.function_call_arguments.done" => {
                self.require_identity()?;
                let output = self.item(&v)?;
                let item = self.items.get(&output).unwrap();
                if self.closed_items.contains(&output) {
                    return Err(err("responses_item_after_done"));
                }
                let content = if kind.starts_with("response.output_text.") {
                    ContentKind::Text
                } else if kind.starts_with("response.function_call_arguments.") {
                    ContentKind::Tool
                } else {
                    ContentKind::Reasoning
                };
                let expected = match content {
                    ContentKind::Text => "message",
                    ContentKind::Reasoning => "reasoning",
                    ContentKind::Tool => "function_call",
                };
                if item.kind != expected {
                    return Err(schema());
                }
                let reasoning = kind.contains("summary");
                let part_index = if content == ContentKind::Tool {
                    0
                } else {
                    index(
                        &v,
                        if kind.contains("summary") {
                            "summary_index"
                        } else {
                            "content_index"
                        },
                    )?
                };
                if kind.ends_with(".delta")
                    && self.closed_parts.contains(&(output, reasoning, part_index))
                {
                    return Err(err("responses_content_after_done"));
                }
                if content != ContentKind::Tool {
                    let idx = part_index;
                    if idx > 4095 {
                        return Err(schema());
                    }
                    let ty = if kind.contains("summary") {
                        "summary_text"
                    } else if content == ContentKind::Text {
                        "output_text"
                    } else {
                        "reasoning_text"
                    };
                    if let Some(part) = self.parts.get(&(output, kind.contains("summary"), idx)) {
                        if part != ty {
                            return Err(schema());
                        }
                    }
                    if self.parts.len() >= 4096 {
                        return Err(schema());
                    }
                    self.parts
                        .insert((output, kind.contains("summary"), idx), ty.into());
                }
                let delta = kind.ends_with(".delta");
                let field = if delta {
                    "delta"
                } else if content == ContentKind::Tool {
                    "arguments"
                } else {
                    "text"
                };
                let data = v.get(field).and_then(Value::as_str).ok_or_else(schema)?;
                if !delta {
                    if content == ContentKind::Text {
                        self.text_snapshot(output, part_index, data, &mut events);
                    }
                    self.closed_parts.insert((output, reasoning, part_index));
                }
                if delta && !data.is_empty() {
                    if content == ContentKind::Text {
                        self.observed_text_parts
                            .entry((output, part_index))
                            .or_default()
                            .append(data)?;
                    }
                    events.push(StreamEvent::Content {
                        kind: content,
                        first_chunk_tokens: None,
                    });
                }
            }
            "response.completed" | "response.failed" | "response.incomplete" => {
                let r = v.get("response").ok_or_else(schema)?;
                self.identity(r)?;
                if text(r, "status")? != kind.strip_prefix("response.").unwrap() {
                    return Err(schema());
                }
                self.output(r, &mut events, true)?;
                if let Some(u) = r.get("usage").filter(|u| !u.is_null()) {
                    events.push(StreamEvent::Usage(usage(u)?));
                }
                if kind == "response.completed" {
                    events.push(StreamEvent::Finish(FinishReason::Stop));
                } else {
                    events.push(StreamEvent::Invalidation(
                        if kind == "response.failed" {
                            "response_failed"
                        } else {
                            "response_incomplete"
                        }
                        .into(),
                    ));
                }
                events.push(StreamEvent::ProtocolTerminal(kind.into()));
                events.push(StreamEvent::Done);
                self.terminal = true;
            }
            "error" => {
                events.push(StreamEvent::Invalidation("response_error".into()));
                events.push(StreamEvent::ProtocolTerminal("error".into()));
                events.push(StreamEvent::Done);
                self.terminal = true;
            }
            _ => return Err(err("unsupported_responses_event")),
        }
        Ok(events)
    }
    fn require_identity(&self) -> Result<()> {
        if self.id.is_none() {
            Err(err("missing_response_identity"))
        } else {
            Ok(())
        }
    }
    fn identity(&mut self, r: &Value) -> Result<()> {
        let id = text(r, "id")?;
        let model = text(r, "model")?;
        if self.id.as_deref().is_some_and(|s| s != id)
            || self.model.as_deref().is_some_and(|s| s != model)
        {
            return Err(err("response_identity_changed"));
        }
        self.id = Some(id.into());
        self.model = Some(model.into());
        Ok(())
    }
    fn item(&self, v: &Value) -> Result<u64> {
        let index = index(v, "output_index")?;
        let id = text(v, "item_id")?;
        if self.items.get(&index).is_none_or(|i| i.id != id) {
            return Err(err("invalid_responses_item"));
        }
        Ok(index)
    }
    fn text_snapshot(&self, output: u64, part: u64, text: &str, events: &mut Vec<StreamEvent>) {
        let reconciled = self
            .observed_text_parts
            .get(&(output, part))
            .map_or(text.is_empty(), |observed| observed.matches(text));
        if !reconciled {
            // Snapshot text has no delta arrival time. This sticky fact only
            // removes generation-window rates; usage, E2E and timestamps survive.
            events.push(StreamEvent::TextBoundaryUnknown);
        }
    }
    fn snapshot_item(
        &mut self,
        index: u64,
        item: &Value,
        events: &mut Vec<StreamEvent>,
    ) -> Result<()> {
        let id = text(item, "id")?;
        let kind = text(item, "type")?;
        if let Some(old) = self.items.get(&index) {
            if old.id != id || old.kind != kind {
                return Err(err("responses_item_identity_changed"));
            }
        } else {
            if self.items.len() >= 4096 || self.items.values().any(|old| old.id == id) {
                return Err(schema());
            }
            self.items.insert(
                index,
                Item {
                    id: id.into(),
                    kind: kind.into(),
                },
            );
        }
        // Every present item is a snapshot of its already established parts,
        // including intermediate snapshots. Missing items are only forbidden
        // at terminal; a present item may not erase a known part association.
        for ((known_item, summary, part_index), kind) in &self.parts {
            if *known_item == index {
                let field = if *summary { "summary" } else { "content" };
                let part = item
                    .get(field)
                    .and_then(Value::as_array)
                    .and_then(|parts| parts.get(*part_index as usize))
                    .ok_or_else(schema)?;
                if text(part, "type")? != kind {
                    return Err(schema());
                }
            }
        }
        let fields: &[(&str, bool)] = match kind {
            "message" => &[("content", false)],
            "reasoning" => &[("summary", true), ("content", false)],
            _ => &[],
        };
        for (field, summary) in fields {
            if let Some(parts) = item.get(*field).filter(|v| !v.is_null()) {
                for (part_index, part) in parts.as_array().ok_or_else(schema)?.iter().enumerate() {
                    if self.parts.len() >= 4096 {
                        return Err(schema());
                    }
                    if kind == "message" {
                        self.text_snapshot(
                            index,
                            part_index as u64,
                            part.get("text")
                                .and_then(Value::as_str)
                                .ok_or_else(schema)?,
                            events,
                        );
                    }
                    self.parts.insert(
                        (index, *summary, part_index as u64),
                        text(part, "type")?.into(),
                    );
                }
            }
        }
        Ok(())
    }
    fn output(&mut self, r: &Value, events: &mut Vec<StreamEvent>, terminal: bool) -> Result<()> {
        let output = r
            .get("output")
            .and_then(Value::as_array)
            .ok_or_else(schema)?;
        if output.len() > 4096 {
            return Err(schema());
        }
        let mut ids = std::collections::BTreeSet::new();
        for (index, item) in output.iter().enumerate() {
            if !ids.insert(text(item, "id")?) {
                return Err(schema());
            }
            scope_item(item, events)?;
            self.snapshot_item(index as u64, item, events)?;
        }
        if terminal {
            if self.items.keys().any(|i| *i as usize >= output.len()) {
                return Err(err("missing_responses_output_item"));
            }
        }
        Ok(())
    }
}
fn err(code: &'static str) -> StreamError {
    StreamError::new(code)
}
fn schema() -> StreamError {
    err("unsupported_responses_schema")
}
fn known(v: &Value, fields: &[&str]) -> Result<()> {
    let map = v.as_object().ok_or_else(schema)?;
    if map
        .iter()
        .any(|(key, value)| !fields.contains(&key.as_str()) && !value.is_null())
    {
        return Err(schema());
    }
    Ok(())
}
fn text<'a>(v: &'a Value, field: &str) -> Result<&'a str> {
    v.get(field)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .ok_or_else(schema)
}
fn count(v: &Value) -> Result<u64> {
    v.as_u64()
        .filter(|n| *n <= MAX)
        .ok_or_else(|| err("invalid_token_count"))
}
fn index(v: &Value, key: &str) -> Result<u64> {
    let n = count(v.get(key).ok_or_else(schema)?)?;
    if n > 4095 {
        Err(schema())
    } else {
        Ok(n)
    }
}
fn scope_item(item: &Value, events: &mut Vec<StreamEvent>) -> Result<()> {
    text(item, "id")?;
    match text(item, "type")? {
        "message" => {
            if text(item, "role")? != "assistant" {
                return Err(schema());
            }
            let parts = item
                .get("content")
                .and_then(Value::as_array)
                .ok_or_else(schema)?;
            if parts.len() > 4096 {
                return Err(schema());
            }
            for part in parts {
                if text(part, "type")? != "output_text"
                    || part.get("text").and_then(Value::as_str).is_none()
                {
                    return Err(schema());
                }
            }
        }
        "reasoning" => {
            let summary = item
                .get("summary")
                .and_then(Value::as_array)
                .ok_or_else(schema)?;
            for part in summary {
                if text(part, "type")? != "summary_text"
                    || part.get("text").and_then(Value::as_str).is_none()
                {
                    return Err(schema());
                }
            }
            if let Some(content) = item.get("content").filter(|v| !v.is_null()) {
                let content = content.as_array().ok_or_else(schema)?;
                if content.len() > 4096 {
                    return Err(schema());
                }
                for part in content {
                    if text(part, "type")? != "reasoning_text"
                        || part.get("text").and_then(Value::as_str).is_none()
                    {
                        return Err(schema());
                    }
                }
            }
            events.push(StreamEvent::Scope {
                reasoning: true,
                tool: false,
            });
        }
        "function_call" => {
            for f in ["name", "call_id"] {
                text(item, f)?;
            }
            if item.get("arguments").and_then(Value::as_str).is_none() {
                return Err(schema());
            }
            events.push(StreamEvent::Scope {
                reasoning: false,
                tool: true,
            });
        }
        _ => return Err(schema()),
    }
    Ok(())
}
fn usage(v: &Value) -> Result<TokenUsage> {
    known(
        v,
        &[
            "input_tokens",
            "output_tokens",
            "total_tokens",
            "input_tokens_details",
            "output_tokens_details",
        ],
    )?;
    let input = v
        .get("input_tokens")
        .filter(|v| !v.is_null())
        .map(count)
        .transpose()?;
    let output = count(
        v.get("output_tokens")
            .ok_or_else(|| err("invalid_token_count"))?,
    )?;
    if let Some(total) = v.get("total_tokens").filter(|v| !v.is_null()) {
        let total = count(total)?;
        if input.map_or(total < output, |n| n.checked_add(output) != Some(total)) {
            return Err(err("inconsistent_token_usage"));
        }
    }
    let details = v.get("output_tokens_details").filter(|v| !v.is_null());
    if details.is_some_and(|v| !v.is_object()) {
        return Err(schema());
    }
    if let Some(details) = details {
        known(details, &["reasoning_tokens"])?;
    }
    let reasoning = details
        .and_then(|v| v.get("reasoning_tokens"))
        .filter(|v| !v.is_null())
        .map(count)
        .transpose()?;
    if reasoning.is_some_and(|n| n > output) {
        return Err(err("invalid_reasoning_count"));
    }
    if let Some(details) = v.get("input_tokens_details").filter(|v| !v.is_null()) {
        known(details, &["cached_tokens"])?;
        let cached = details
            .get("cached_tokens")
            .filter(|v| !v.is_null())
            .map(count)
            .transpose()?;
        if !details.is_object() || cached.zip(input).is_some_and(|(n, total)| n > total) {
            return Err(err("inconsistent_token_usage"));
        }
    }
    Ok(TokenUsage {
        input_tokens: input,
        output_tokens: output,
        reasoning_tokens: reasoning,
    })
}
