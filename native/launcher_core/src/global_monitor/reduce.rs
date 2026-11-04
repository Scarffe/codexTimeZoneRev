use super::*;

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Tokens {
    pub input_tokens: Option<u64>,
    pub cached_input_tokens: Option<u64>,
    pub cache_write_input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
}
impl Tokens {
    pub fn parse(v: &Value) -> Option<Self> {
        let read = |key: &str| -> Option<Option<u64>> {
            match v.get(key) {
                None | Some(Value::Null) => Some(None),
                Some(n) => n.as_u64().map(Some),
            }
        };
        if !v.is_object() {
            return None;
        }
        let input = read("input_tokens")?;
        let output = read("output_tokens")?;
        let value = Self {
            input_tokens: input,
            cached_input_tokens: read("cached_input_tokens")?,
            cache_write_input_tokens: read("cache_write_input_tokens")?,
            output_tokens: output,
            reasoning_tokens: read("reasoning_output_tokens")?,
            total_tokens: read("total_tokens")?
                .or_else(|| input.zip(output).and_then(|(i, o)| i.checked_add(o))),
        };
        if input.is_none()
            || output.is_none()
            || value
                .cached_input_tokens
                .zip(input)
                .is_some_and(|(c, i)| c > i)
            || value
                .reasoning_tokens
                .zip(output)
                .is_some_and(|(r, o)| r > o)
            || input
                .zip(output)
                .zip(value.total_tokens)
                .is_some_and(|((i, o), t)| i.checked_add(o) != Some(t))
        {
            None
        } else {
            Some(value)
        }
    }
    pub fn add(&mut self, other: &Self, first: bool) {
        if first {
            *self = other.clone();
            return;
        }
        let add = |a: Option<u64>, b: Option<u64>| a.zip(b).and_then(|(a, b)| a.checked_add(b));
        self.input_tokens = add(self.input_tokens, other.input_tokens);
        self.cached_input_tokens = add(self.cached_input_tokens, other.cached_input_tokens);
        self.cache_write_input_tokens = add(
            self.cache_write_input_tokens,
            other.cache_write_input_tokens,
        );
        self.output_tokens = add(self.output_tokens, other.output_tokens);
        self.reasoning_tokens = add(self.reasoning_tokens, other.reasoning_tokens);
        self.total_tokens = add(self.total_tokens, other.total_tokens);
    }
    fn delta(&self, previous: &Self) -> Option<Self> {
        let sub = |a: Option<u64>, b: Option<u64>| -> Option<Option<u64>> {
            match (a, b) {
                (Some(a), Some(b)) => a.checked_sub(b).map(Some),
                _ => Some(None),
            }
        };
        Some(Self {
            input_tokens: sub(self.input_tokens, previous.input_tokens)?,
            cached_input_tokens: sub(self.cached_input_tokens, previous.cached_input_tokens)?,
            cache_write_input_tokens: sub(
                self.cache_write_input_tokens,
                previous.cache_write_input_tokens,
            )?,
            output_tokens: sub(self.output_tokens, previous.output_tokens)?,
            reasoning_tokens: sub(self.reasoning_tokens, previous.reasoning_tokens)?,
            total_tokens: sub(self.total_tokens, previous.total_tokens)?,
        })
    }
    fn is_zero(&self) -> bool {
        self.input_tokens == Some(0) && self.output_tokens == Some(0)
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct Context {
    pub model: Option<String>,
    pub project: Option<String>,
    pub order: u64,
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct Turn {
    pub state: String,
    pub order: u64,
    pub started_at: Option<u64>,
    pub completed_at: Option<u64>,
    pub duration: Option<u64>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct LegacyCheckpoint {
    pub segment: u64,
    pub total: Tokens,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Fact {
    pub turn_id: String,
    pub time: Option<u64>,
    pub tokens: Tokens,
    pub checkpoint: Option<LegacyCheckpoint>,
}

// Ephemeral recent lifecycle evidence while the usage ledger catches up.
#[derive(Clone)]
pub(super) struct TailState {
    pub length: u64,
    pub last_event_ms: Option<u64>,
    pub latest_turn: Option<Turn>,
}

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Source {
    pub path: PathBuf,
    pub thread_id: String,
    pub session_id: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub metadata_title: Option<String>,
    #[serde(default)]
    pub metadata_title_read: bool,
    pub parent_thread_id: Option<String>,
    pub project: Option<String>,
    pub child: bool,
    pub detail: bool,
    pub offset: u64,
    pub length: u64,
    pub identity: Option<catalog::Identity>,
    pub source_state: String,
    pub restored: bool,
    pub serial: u64,
    pub last_event_ms: Option<u64>,
    pub contexts: BTreeMap<String, Context>,
    pub turns: BTreeMap<String, Turn>,
    pub responses: BTreeMap<String, Fact>,
    pub legacy: Vec<Fact>,
    pub previous: Option<Tokens>,
    pub baseline_only: bool,
    pub current_turn: Option<String>,
    pub legacy_segment: u64,
    pub reasons: BTreeSet<String>,
    pub conflicting_responses: BTreeSet<String>,
    // Ephemeral scheduling evidence only; never lifecycle or durable usage data.
    #[serde(skip)]
    pub priority_modified: Option<SystemTime>,
    #[serde(skip)]
    pub tail: Option<TailState>,
}
impl Source {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            thread_id: String::new(),
            session_id: None,
            title: None,
            metadata_title: None,
            metadata_title_read: false,
            parent_thread_id: None,
            project: None,
            child: false,
            detail: false,
            offset: 0,
            length: 0,
            identity: None,
            source_state: "pending".into(),
            restored: false,
            serial: 0,
            last_event_ms: None,
            contexts: BTreeMap::new(),
            turns: BTreeMap::new(),
            responses: BTreeMap::new(),
            legacy: Vec::new(),
            previous: None,
            baseline_only: false,
            current_turn: None,
            legacy_segment: 0,
            reasons: BTreeSet::new(),
            conflicting_responses: BTreeSet::new(),
            priority_modified: None,
            tail: None,
        }
    }
    pub fn valid_cache(&self) -> bool {
        self.thread_id.len() <= 32768
            && self.session_id.as_ref().is_none_or(|v| v.len() <= 32768)
            && self.title.as_ref().is_none_or(|v| v.len() <= 32768)
            && self
                .metadata_title
                .as_ref()
                .is_none_or(|v| v.len() <= 32768)
            && self.offset <= self.length
            && self.contexts.len() <= 2_000_000
            && self.responses.len() <= 2_000_000
            && self.legacy.len() <= 2_000_000
            && self.legacy.iter().all(|f| f.checkpoint.is_some())
    }
    pub fn accept(&mut self, row: &Value) {
        let kind = row["type"].as_str().unwrap_or("");
        let p = &row["payload"];
        if kind == "session_meta" {
            if self.offset > MAX_LINE && !self.thread_id.is_empty() {
                return;
            }
            if let Some(id) = text(&p["id"]) {
                if !self.thread_id.is_empty() && self.thread_id != id {
                    self.reasons.insert("conflicting_thread_identity".into());
                    return;
                }
                self.thread_id = id;
                self.session_id = text(&p["session_id"]);
                self.metadata_title = crate::session_names::title(&p["title"]);
                self.metadata_title_read = true;
                self.project = text(&p["cwd"]).map(project_key);
                self.reasons.remove("missing_session_meta");
                self.child = p["source"].is_object();
                self.parent_thread_id = text(&p["parent_thread_id"])
                    .or_else(|| text(&p["forked_from_id"]))
                    .or_else(|| text(&p["forked_from_thread_id"]))
                    .or_else(|| text(&p["forked_from"]["thread_id"]))
                    .or_else(|| text(&p["source"]["subagent"]["thread_spawn"]["parent_thread_id"]));
                self.baseline_only = self.child || self.parent_thread_id.is_some();
                self.detail = !self.child && catalog::strict_detail_supported(&self.path);
            }
            return;
        }
        if self.thread_id.is_empty() {
            return;
        }
        let kind = if kind == "event_msg" {
            p["type"].as_str().unwrap_or("")
        } else {
            kind
        };
        if !matches!(
            kind,
            "turn_context"
                | "task_started"
                | "task_complete"
                | "task_completed"
                | "turn_aborted"
                | "token_usage_record"
                | "token_count"
                | "compacted"
        ) {
            return;
        }
        // An inherited parent's request is not evidence of this child's activity.
        if kind == "token_usage_record" && p["thread_id"].as_str() != Some(self.thread_id.as_str())
        {
            return;
        }
        // No legacy wire field proves the point at which a fork's inherited
        // counters become owned usage. Explicit request owners remain usable.
        if kind == "token_count" && (self.child || self.parent_thread_id.is_some()) {
            self.reasons.insert("ambiguous_legacy_fork".into());
            return;
        }
        let time = timestamp(&row["timestamp"]).or_else(|| match kind {
            "task_started" => epoch_seconds(&p["started_at"]),
            "task_complete" | "task_completed" | "turn_aborted" => {
                epoch_seconds(&p["completed_at"])
            }
            _ => None,
        });
        if let Some(time) = time {
            self.last_event_ms = Some(self.last_event_ms.unwrap_or(0).max(time));
        }
        self.serial = self.serial.saturating_add(1);
        let turn = text(&p["turn_id"]);
        match kind {
            "turn_context" => {
                if let Some(turn) = turn {
                    self.current_turn = Some(turn.clone());
                    let context = Context {
                        model: text(&p["model"]),
                        project: text(&p["cwd"]).map(project_key),
                        order: self.serial,
                    };
                    if let Some(old) = self.contexts.get(&turn) {
                        if old.model != context.model || old.project != context.project {
                            self.reasons.insert("conflicting_turn_context".into());
                        }
                    } else {
                        self.contexts.insert(turn, context);
                    }
                }
            }
            "task_started" | "task_complete" | "task_completed" | "turn_aborted" => {
                let Some(turn) = turn else {
                    self.reasons.insert("missing_turn_identity".into());
                    return;
                };
                let t = self.turns.entry(turn.clone()).or_default();
                if !matches!(t.state.as_str(), "completed" | "cancelled" | "failed") {
                    if t.order == 0 {
                        t.order = self.serial;
                    }
                    if kind == "task_started" {
                        t.state = "running".into();
                        t.started_at = t
                            .started_at
                            .or_else(|| epoch_seconds(&p["started_at"]))
                            .or(time);
                        self.current_turn = Some(turn);
                    } else {
                        t.state = if kind == "turn_aborted" {
                            "cancelled"
                        } else if error_present(&p["error"]) {
                            "failed"
                        } else {
                            "completed"
                        }
                        .into();
                        t.started_at = epoch_seconds(&p["started_at"]).or(t.started_at);
                        t.completed_at = epoch_seconds(&p["completed_at"]).or(time);
                        t.duration = p["duration_ms"].as_u64();
                    }
                }
            }
            "token_usage_record" => {
                if p["thread_id"].as_str() != Some(self.thread_id.as_str()) {
                    return;
                }
                let (Some(turn), Some(response)) = (turn, text(&p["response_id"])) else {
                    self.reasons.insert("missing_usage_identity".into());
                    return;
                };
                let Some(tokens) = Tokens::parse(&p["usage"]) else {
                    self.reasons.insert("invalid_usage".into());
                    return;
                };
                let fact = Fact {
                    turn_id: turn,
                    time,
                    tokens,
                    checkpoint: None,
                };
                if let Some(old) = self.responses.get_mut(&response) {
                    if old.turn_id != fact.turn_id || old.tokens != fact.tokens {
                        self.conflicting_responses.insert(response);
                        self.reasons.insert("conflicting_usage".into());
                    } else {
                        old.time = earliest(old.time, fact.time);
                    }
                } else {
                    self.responses.insert(response, fact);
                }
            }
            "token_count" => {
                let Some(total) = Tokens::parse(&p["info"]["total_token_usage"]) else {
                    if p["info"]["last_token_usage"].is_object() {
                        self.reasons
                            .insert("last_usage_without_cumulative_identity".into());
                    }
                    return;
                };
                let delta = if let Some(previous) = &self.previous {
                    match total.delta(previous) {
                        Some(delta) => Some(delta),
                        None => {
                            self.legacy_segment = self.legacy_segment.saturating_add(1);
                            self.reasons.insert("counter_reset_baseline".into());
                            None
                        }
                    }
                } else if self.baseline_only {
                    self.reasons.insert("inherited_counter_baseline".into());
                    None
                } else {
                    Some(total.clone())
                };
                let checkpoint = LegacyCheckpoint {
                    segment: self.legacy_segment,
                    total: total.clone(),
                };
                self.previous = Some(total);
                self.baseline_only = false;
                if let Some(tokens) = delta.filter(|t| !t.is_zero()) {
                    self.legacy.push(Fact {
                        turn_id: turn
                            .or_else(|| self.current_turn.clone())
                            .unwrap_or_default(),
                        time,
                        tokens,
                        checkpoint: Some(checkpoint),
                    });
                }
            }
            "compacted" => {
                self.previous = None;
                self.baseline_only = true;
                self.legacy_segment = self.legacy_segment.saturating_add(1);
                self.reasons.insert("compaction_baseline".into());
            }
            _ => {}
        }
    }
}
fn error_present(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Object(m) => !m.is_empty(),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}
fn epoch_seconds(v: &Value) -> Option<u64> {
    v.as_u64()?.checked_mul(1000)
}
pub(super) fn earliest(a: Option<u64>, b: Option<u64>) -> Option<u64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}
fn project_key(mut value: String) -> String {
    if value.starts_with(r"\\?\UNC\") {
        value = format!(r"\\{}", &value[8..]);
    } else if value.starts_with(r"\\?\") {
        value = value[4..].to_owned();
    }
    if value.as_bytes().get(1) == Some(&b':') || value.starts_with(r"\\") {
        value
            .replace('/', r"\")
            .trim_end_matches('\\')
            .to_lowercase()
    } else {
        value
    }
}

// Same strict civil-date arithmetic as the existing single-session parser.
pub(super) fn timestamp(value: &Value) -> Option<u64> {
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
