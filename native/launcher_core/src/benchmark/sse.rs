use super::types::{SseMessage, StreamError};

const EVENT_LIMIT: usize = 1024 * 1024;
const INPUT_LIMIT: usize = 8 * 1024 * 1024;

/// Byte-oriented SSE framing. UTF8 is decoded only after a complete line.
pub struct SseDecoder {
    line: Vec<u8>,
    data: String,
    event: Option<String>,
    has_data: bool,
    first_line: bool,
    after_cr: bool,
    event_bytes: usize,
    total_bytes: usize,
    closed: bool,
    error: Option<&'static str>,
}
impl SseDecoder {
    pub fn new() -> Self {
        Self {
            line: vec![],
            data: String::new(),
            event: None,
            has_data: false,
            first_line: true,
            after_cr: false,
            event_bytes: 0,
            total_bytes: 0,
            closed: false,
            error: None,
        }
    }
    fn fail<T>(&mut self, code: &'static str) -> Result<T, StreamError> {
        self.line.clear();
        self.data.clear();
        self.event = None;
        self.error = Some(code);
        Err(StreamError::new(code))
    }
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SseMessage>, StreamError> {
        if let Some(code) = self.error {
            return Err(StreamError::new(code));
        }
        if self.closed {
            return Err(StreamError::new("sse_after_eof"));
        }
        if bytes.len() > INPUT_LIMIT - self.total_bytes {
            return self.fail("sse_input_too_large");
        }
        self.total_bytes += bytes.len();
        let mut messages = vec![];
        for &byte in bytes {
            if self.after_cr {
                self.after_cr = false;
                if byte == b'\n' {
                    continue;
                }
            }
            self.event_bytes += 1;
            if self.event_bytes > EVENT_LIMIT {
                return self.fail("sse_event_too_large");
            }
            if byte == b'\r' || byte == b'\n' {
                self.after_cr = byte == b'\r';
                if let Err(error) = self.end_line(&mut messages) {
                    return self.fail(error);
                }
            } else {
                self.line.push(byte);
            }
        }
        Ok(messages)
    }
    fn end_line(&mut self, messages: &mut Vec<SseMessage>) -> Result<(), &'static str> {
        let bytes = std::mem::take(&mut self.line);
        let mut line = std::str::from_utf8(&bytes).map_err(|_| "invalid_utf8")?;
        if self.first_line {
            line = line.strip_prefix('\u{feff}').unwrap_or(line);
            self.first_line = false;
        }
        if line.is_empty() {
            if self.has_data {
                self.data.pop(); // SSE joins data fields with LF, excluding final LF.
                messages.push(SseMessage {
                    event: self.event.take().filter(|v| !v.is_empty()),
                    data: std::mem::take(&mut self.data),
                });
            }
            self.data.clear();
            self.event = None;
            self.has_data = false;
            self.event_bytes = 0;
        } else if !line.starts_with(':') {
            let (field, value) = line.split_once(':').unwrap_or((line, ""));
            let value = value.strip_prefix(' ').unwrap_or(value);
            match field {
                "data" => {
                    self.has_data = true;
                    self.data.push_str(value);
                    self.data.push('\n');
                }
                "event" => self.event = Some(value.into()),
                _ => {}
            }
        }
        Ok(())
    }
    pub fn finish(&mut self) -> Result<(), StreamError> {
        if let Some(code) = self.error {
            return Err(StreamError::new(code));
        }
        if !self.line.is_empty() {
            if std::str::from_utf8(&self.line).is_err() {
                return self.fail("invalid_utf8");
            }
            return self.fail("incomplete_sse");
        }
        if self.has_data {
            return self.fail("incomplete_sse");
        }
        self.closed = true;
        self.event = None;
        Ok(())
    }
}
