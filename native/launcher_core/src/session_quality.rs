//! Evidence validation adapted from Win-CodexBar MIT, commit
//! 0eae1ea5c65c35bf184f116b41c131550b22d2cb, turn_performance.rs and
//! identified_requests.rs. Output includes reasoning; cached input is a subset.
//! ccusage f9c9154f9e8cdce4bedd5119dc7a41ec490f96b8 parser.rs documents why
//! compaction accounting / legacy token_count cannot supply this request ledger.
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const LIMIT: usize = 10_000;
pub(super) fn text(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .map(str::to_owned)
}
#[derive(Clone, PartialEq, Eq)]
struct Usage {
    input: Option<u64>,
    cached: Option<u64>,
    output: u64,
    reasoning: Option<u64>,
}
impl Usage {
    fn parse(v: &Value) -> Option<Self> {
        let output = v["output_tokens"].as_u64()?;
        let optional = |key: &str| -> Option<Option<u64>> {
            match v.get(key) {
                None => Some(None),
                Some(n) => n.as_u64().map(Some),
            }
        };
        let input = optional("input_tokens")?;
        let cached = optional("cached_input_tokens")?;
        let reasoning = optional("reasoning_output_tokens")?;
        if reasoning.is_some_and(|n| n > output)
            || cached.zip(input).is_some_and(|(c, i)| c > i)
            || cached.is_some() && input.is_none()
            || input.is_some_and(|n| n.checked_add(output).is_none())
        {
            return None;
        }
        Some(Self {
            input,
            cached,
            output,
            reasoning,
        })
    }
    fn at_least(&self, other: &Self) -> bool {
        self.output >= other.output
            && [
                self.input.zip(other.input),
                self.cached.zip(other.cached),
                self.reasoning.zip(other.reasoning),
            ]
            .into_iter()
            .flatten()
            .all(|(a, b)| a >= b)
    }
}
#[derive(Clone, PartialEq)]
struct Response {
    usage: Option<Usage>,
    snapshot: Option<Usage>,
    payload: Value,
    timestamp: Option<u64>,
}
#[derive(Default)]
pub(super) struct Evidence {
    responses: BTreeMap<String, Response>,
    terminal: Option<Value>,
    context: Option<Value>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub tier: Option<String>,
    pub output: Option<u64>,
    pub reasoning: Option<u64>,
    pub recognized: bool,
    pub conflicts: BTreeSet<String>,
    invalid: bool,
    missing_request: bool,
    missing_identity: bool,
    unsupported: bool,
    truncated: bool,
    snapshot_without_id: Option<Usage>,
}
impl Evidence {
    pub fn conflict(&mut self, reason: &str) {
        self.conflicts.insert(reason.into());
    }
    fn observe_model(&mut self, model: Option<String>) {
        if let Some(model) = model {
            if self.model.as_ref().is_some_and(|known| known != &model) {
                self.conflict("conflicting_model");
            } else {
                self.model = Some(model);
            }
        }
    }
    pub fn accept(&mut self, kind: &str, p: &Value, record: &Value, session: Option<&str>) {
        match kind {
            "task_complete" | "turn_aborted" => {
                let terminal = json!({"kind":kind,"duration":p["duration_ms"],"first":p["time_to_first_token_ms"],"start":p["started_at"],"end":p["completed_at"],"error":p["error"]});
                if let Some(first) = &self.terminal {
                    if first != &terminal {
                        self.conflict("conflicting_terminal");
                    }
                } else {
                    self.terminal = Some(terminal);
                }
            }
            "turn_context" => {
                let context =
                    json!({"model":p["model"],"effort":p["effort"],"tier":p["service_tier"]});
                if self.context.as_ref().is_some_and(|first| first != &context) {
                    self.conflict("conflicting_metadata");
                } else {
                    self.observe_model(text(&p["model"]));
                    self.effort = text(&p["effort"]);
                    self.tier = text(&p["service_tier"]);
                    self.context = Some(context);
                }
            }
            "token_count" | "compacted" => self.unsupported = true,
            "token_usage_record" => {
                self.recognized = true;
                self.observe_model(text(&p["model"]));
                let usage = Usage::parse(&p["usage"]);
                let snapshot = Usage::parse(&p["turn_token_usage"]);
                let thread = Usage::parse(&p["thread_token_usage"]);
                if p.get("usage").is_some() && usage.is_none()
                    || p.get("turn_token_usage").is_some() && snapshot.is_none()
                    || p.get("thread_token_usage").is_some() && thread.is_none()
                {
                    self.invalid = true;
                }
                if usage.is_none() || thread.is_none() {
                    self.missing_request = true;
                }
                if usage
                    .as_ref()
                    .zip(snapshot.as_ref())
                    .is_some_and(|(u, s)| !s.at_least(u))
                    || usage
                        .as_ref()
                        .zip(thread.as_ref())
                        .is_some_and(|(u, s)| !s.at_least(u))
                {
                    self.invalid = true;
                }
                let owned = session.is_some_and(|s| text(&p["thread_id"]).as_deref() == Some(s));
                if !owned {
                    self.missing_identity = true;
                }
                if session
                    .zip(text(&p["thread_id"]).as_deref())
                    .is_some_and(|(a, b)| a != b)
                    || p.get("session_id")
                        .is_some_and(|id| text(id).as_deref() != session)
                {
                    self.conflict("conflicting_identity");
                }
                let Some(id) = text(&p["response_id"]) else {
                    self.missing_request = true;
                    if let Some(s) = snapshot {
                        if self
                            .snapshot_without_id
                            .as_ref()
                            .is_some_and(|old| old != &s)
                        {
                            self.conflict("conflicting_usage");
                        }
                        self.output = Some(s.output);
                        self.reasoning = s.reasoning;
                        self.snapshot_without_id = Some(s);
                    }
                    return;
                };
                let response = Response {
                    usage,
                    snapshot,
                    payload: p.clone(),
                    timestamp: timestamp(&record["timestamp"]),
                };
                if let Some(old) = self.responses.get(&id) {
                    if old != &response {
                        self.conflict("conflicting_usage");
                    }
                    return;
                }
                if self.responses.len() >= LIMIT {
                    self.truncated = true;
                    return;
                }
                if let Some(s) = &response.snapshot {
                    self.output = Some(s.output);
                    self.reasoning = s.reasoning;
                }
                self.responses.insert(id, response);
                // A snapshot matching the complete deduplicated ledger proves its
                // scope. An older response replay never changes this selection.
                if let Some(sum) = self.sum_output() {
                    if let Some(s) = self
                        .responses
                        .values()
                        .filter_map(|r| r.snapshot.as_ref())
                        .find(|s| s.output == sum)
                    {
                        self.output = Some(s.output);
                        self.reasoning = s.reasoning;
                    }
                }
            }
            _ => {}
        }
    }
    fn sum_output(&self) -> Option<u64> {
        self.responses
            .values()
            .try_fold(0u64, |n, r| n.checked_add(r.usage.as_ref()?.output))
    }
    pub fn quality(
        &self,
        duration: Option<u64>,
        bounds_valid: bool,
        session: Option<&str>,
        history: bool,
    ) -> Value {
        let mut reasons = self.conflicts.clone();
        let mut incomplete = false;
        let mut reported = false;
        if self.unsupported {
            reasons.insert("unsupported_token_schema".into());
        }
        match self.output {
            None => {
                reasons.insert("missing_usage".into());
                incomplete = true;
            }
            Some(_) => {}
        }
        if self.invalid {
            reasons.insert("invalid_usage".into());
            incomplete = true;
        }
        match duration {
            None => {
                reasons.insert(
                    if self
                        .terminal
                        .as_ref()
                        .is_some_and(|p| !p["duration"].is_null())
                    {
                        "invalid_duration"
                    } else {
                        "missing_duration"
                    }
                    .into(),
                );
                incomplete = true;
            }
            Some(0) => {
                reasons.insert("invalid_duration".into());
                incomplete = true;
            }
            _ => {}
        }
        if self.terminal.as_ref().is_some_and(|p| {
            !p["first"].is_null() && p["first"].as_u64().zip(duration).is_none_or(|(f, d)| f > d)
        }) {
            reasons.insert("invalid_bounds".into());
            incomplete = true;
        }
        if self
            .terminal
            .as_ref()
            .is_some_and(|p| !p["error"].is_null())
        {
            reasons.insert("unsuccessful_terminal".into());
            incomplete = true;
        }
        if session.is_none() || self.missing_identity {
            reasons.insert("missing_identity".into());
            reported = true;
        }
        if self.missing_request || self.responses.is_empty() {
            reasons.insert("missing_request_evidence".into());
            reported = true;
        }
        if !bounds_valid {
            reasons.insert("invalid_bounds".into());
            incomplete = true;
        }
        if self.truncated || history {
            reasons.insert("incomplete_history".into());
            incomplete = true;
        }
        if !self.responses.is_empty() {
            if let Some(reported_reasoning) = self.reasoning {
                let sum = self
                    .responses
                    .values()
                    .try_fold(0u64, |n, r| n.checked_add(r.usage.as_ref()?.reasoning?));
                // Missing detail remains unknown. When all detail is present,
                // contradictory request/snapshot reasoning cannot be verified.
                if sum.is_some_and(|sum| sum != reported_reasoning) {
                    reasons.insert("usage_mismatch".into());
                    incomplete = true;
                }
            }
            match self.sum_output() {
                Some(sum) if Some(sum) == self.output => {
                    // Every linked cumulative snapshot must be attainable by
                    // a prefix of the unique response ledger, ordered by its
                    // reported cumulative output, rather than arrival order.
                    let mut rows: Vec<_> = self.responses.values().collect();
                    rows.sort_by_key(|r| r.snapshot.as_ref().map(|s| s.output));
                    let mut sum = Some(0u64);
                    for r in rows {
                        sum = sum
                            .zip(r.usage.as_ref())
                            .and_then(|(a, u)| a.checked_add(u.output));
                        if sum != r.snapshot.as_ref().map(|s| s.output) {
                            reasons.insert("usage_mismatch".into());
                            incomplete = true;
                        }
                    }
                }
                _ => {
                    reasons.insert("usage_mismatch".into());
                    incomplete = true;
                }
            }
            let bounds = self
                .terminal
                .as_ref()
                .and_then(|p| p["start"].as_u64().zip(p["end"].as_u64()))
                .and_then(|(s, e)| s.checked_mul(1000).zip(e.checked_add(1)?.checked_mul(1000)));
            for r in self.responses.values() {
                if r.usage.as_ref().is_some_and(|u| u.input.is_none()) {
                    reasons.insert("missing_request_evidence".into());
                    reported = true;
                }
                if r.timestamp
                    .zip(bounds)
                    .is_none_or(|(t, (s, e))| t < s || t >= e)
                {
                    reasons.insert("invalid_bounds".into());
                    incomplete = true;
                }
            }
        }
        let status = if !self.conflicts.is_empty() {
            "conflict"
        } else if self.unsupported {
            "unsupported"
        } else if incomplete {
            "incomplete"
        } else if reported {
            "reported_only"
        } else {
            "verified"
        };
        json!({"status":status,"reasons":reasons})
    }
}
pub(super) fn rate(output: Option<u64>, duration: Option<u64>) -> Option<f64> {
    let (n, d) = output.zip(duration).filter(|(_, d)| *d > 0)?;
    let rate = n as f64 / d as f64 * 1000.0;
    rate.is_finite().then_some(rate)
}
// Strict RFC3339 UTC/offset timestamps for request scope, without adding a
// date/time dependency. Invalid calendar dates and arithmetic overflow reject.
fn timestamp(value: &Value) -> Option<u64> {
    let s = value.as_str()?;
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let number = |a: usize, z: usize| -> Option<i64> {
        let digits = s.get(a..z)?;
        if !digits.as_bytes().iter().all(u8::is_ascii_digit) {
            return None;
        }
        digits.parse().ok()
    };
    let (year, month, day) = (number(0, 4)?, number(5, 7)?, number(8, 10)?);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if !(1..=12).contains(&month) || !(1..=days[(month - 1) as usize]).contains(&day) {
        return None;
    }
    let (hour, min, sec) = (number(11, 13)?, number(14, 16)?, number(17, 19)?);
    if !(0..=23).contains(&hour) || !(0..=59).contains(&min) || !(0..=59).contains(&sec) {
        return None;
    }
    let mut pos = 19;
    let mut millis = 0;
    if b.get(pos) == Some(&b'.') {
        pos += 1;
        let start = pos;
        while b.get(pos).is_some_and(u8::is_ascii_digit) {
            pos += 1;
        }
        if start == pos {
            return None;
        }
        for i in 0..3 {
            millis = millis * 10
                + i64::from(if start + i < pos {
                    b[start + i] - b'0'
                } else {
                    0
                });
        }
    }
    let offset = match b.get(pos) {
        Some(b'Z') if pos + 1 == b.len() => 0,
        Some(sign @ (b'+' | b'-')) if pos + 6 == b.len() && b[pos + 3] == b':' => {
            let h = number(pos + 1, pos + 3)?;
            let m = number(pos + 4, pos + 6)?;
            if !(0..=23).contains(&h) || !(0..=59).contains(&m) {
                return None;
            }
            (h * 60 + m) * 60 * if *sign == b'+' { 1 } else { -1 }
        }
        _ => return None,
    };
    let y = year - i64::from(month <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    u64::try_from(
        (days * 86400 + hour * 3600 + min * 60 + sec - offset)
            .checked_mul(1000)?
            .checked_add(millis)?,
    )
    .ok()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn session_timestamp_rejects_signed_numeric_components() {
        for s in [
            "1970-01-01T00:00:+2Z",
            "1970-01-01T00:+0:02Z",
            "1970-01-01T+0:00:02Z",
            "1970-01-01T00:00:02++0:00",
            "1970-01-01T00:00:02+00:+0",
            "1970-01-01T00:-0:02Z",
            "1970-01-01T-0:00:02Z",
            "1970-01-01T00:00:02+-0:00",
            "1970-01-01T00:00:02+00:-0",
        ] {
            assert_eq!(timestamp(&json!(s)), None, "{s}");
        }
        assert_eq!(timestamp(&json!("1970-01-01T00:00:02Z")), Some(2000));
        assert_eq!(timestamp(&json!("1970-01-01T08:00:02+08:00")), Some(2000));
    }
}
