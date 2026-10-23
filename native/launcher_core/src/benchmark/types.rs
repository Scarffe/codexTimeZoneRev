use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum ContentKind {
    Text,
    Reasoning,
    Tool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TokenUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: u64,
    pub reasoning_tokens: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum FinishReason {
    Stop,
    Length,
    ToolCalls,
    Filtered,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum StreamEvent {
    Scope {
        reasoning: bool,
        tool: bool,
    },
    Invalidation(String),
    ProtocolTerminal(String),
    Content {
        kind: ContentKind,
        first_chunk_tokens: Option<u64>,
    },
    Usage(TokenUsage),
    Finish(FinishReason),
    Done,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct StreamError {
    pub code: String,
}

impl StreamError {
    /// Only compile-time codes may be supplied; never pass upstream/parser text.
    pub fn new(code: &'static str) -> Self {
        Self { code: code.into() }
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SseMessage {
    pub event: Option<String>,
    pub data: String,
}
