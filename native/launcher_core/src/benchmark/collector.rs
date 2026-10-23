use super::metrics::{self, Facts};
use super::types::{ContentKind, StreamError, StreamEvent};
use serde_json::Value;

/// A bounded, request-relative fact collector. No request/response text is retained.
#[derive(Default)]
pub struct Collector {
    facts: Facts,
    previous_ns: Option<u64>,
}

impl Collector {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn for_responses() -> Self {
        let mut c = Self::new();
        c.facts.responses = true;
        c
    }

    fn reject(&mut self, code: &'static str) -> Result<(), StreamError> {
        self.fail(code);
        Err(StreamError::new(code))
    }

    fn advance(&mut self, ns: u64) -> Result<(), StreamError> {
        if self.previous_ns.is_some_and(|previous| ns < previous) {
            return self.reject("reversed_time");
        }
        self.previous_ns = Some(ns);
        Ok(())
    }

    pub fn observe(&mut self, at_ns: u64, event: StreamEvent) -> Result<(), StreamError> {
        self.advance(at_ns)?;
        if self.facts.http_end.is_some() {
            return self.reject("event_after_http_eof");
        }
        if self.facts.done.is_some() {
            return self.reject("event_after_done");
        }
        match event {
            StreamEvent::TextBoundaryUnknown => self.facts.unobserved_text = true,
            StreamEvent::Scope { reasoning, tool } => {
                self.facts.has_reasoning |= reasoning;
                self.facts.has_tool |= tool;
            }
            StreamEvent::Invalidation(code) => self.fail(&code),
            StreamEvent::ProtocolTerminal(kind) => self.facts.protocol_terminal = Some(kind),
            StreamEvent::Content {
                kind,
                first_chunk_tokens,
            } => {
                if self.facts.finish.is_some() {
                    return self.reject("content_after_finish");
                }
                if self.facts.first_content.is_none() {
                    self.facts.first_content = Some(at_ns);
                    self.facts.first_chunk_tokens = first_chunk_tokens;
                }
                self.facts.last_content = Some(at_ns);
                match kind {
                    ContentKind::Text => {
                        self.facts.first_visible.get_or_insert(at_ns);
                        self.facts.last_visible = Some(at_ns);
                    }
                    ContentKind::Reasoning => self.facts.has_reasoning = true,
                    ContentKind::Tool => self.facts.has_tool = true,
                }
            }
            StreamEvent::Usage(usage) => {
                if let Some(old) = &self.facts.usage {
                    if old != &usage {
                        return self.reject("conflicting_usage");
                    }
                } else {
                    if usage
                        .reasoning_tokens
                        .is_some_and(|r| r > usage.output_tokens)
                    {
                        return self.reject("invalid_reasoning_count");
                    }
                    self.facts.usage = Some(usage);
                    self.facts.usage_at = Some(at_ns);
                }
            }
            StreamEvent::Finish(reason) => {
                if let Some(old) = &self.facts.finish {
                    if old != &reason {
                        return self.reject("conflicting_finish");
                    }
                } else {
                    self.facts.finish = Some(reason);
                }
            }
            StreamEvent::Done => {
                self.facts.done = Some(at_ns);
                if !self.facts.responses {
                    self.facts.protocol_terminal = Some("chat_done".into());
                }
            }
        }
        Ok(())
    }

    pub fn http_end(&mut self, at_ns: u64) -> Result<(), StreamError> {
        self.advance(at_ns)?;
        if self.facts.http_end.is_some() {
            return self.reject("duplicate_http_eof");
        }
        self.facts.http_end = Some(at_ns);
        Ok(())
    }

    pub fn fail(&mut self, code: &str) {
        // Stable internal codes only; arbitrary error bodies cannot enter a snapshot.
        let code = if !code.is_empty()
            && code.len() <= 64
            && code
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        {
            code
        } else {
            "collector_failed"
        };
        if !self.facts.reasons.iter().any(|r| r == code) {
            self.facts.reasons.push(code.to_owned());
        }
    }

    pub fn snapshot(&self) -> Value {
        metrics::snapshot(&self.facts)
    }
}
