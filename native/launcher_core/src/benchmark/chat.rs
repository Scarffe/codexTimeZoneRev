use super::types::{ContentKind, FinishReason, SseMessage, StreamError, StreamEvent, TokenUsage};
use serde_json::{Map, Value};

const MAX_COUNTER: u64 = 9_007_199_254_740_991;
const MAX_MESSAGE: usize = 1024 * 1024;
type Result<T> = std::result::Result<T, StreamError>;

/// Normalizes the supported Chat streaming schema without retaining response text.
/// Visible reasoning fields are compatibility extensions documented by pinned AIPerf.
pub struct ChatAdapter {
    id: Option<String>,
    model: Option<String>,
    usage: Option<TokenUsage>,
    finish: Option<FinishReason>,
    done: bool,
    visible_seen: bool,
    usage_total: Option<u64>,
}
impl ChatAdapter {
    pub fn new() -> Self {
        Self {
            id: None,
            model: None,
            usage: None,
            finish: None,
            done: false,
            visible_seen: false,
            usage_total: None,
        }
    }
    pub fn accept(&mut self, message: SseMessage) -> Result<Vec<StreamEvent>> {
        if self.done {
            return Err(StreamError::new("chat_after_done"));
        }
        if message.data.len() > MAX_MESSAGE {
            return Err(StreamError::new("chat_message_too_large"));
        }
        if message
            .event
            .as_deref()
            .is_some_and(|event| event != "message" && !event.is_empty())
        {
            return Err(StreamError::new("unsupported_sse_event"));
        }
        if message.data == "[DONE]" {
            self.done = true;
            return Ok(vec![StreamEvent::Done]);
        }
        let value: Value = serde_json::from_str(&message.data)
            .map_err(|_| StreamError::new("invalid_chat_json"))?;
        let root = object(&value)?;
        known(
            root,
            &[
                "id",
                "model",
                "object",
                "created",
                "choices",
                "usage",
                "system_fingerprint",
                "service_tier",
            ],
        )?;
        if root.get("object").and_then(Value::as_str) != Some("chat.completion.chunk") {
            return Err(StreamError::new("unsupported_chat_schema"));
        }
        let id = identity(root.get("id"))?;
        let model = identity(root.get("model"))?;
        if self.id.as_deref().is_some_and(|old| old != id)
            || self.model.as_deref().is_some_and(|old| old != model)
        {
            return Err(StreamError::new("response_identity_changed"));
        }
        if let Some(created) = root.get("created") {
            counter(created)?;
        }
        for field in ["system_fingerprint", "service_tier"] {
            optional_string(root.get(field))?;
        }
        let choices = root
            .get("choices")
            .and_then(Value::as_array)
            .ok_or_else(schema)?;
        if choices.len() > 1 {
            return Err(StreamError::new("unsupported_choices"));
        }
        let mut events = vec![];
        let mut next_finish = None;
        let mut has_text = false;
        if let Some(choice) = choices.first() {
            let choice = object(choice)?;
            known(choice, &["index", "delta", "finish_reason", "logprobs"])?;
            if choice.get("index").and_then(Value::as_u64) != Some(0) {
                return Err(StreamError::new("unsupported_choices"));
            }
            let delta = object(choice.get("delta").ok_or_else(schema)?)?;
            known(
                delta,
                &[
                    "role",
                    "content",
                    "reasoning_content",
                    "reasoning",
                    "tool_calls",
                    "refusal",
                ],
            )?;
            if let Some(role) = optional_string(delta.get("role"))? {
                if role != "assistant" {
                    return Err(schema());
                }
            }
            if optional_string(delta.get("refusal"))?.is_some_and(|s| !s.is_empty()) {
                return Err(schema());
            }
            let reasoning =
                nonempty(delta.get("reasoning_content"))? | nonempty(delta.get("reasoning"))?;
            has_text = nonempty(delta.get("content"))?;
            let tools = tool_content(delta.get("tool_calls"))?;
            let candidate = logprobs_count(choice.get("logprobs"))?;
            if self.finish.is_some() && (reasoning || has_text || tools) {
                return Err(StreamError::new("content_after_finish"));
            }
            if reasoning {
                events.push(StreamEvent::Content {
                    kind: ContentKind::Reasoning,
                    first_chunk_tokens: None,
                });
            }
            if has_text {
                events.push(StreamEvent::Content {
                    kind: ContentKind::Text,
                    first_chunk_tokens: if !self.visible_seen && !reasoning && !tools {
                        candidate
                    } else {
                        None
                    },
                });
            }
            if tools {
                events.push(StreamEvent::Content {
                    kind: ContentKind::Tool,
                    first_chunk_tokens: None,
                });
            }
            if let Some(reason) = optional_string(choice.get("finish_reason"))? {
                let reason = match reason {
                    "stop" => FinishReason::Stop,
                    "length" => FinishReason::Length,
                    "tool_calls" => FinishReason::ToolCalls,
                    "content_filter" => FinishReason::Filtered,
                    _ => return Err(StreamError::new("unsupported_finish_reason")),
                };
                if self.finish.as_ref().is_some_and(|old| old != &reason) {
                    return Err(StreamError::new("conflicting_finish"));
                }
                if self.finish.is_none() {
                    events.push(StreamEvent::Finish(reason.clone()));
                    next_finish = Some(reason);
                }
            }
        }
        let mut next_usage = None;
        let mut next_total = None;
        if let Some(value) = root.get("usage").filter(|v| !v.is_null()) {
            let parsed = parse_usage(value)?;
            next_total = optional_counter(value.get("total_tokens"))?;
            if self
                .usage_total
                .zip(next_total)
                .is_some_and(|(old, new)| old != new)
            {
                return Err(StreamError::new("conflicting_usage"));
            }
            if let Some(previous) = &self.usage {
                if previous != &parsed {
                    return Err(StreamError::new("conflicting_usage"));
                }
            } else {
                events.push(StreamEvent::Usage(parsed.clone()));
                next_usage = Some(parsed);
            }
        } else if choices.is_empty() {
            return Err(schema());
        }
        // Commit only after the whole message validates.
        if self.id.is_none() {
            self.id = Some(id.into());
            self.model = Some(model.into());
        }
        self.visible_seen |= has_text;
        if let Some(reason) = next_finish {
            self.finish = Some(reason);
        }
        if let Some(usage) = next_usage {
            self.usage = Some(usage);
        }
        self.usage_total = self.usage_total.or(next_total);
        Ok(events)
    }
    pub fn response_model(&self) -> Option<&str> {
        self.model.as_deref()
    }
}

fn schema() -> StreamError {
    StreamError::new("unsupported_chat_schema")
}
fn object(value: &Value) -> Result<&Map<String, Value>> {
    value.as_object().ok_or_else(schema)
}
fn known(map: &Map<String, Value>, fields: &[&str]) -> Result<()> {
    for (key, value) in map {
        if !fields.contains(&key.as_str()) && !value.is_null() {
            return Err(schema());
        }
    }
    Ok(())
}
fn optional_string(value: Option<&Value>) -> Result<Option<&str>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        _ => Err(schema()),
    }
}
fn nonempty(value: Option<&Value>) -> Result<bool> {
    Ok(optional_string(value)?.is_some_and(|s| !s.is_empty()))
}
fn identity(value: Option<&Value>) -> Result<&str> {
    optional_string(value)?
        .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .ok_or_else(schema)
}
fn counter(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .filter(|n| *n <= MAX_COUNTER)
        .ok_or_else(|| StreamError::new("invalid_token_count"))
}
fn optional_counter(value: Option<&Value>) -> Result<Option<u64>> {
    value.filter(|v| !v.is_null()).map(counter).transpose()
}
fn tool_content(value: Option<&Value>) -> Result<bool> {
    let Some(value) = value.filter(|v| !v.is_null()) else {
        return Ok(false);
    };
    let tools = value.as_array().ok_or_else(schema)?;
    let mut content = false;
    for tool in tools {
        let tool = object(tool)?;
        known(tool, &["index", "id", "type", "function"])?;
        counter(tool.get("index").ok_or_else(schema)?)?;
        optional_string(tool.get("id"))?;
        if optional_string(tool.get("type"))?.is_some_and(|kind| kind != "function") {
            return Err(schema());
        }
        if let Some(function) = tool.get("function").filter(|v| !v.is_null()) {
            let function = object(function)?;
            known(function, &["name", "arguments"])?;
            content |= nonempty(function.get("name"))? | nonempty(function.get("arguments"))?;
        }
    }
    Ok(content)
}
fn logprobs_count(value: Option<&Value>) -> Result<Option<u64>> {
    let Some(value) = value.filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    let map = object(value)?;
    known(map, &["content", "refusal"])?;
    if map
        .get("refusal")
        .is_some_and(|v| !v.is_null() && v.as_array().is_none_or(|v| !v.is_empty()))
    {
        return Err(schema());
    }
    let Some(entries) = map.get("content").filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    let entries = entries.as_array().ok_or_else(schema)?;
    for entry in entries {
        let entry = object(entry)?;
        known(entry, &["token", "logprob", "bytes", "top_logprobs"])?;
        if !nonempty(entry.get("token"))? {
            return Err(schema());
        }
    }
    Ok((!entries.is_empty()).then_some(entries.len() as u64))
}
fn parse_usage(value: &Value) -> Result<TokenUsage> {
    let map = object(value)?;
    known(
        map,
        &[
            "prompt_tokens",
            "completion_tokens",
            "total_tokens",
            "prompt_tokens_details",
            "completion_tokens_details",
        ],
    )?;
    let input = optional_counter(map.get("prompt_tokens"))?;
    let output = counter(
        map.get("completion_tokens")
            .ok_or_else(|| StreamError::new("invalid_token_count"))?,
    )?;
    let total = optional_counter(map.get("total_tokens"))?;
    if total.is_some_and(|total| {
        input.map_or(total < output, |input| {
            input.checked_add(output) != Some(total)
        })
    }) {
        return Err(StreamError::new("inconsistent_token_usage"));
    }
    let mut reasoning = None;
    for (field, allowed, limit) in [
        (
            "prompt_tokens_details",
            &["cached_tokens", "audio_tokens"][..],
            input,
        ),
        (
            "completion_tokens_details",
            &[
                "reasoning_tokens",
                "audio_tokens",
                "accepted_prediction_tokens",
                "rejected_prediction_tokens",
            ][..],
            Some(output),
        ),
    ] {
        if let Some(details) = map.get(field).filter(|v| !v.is_null()) {
            let details = object(details)?;
            known(details, allowed)?;
            for (name, count) in details {
                let count = optional_counter(Some(count))?;
                if count.zip(limit).is_some_and(|(count, limit)| count > limit) {
                    return Err(StreamError::new("inconsistent_token_usage"));
                }
                if field == "completion_tokens_details" && name == "reasoning_tokens" {
                    reasoning = count;
                }
            }
        }
    }
    Ok(TokenUsage {
        input_tokens: input,
        output_tokens: output,
        reasoning_tokens: reasoning,
    })
}
