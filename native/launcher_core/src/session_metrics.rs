#[path = "session_metrics/session_history.rs"]
mod session_history;
#[path = "session_identity.rs"]
mod session_identity;
#[path = "session_quality.rs"]
mod session_quality;
#[path = "session_timing.rs"]
mod session_timing;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
};

// This collector only opens session files for reading. No runtime RPC or prompt content leaves it.
const MAX_LINE: u64 = 8 * 1024 * 1024;
// Eight watched sessions, one selected analysis and eight explicit rhythm sources.
const READER_CAPACITY: usize = 8 + 1 + 8;
#[derive(Default)]
struct Turn {
    history_order: u64,
    lifecycle: session_history::Lifecycle,
    evidence: session_quality::Evidence,
    timing: session_timing::Timing,
    state: String,
    output: Option<u64>,
    reasoning: Option<u64>,
    duration: Option<u64>,
    first: Option<u64>,
    complete: bool,
    ended: bool,
    order: u64,
    started_order: u64,
}
#[derive(Default)]
struct Reader {
    path: PathBuf,
    epoch: u64,
    offset: u64,
    turns: BTreeMap<String, Turn>,
    serial: u64,
    stamp: Option<std::time::SystemTime>,
    identity: Option<session_identity::Identity>,
    source_info: Option<Value>,
    catching_up: bool,
    incomplete: bool,
    missing_identity: bool,
    unsupported: bool,
    response_owners: BTreeMap<String, String>,
}
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
#[derive(Default)]
struct ReaderPool {
    // Least recently used first; bounded independently of Dart isolate lifetimes.
    readers: Vec<Reader>,
}
impl ReaderPool {
    fn history(&mut self, path: PathBuf, request: &Value) -> Result<Value, String> {
        let request = session_history::Request::parse(request)?;
        let metrics = self.poll(path)?;
        // poll retains this exact Reader at the end of the LRU, including its
        // file identity, bounded catch-up state and all previously read turns.
        let reader = self.readers.last().ok_or("会话采集状态不可用")?;
        Ok(session_history::project(
            reader,
            &request,
            metrics["catchingUp"] == true,
        ))
    }
    fn poll(&mut self, path: PathBuf) -> Result<Value, String> {
        let mut reader = self
            .readers
            .iter()
            .position(|r| r.path == path)
            .map(|index| self.readers.remove(index))
            .unwrap_or_default();
        let result = reader.poll(path);
        self.readers.push(reader);
        if self.readers.len() > READER_CAPACITY {
            self.readers.remove(0);
        }
        result
    }
}
static READERS: Mutex<ReaderPool> = Mutex::new(ReaderPool {
    readers: Vec::new(),
});
fn root() -> Result<PathBuf, String> {
    let home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE")
                .or_else(|| std::env::var_os("HOME"))
                .map(|p| PathBuf::from(p).join(".codex"))
        })
        .ok_or("无法定位 Codex 目录")?;
    home.join("sessions")
        .canonicalize()
        .map_err(|_| "本机尚无可读取的会话目录".into())
}
fn walk(path: &Path, depth: usize, files: &mut Vec<PathBuf>) {
    if depth > 4 {
        return;
    }
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            // Never follow links outside the configured sessions root.
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                walk(&entry.path(), depth + 1, files);
            } else if kind.is_file()
                && entry.file_name().to_string_lossy().starts_with("rollout-")
                && entry.path().extension().is_some_and(|e| e == "jsonl")
            {
                files.push(entry.path());
            }
        }
    }
}
fn line(reader: &mut impl BufRead) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    let n = reader
        .take(MAX_LINE + 1)
        .read_until(b'\n', &mut bytes)
        .map_err(|_| "会话读取失败")?;
    if n as u64 > MAX_LINE {
        return Err("会话单条记录过大，已停止采集".into());
    }
    Ok(bytes)
}
fn metadata(path: &Path) -> Option<Value> {
    metadata_file(File::open(path).ok()?, path)
}
fn metadata_file(mut file: File, path: &Path) -> Option<Value> {
    file.seek(SeekFrom::Start(0)).ok()?;
    let modified = file
        .metadata()
        .ok()?
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .and_then(|d| u64::try_from(d.as_millis()).ok());
    let mut reader = BufReader::new(file);
    let value: Value = serde_json::from_slice(&line(&mut reader).ok()?).ok()?;
    if value["type"] != "session_meta" || value["payload"]["source"].is_object() {
        return None;
    }
    let p = &value["payload"];
    Some(
        json!({"id":p["id"],"cwd":p["cwd"],"timestamp":p["timestamp"],"source":p["source"],"title":p["title"],"modifiedMs":modified,"path":path}),
    )
}
impl Reader {
    fn poll(&mut self, path: PathBuf) -> Result<Value, String> {
        let mut file = File::open(&path).map_err(|_| "所选会话已移除或不可读取")?;
        let meta = file.metadata().map_err(|_| "会话属性读取失败")?;
        let modified = meta.modified().ok();
        if self.path != path
            || self
                .identity
                .as_ref()
                .is_some_and(|i| !i.matches(&mut file).unwrap_or(false))
            || meta.len() < self.offset
            || (meta.len() == self.offset && self.stamp != modified)
        {
            *self = Reader {
                path,
                epoch: NEXT_EPOCH.fetch_add(1, Ordering::Relaxed),
                ..Default::default()
            };
        }
        // Metadata and records come from this same open handle, including when
        // the directory entry is atomically replaced during the poll.
        self.source_info = metadata_file(
            file.try_clone().map_err(|_| "会话属性读取失败")?,
            &self.path,
        );
        let session = self
            .source_info
            .as_ref()
            .and_then(|m| session_quality::text(&m["id"]));
        let mut reader = BufReader::new(file);
        reader
            .seek(SeekFrom::Start(self.offset))
            .map_err(|_| "会话定位失败")?;
        // Bound each UI poll; large initial histories catch up across polls without blocking the UI.
        let mut read = 0;
        while read < 16 * 1024 * 1024 {
            let bytes = line(&mut reader)?;
            if bytes.is_empty() || bytes.last() != Some(&b'\n') {
                break;
            } // retry partial append next time
            self.offset += bytes.len() as u64;
            read += bytes.len();
            let Ok(v) = serde_json::from_slice::<Value>(&bytes) else {
                self.serial += 1;
                self.incomplete = true;
                continue;
            };
            if ![
                "event_msg",
                "token_usage_record",
                "turn_context",
                "compacted",
            ]
            .iter()
            .any(|k| v["type"] == *k)
            {
                continue;
            }
            let p = &v["payload"];
            let kind = if v["type"] != "event_msg" {
                v["type"].as_str().unwrap_or("")
            } else {
                p["type"].as_str().unwrap_or("")
            };
            if ![
                "task_started",
                "task_complete",
                "turn_aborted",
                "token_usage_record",
                "item_completed",
                "turn_context",
                "token_count",
                "compacted",
            ]
            .contains(&kind)
            {
                continue;
            }
            let legacy = matches!(kind, "token_count" | "compacted");
            // Quality-changing rows need a revision even if no turn owns them.
            self.serial += 1;
            self.unsupported |= legacy;
            let Some(id) = p["turn_id"].as_str().filter(|s| !s.trim().is_empty()) else {
                // Identity evidence cannot disappear before ownership checking.
                // A known response still identifies its contradicted owner;
                // unresolved relevant rows conservatively taint this epoch.
                let owner = if kind == "token_usage_record" {
                    session_quality::text(&p["response_id"])
                        .and_then(|r| self.response_owners.get(&r))
                        .cloned()
                } else {
                    None
                };
                if let Some(owner) = owner {
                    if let Some(t) = self.turns.get_mut(&owner) {
                        t.evidence.conflict("conflicting_identity");
                        t.evidence.accept(kind, p, &v, session.as_deref());
                    }
                } else if legacy {
                    for t in self.turns.values_mut() {
                        t.evidence.accept(kind, p, &v, session.as_deref());
                    }
                } else {
                    self.incomplete = true;
                    self.missing_identity = true;
                }
                continue;
            };
            let response_owner = if kind == "token_usage_record" {
                session_quality::text(&p["response_id"])
                    .and_then(|r| self.response_owners.insert(r, id.to_owned()))
            } else {
                None
            };
            if let Some(other) = response_owner.as_ref().filter(|other| other.as_str() != id) {
                if let Some(t) = self.turns.get_mut(other) {
                    t.evidence.conflict("conflicting_usage");
                }
            }
            let t = self.turns.entry(id.to_owned()).or_default();
            if t.history_order == 0 {
                t.history_order = self.serial;
            }
            t.lifecycle.accept(kind, p, &v);
            if response_owner.is_some_and(|other| other != id) {
                t.evidence.conflict("conflicting_usage");
            }
            t.evidence.accept(kind, p, &v, session.as_deref());
            t.timing.accept(kind, p, self.serial);
            if t.timing.conflicting_item {
                t.evidence.conflict("conflicting_item");
            }
            // Replayed lifecycle records must not resurrect a terminal turn or
            // reorder an old turn ahead of newer activity. First terminal wins.
            if kind == "task_started" && !t.ended {
                if t.order == 0 {
                    t.order = self.serial;
                    t.started_order = self.serial;
                }
                t.state = "running".into();
            }
            if kind == "task_complete" && !t.ended {
                if t.started_order == 0 {
                    t.started_order = self.serial;
                }
                t.complete = true;
                t.ended = true;
                t.state = "completed".into();
                t.duration = p["duration_ms"].as_u64();
                t.first = p["time_to_first_token_ms"].as_u64();
                t.order = self.serial;
            }
            if kind == "turn_aborted" && !t.ended {
                if t.started_order == 0 {
                    t.started_order = self.serial;
                }
                t.ended = true;
                t.state = "cancelled".into();
                t.order = self.serial;
            }
            if kind == "token_usage_record" {
                t.output = t.evidence.output;
                t.reasoning = t.evidence.reasoning;
            }
        }
        self.identity = Some(
            session_identity::Identity::capture(reader.get_mut(), self.offset)
                .map_err(|_| "会话连续性检查失败")?,
        );
        self.stamp = modified;
        let latest = self
            .turns
            .iter()
            .filter(|(_, t)| t.complete)
            .max_by_key(|(_, t)| t.order);
        let latest_state = self
            .turns
            .iter()
            .filter(|(_, t)| t.started_order > 0)
            .max_by_key(|(_, t)| t.started_order);
        let active = latest_state.is_some_and(|(_, t)| t.state == "running");
        let current = latest_state.map(|(id, t)| json!({"turnId":id,"status":t.state}));
        let mut ended: Vec<_> = self.turns.iter().filter(|(_, t)| t.ended).collect();
        ended.sort_by_key(|(_, t)| t.order);
        let terminals: Vec<_> = ended
            .iter()
            .rev()
            .take(64)
            .map(|(id, t)| json!({"turnId":id,"status":t.state,"durationMs":t.duration}))
            .collect();
        let catching_up = self.offset < meta.len();
        // Partial bytes are not consumed, and their eventual completion can be
        // an ignored record. Both completeness transitions still change every
        // history fact's quality, so they must invalidate paginated snapshots.
        if self.catching_up != catching_up {
            self.serial += 1;
            self.catching_up = catching_up;
        }
        let quality_of = |t: &Turn| {
            let mut quality = t.evidence.quality(
                t.duration,
                t.timing.bounds_valid(t.duration),
                session.as_deref(),
                self.incomplete || catching_up,
            );
            if self.missing_identity {
                quality["reasons"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!("missing_identity"));
            }
            quality
        };
        let last = latest.map(|(id, t)| {
            let quality = quality_of(t);
            // Build the full analysis only for the selected completed turn.
            // Reader-wide evidence cannot be recovered from Timing alone.
            let mut analysis = t.timing.report(t.duration, t.output);
            if self.incomplete || catching_up || self.missing_identity || quality["status"] == "conflict" {
                analysis["timeline"]["sourcePartial"] = json!(true);
                analysis["timeline"]["coverageInterpretation"] = json!("unavailable");
            }
            json!({"turnId":id,"outputTokens":t.output,"reasoningTokens":t.reasoning,"durationMs":t.duration,"firstTokenMs":t.first,"analysis":analysis,"tokensPerSecond":session_quality::rate(t.output,t.duration),"verifiedTokensPerSecond":if quality["status"]=="verified" {session_quality::rate(t.output,t.duration)} else {None},"quality":quality})
        });
        let quality = latest
            .map(|(_, t)| quality_of(t))
            .unwrap_or_else(|| {
                let mut reasons=vec!["no_completed_turn"];
                if self.unsupported {reasons.push("unsupported_token_schema");}
                if self.incomplete || catching_up {reasons.push("incomplete_history");}
                if self.missing_identity {reasons.push("missing_identity");}
                json!({"status":if self.unsupported {"unsupported"}else{"incomplete"},"reasons":reasons})
            });
        let mut grouped: BTreeMap<
            (
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
            ),
            Vec<&Turn>,
        > = BTreeMap::new();
        for (id, t) in &self.turns {
            if !t.complete || quality_of(t)["status"] != "verified" {
                continue;
            }
            let e = &t.evidence;
            let unknown = if e.model.is_none() || e.effort.is_none() || e.tier.is_none() {
                Some(id.clone())
            } else {
                None
            };
            grouped
                .entry((
                    session.clone(),
                    e.model.clone(),
                    e.effort.clone(),
                    e.tier.clone(),
                    unknown,
                ))
                .or_default()
                .push(t);
        }
        let groups:Vec<_>=grouped.into_iter().filter_map(|((session,model,effort,tier,_),turns)| {
            let output=turns.iter().try_fold(0u64,|a,t|a.checked_add(t.output?))?;
            let duration=turns.iter().try_fold(0u64,|a,t|a.checked_add(t.duration?))?;
            Some(json!({"sessionId":session,"model":model,"effort":effort,"serviceTier":tier,"turnCount":turns.len(),"outputTokens":output,"durationMs":duration,"tokensPerSecond":session_quality::rate(Some(output),Some(duration))}))
        }).collect();
        Ok(
            json!({"logEpoch":self.epoch,"current":current,"terminals":terminals,"active":active,"catchingUp":catching_up,"last":last,"completedTurns":self.turns.values().filter(|t|t.complete).count(),"sourceInfo":self.source_info,"quality":quality,"verifiedGroups":groups,"measurement":{"kind":"observed_turn","sourceLabel":"所选 Codex 会话 · 本地只读日志","sessionId":session,"tokenSource":"turn_token_usage.output_tokens","durationSource":"task_complete.duration_ms","outputIncludesReasoning":if latest.is_some_and(|(_,t)|t.evidence.recognized){Some(true)}else{None}}}),
        )
    }
}
fn recent(base: &Path) -> Vec<Value> {
    let mut files = Vec::new();
    walk(base, 0, &mut files);
    files.sort_by_key(|p| {
        (
            fs::metadata(p).ok().and_then(|m| m.modified().ok()),
            p.clone(),
        )
    });
    files.reverse();
    let sessions: Vec<_> = files
        .iter()
        .filter_map(|p| p.canonicalize().ok())
        .filter(|p| p.starts_with(base))
        .filter_map(|p| metadata(&p))
        .take(100)
        .collect();
    sessions
}
pub fn execute(payload: Value) -> Result<Value, String> {
    let base = root()?;
    if payload["action"] == "list" {
        let sessions = recent(&base);
        return Ok(json!({"sessions":sessions}));
    }
    let path = PathBuf::from(payload["path"].as_str().ok_or("请先选择会话")?)
        .canonicalize()
        .map_err(|_| "所选会话不存在")?;
    if !path.starts_with(&base)
        || path.extension().is_none_or(|e| e != "jsonl")
        || metadata(&path).is_none()
    {
        return Err("仅允许读取本机会话目录中的主会话日志".into());
    }
    let mut guard = READERS.lock().map_err(|_| "会话采集锁不可用")?;
    if payload["action"] == "history" {
        guard.history(path, &payload)
    } else {
        guard.poll(path)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn pool_keeps_nine_interleaved_readers_and_reuses_same_path() {
        let mut files: Vec<_> = (0..9)
            .map(|_| tempfile::NamedTempFile::new().unwrap())
            .collect();
        let mut pool = ReaderPool::default();
        let mut epochs = Vec::new();
        for (i, f) in files.iter_mut().enumerate() {
            writeln!(f, "{}", json!({"type":"event_msg","payload":{"type":"task_started","turn_id":format!("t{i}")}})).unwrap();
            epochs.push(pool.poll(f.path().to_path_buf()).unwrap()["logEpoch"].clone());
        }
        for (i, f) in files.iter_mut().enumerate() {
            writeln!(f, "{}", json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":format!("t{i}")}})).unwrap();
            let value = pool.poll(f.path().to_path_buf()).unwrap();
            assert_eq!(value["logEpoch"], epochs[i]);
            assert_eq!(value["current"]["status"], "completed");
            assert_eq!(
                pool.poll(f.path().to_path_buf()).unwrap()["logEpoch"],
                epochs[i]
            );
        }
    }
    #[test]
    fn pool_lru_keeps_seventeen_paths_and_evicts_only_on_eighteenth() {
        let mut files: Vec<_> = (0..18)
            .map(|_| tempfile::NamedTempFile::new().unwrap())
            .collect();
        let mut pool = ReaderPool::default();
        let mut epochs = Vec::new();
        for f in files.iter_mut().take(17) {
            writeln!(
                f,
                "{}",
                json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}})
            )
            .unwrap();
            epochs.push(pool.poll(f.path().to_path_buf()).unwrap()["logEpoch"].clone());
        }
        for (i, f) in files.iter().take(17).enumerate() {
            assert_eq!(
                pool.poll(f.path().to_path_buf()).unwrap()["logEpoch"],
                epochs[i]
            );
        }
        pool.poll(files[0].path().to_path_buf()).unwrap();
        pool.poll(files[17].path().to_path_buf()).unwrap();
        assert_eq!(pool.readers.len(), 17);
        assert_eq!(
            pool.poll(files[0].path().to_path_buf()).unwrap()["logEpoch"],
            epochs[0]
        );
        assert_ne!(
            pool.poll(files[1].path().to_path_buf()).unwrap()["logEpoch"],
            epochs[1]
        );
        files[0].as_file().set_len(0).unwrap();
        assert_ne!(
            pool.poll(files[0].path().to_path_buf()).unwrap()["logEpoch"],
            epochs[0]
        );
        assert_eq!(
            pool.poll(files[3].path().to_path_buf()).unwrap()["logEpoch"],
            epochs[3]
        );
    }
    #[test]
    fn pool_file_rotation_changes_only_that_paths_epoch() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("rollout-a.jsonl");
        let b = dir.path().join("rollout-b.jsonl");
        for path in [&a, &b] {
            fs::write(
                path,
                format!(
                    "{}\n",
                    json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"before"}})
                ),
            )
            .unwrap();
        }
        let mut pool = ReaderPool::default();
        let a_epoch = pool.poll(a.clone()).unwrap()["logEpoch"].clone();
        let b_epoch = pool.poll(b.clone()).unwrap()["logEpoch"].clone();
        fs::rename(&a, dir.path().join("rotated.jsonl")).unwrap();
        fs::write(&a, format!("{}\n", json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"after-rotation"}}))).unwrap();
        let after = pool.poll(a).unwrap();
        assert_ne!(after["logEpoch"], a_epoch);
        assert_eq!(after["current"]["turnId"], "after-rotation");
        assert_eq!(pool.poll(b).unwrap()["logEpoch"], b_epoch);
    }
    fn m1_usage(turn: &str, response: &str, output: u64, total: u64) -> Value {
        json!({"type":"token_usage_record","timestamp":"1970-01-01T00:00:02.000Z","payload":{"turn_id":turn,"thread_id":"session","response_id":response,"model":"model","usage":{"input_tokens":100,"output_tokens":output,"reasoning_output_tokens":5},"turn_token_usage":{"input_tokens":100,"output_tokens":total,"reasoning_output_tokens":5},"thread_token_usage":{"input_tokens":100,"output_tokens":total,"reasoning_output_tokens":5}}})
    }
    fn m1_records(turn: &str, output: u64, duration: u64) -> Vec<Value> {
        vec![
            json!({"type":"session_meta","payload":{"id":"session","source":"vscode"}}),
            json!({"type":"turn_context","payload":{"turn_id":turn,"model":"model","effort":"high","service_tier":"standard"}}),
            m1_usage(turn, &format!("r-{turn}"), output, output),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":turn,"started_at":1,"completed_at":1+duration/1000,"duration_ms":duration}}),
        ]
    }
    fn m1_poll(records: &[Value]) -> Value {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        for v in records {
            writeln!(f, "{v}").unwrap();
        }
        Reader::default().poll(f.path().to_path_buf()).unwrap()
    }
    fn timeline_records() -> Vec<Value> {
        let mut records = m1_records("a", 20, 2000);
        records.push(json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","started_at_ms":1000,"completed_at_ms":2000,"item":{"id":"PRIVATE","type":"AgentMessage","content":"PRIVATE"}}}));
        records
    }
    #[test]
    fn session_timeline_reader_global_incomplete_missing_identity_and_conflict_overlay() {
        for cause in ["incomplete", "identity", "conflict"] {
            let mut records = timeline_records();
            if cause == "identity" {
                records.push(json!({"type":"event_msg","payload":{"type":"item_completed","item":{"id":"unowned","type":"AgentMessage"}}}));
            }
            if cause == "conflict" {
                let mut conflicting = records[3].clone();
                conflicting["payload"]["duration_ms"] = json!(3000);
                records.push(conflicting);
            }
            let mut f = tempfile::NamedTempFile::new().unwrap();
            for record in records {
                writeln!(f, "{record}").unwrap();
            }
            if cause == "incomplete" {
                writeln!(f, "malformed synthetic record").unwrap();
            }
            let v = Reader::default().poll(f.path().to_path_buf()).unwrap();
            let a = &v["last"]["analysis"];
            assert_eq!(a["partial"], false, "original H2 partial stays unchanged");
            assert_eq!(a["timeline"]["sourcePartial"], true, "{cause}");
            assert_eq!(
                a["timeline"]["coverageInterpretation"], "unavailable",
                "{cause}"
            );
            assert_eq!(a["observedMs"], 1000);
        }
    }
    #[test]
    fn session_timeline_reader_catching_up_keeps_facts_but_disables_coverage() {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        for record in timeline_records() {
            writeln!(f, "{record}").unwrap();
        }
        // A pending append is catchingUp evidence even before it becomes parseable.
        write!(f, "{{\"type\":\"event_msg\"").unwrap();
        let v = Reader::default().poll(f.path().to_path_buf()).unwrap();
        assert_eq!(v["catchingUp"], true);
        assert_eq!(v["last"]["analysis"]["timeline"]["sourcePartial"], true);
        assert_eq!(
            v["last"]["analysis"]["timeline"]["items"][0]["drawable"],
            true
        );
        assert_eq!(
            v["last"]["analysis"]["timeline"]["coverageInterpretation"],
            "unavailable"
        );
    }
    #[test]
    fn session_timeline_reader_new_epoch_discards_previous_projection() {
        let mut first = tempfile::NamedTempFile::new().unwrap();
        for record in timeline_records() {
            writeln!(first, "{record}").unwrap();
        }
        let mut second = tempfile::NamedTempFile::new().unwrap();
        for record in m1_records("b", 40, 4000) {
            writeln!(second, "{record}").unwrap();
        }
        let mut reader = Reader::default();
        let a = reader.poll(first.path().to_path_buf()).unwrap();
        assert_eq!(a["last"]["analysis"]["timeline"]["totalItems"], 1);
        let b = reader.poll(second.path().to_path_buf()).unwrap();
        assert_ne!(a["logEpoch"], b["logEpoch"]);
        assert_eq!(b["last"]["turnId"], "b");
        assert_eq!(b["last"]["analysis"]["timeline"]["totalItems"], 0);
        assert_eq!(b["last"]["analysis"]["timeline"]["items"], json!([]));
    }
    #[test]
    fn session_m1_verified_replay_and_reasoning_are_not_double_counted() {
        let mut records = m1_records("a", 20, 2000);
        records.push(records[2].clone());
        let v = m1_poll(&records);
        assert_eq!(v["quality"]["status"], "verified");
        assert_eq!(v["last"]["verifiedTokensPerSecond"], 10.0);
        assert_eq!(v["measurement"]["outputIncludesReasoning"], true);
        assert_eq!(v["verifiedGroups"][0]["outputTokens"], 20);
    }
    #[test]
    fn session_m1_response_linked_cumulative_replay_does_not_regress() {
        let mut records = m1_records("a", 10, 2000);
        records.insert(3, m1_usage("a", "r2", 10, 20));
        records[3]["payload"]["turn_token_usage"]["reasoning_output_tokens"] = json!(10);
        records[3]["payload"]["thread_token_usage"]["reasoning_output_tokens"] = json!(10);
        records.push(records[2].clone());
        let v = m1_poll(&records);
        assert_eq!(v["last"]["outputTokens"], 20);
        assert_eq!(v["quality"]["status"], "verified");
        records.push(m1_usage("a", "r2", 11, 21));
        assert_eq!(m1_poll(&records)["quality"]["status"], "conflict");
    }
    #[test]
    fn session_m1_conflicting_terminal_freezes_h2_bounds() {
        let mut records = m1_records("a", 20, 2000);
        records.push(json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","started_at_ms":1000,"completed_at_ms":2000,"item":{"id":"i","type":"CommandExecution"}}}));
        records.push(json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","started_at":10,"completed_at":12,"duration_ms":2000}}));
        let v = m1_poll(&records);
        assert_eq!(v["last"]["analysis"]["toolMs"], 1000);
        assert_eq!(v["quality"]["status"], "conflict");
        assert!(v["last"]["verifiedTokensPerSecond"].is_null());
    }
    #[test]
    fn session_m1_conflicting_item_and_snapshot_are_visible() {
        let mut records = m1_records("a", 20, 2000);
        for end in [2000, 2500] {
            records.push(json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","started_at_ms":1000,"completed_at_ms":end,"item":{"id":"i","type":"CommandExecution"}}}));
        }
        let v = m1_poll(&records);
        assert_eq!(v["quality"]["status"], "conflict");
        assert_eq!(v["last"]["analysis"]["toolMs"], 1000);
        let mut records = m1_records("a", 20, 2000);
        let mut changed = records[2].clone();
        changed["payload"]["turn_token_usage"]["output_tokens"] = json!(21);
        records.push(changed);
        assert_eq!(m1_poll(&records)["quality"]["status"], "conflict");
    }
    #[test]
    fn session_m1_invalid_missing_and_old_schema_never_verify() {
        for bad in [json!(-1), json!("20"), json!(1.5), json!(true)] {
            let mut records = m1_records("a", 20, 2000);
            records[2]["payload"]["usage"]["output_tokens"] = bad;
            let v = m1_poll(&records);
            assert_eq!(v["quality"]["status"], "incomplete");
            assert!(v["last"]["verifiedTokensPerSecond"].is_null());
        }
        let mut records = m1_records("a", 20, 0);
        assert_eq!(m1_poll(&records)["quality"]["status"], "incomplete");
        records.remove(2);
        assert_eq!(m1_poll(&records)["quality"]["status"], "incomplete");
        records.push(json!({"type":"event_msg","payload":{"type":"token_count","turn_id":"a","info":{"total_token_usage":{"output_tokens":20}}}}));
        assert_eq!(m1_poll(&records)["quality"]["status"], "unsupported");
    }
    #[test]
    fn session_m1_groups_use_weighted_duration_and_unknowns_stay_separate() {
        let mut records = m1_records("a", 20, 2000);
        records.extend(m1_records("b", 80, 4000).into_iter().skip(1));
        let v = m1_poll(&records);
        assert_eq!(v["verifiedGroups"].as_array().unwrap().len(), 1);
        assert_eq!(v["verifiedGroups"][0]["durationMs"], 6000);
        assert!(
            (v["verifiedGroups"][0]["tokensPerSecond"].as_f64().unwrap() - 100.0 / 6.0).abs()
                < 1e-10
        );
        for key in ["model", "effort", "service_tier"] {
            let mut r = records.clone();
            r[4]["payload"][key] = json!("different");
            if key == "model" {
                r[5]["payload"]["model"] = json!("different");
            }
            assert_eq!(
                m1_poll(&r)["verifiedGroups"].as_array().unwrap().len(),
                2,
                "{key}"
            );
        }
        for r in &mut records {
            if r["type"] == "turn_context" {
                r["payload"].as_object_mut().unwrap().remove("service_tier");
            }
        }
        assert_eq!(
            m1_poll(&records)["verifiedGroups"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }
    #[test]
    fn session_m1_longer_same_session_atomic_replacement_resets_epoch() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let write_log = |path: &Path, records: Vec<Value>| {
            let mut f = File::create(path).unwrap();
            for v in records {
                writeln!(f, "{v}").unwrap();
            }
        };
        write_log(&path, m1_records("old", 20, 2000));
        let mut reader = Reader::default();
        let before = reader.poll(path.clone()).unwrap();
        let replacement = dir.path().join("replacement");
        let mut newer = m1_records("new", 80, 4000);
        newer.push(json!({"padding":"longer file padding repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated repeated"}));
        write_log(&replacement, newer);
        assert!(fs::metadata(&replacement).unwrap().len() > fs::metadata(&path).unwrap().len());
        fs::remove_file(&path).unwrap();
        fs::rename(replacement, &path).unwrap();
        let after = reader.poll(path).unwrap();
        assert_ne!(before["logEpoch"], after["logEpoch"]);
        assert_eq!(after["completedTurns"], 1);
        assert_eq!(after["last"]["turnId"], "new");
        assert_eq!(after["sourceInfo"]["id"], "session");
    }
    #[test]
    fn session_m1_timestamp_identity_and_counter_ranges_gate_verification() {
        for (key, bad) in [
            ("reasoning_output_tokens", json!(21)),
            ("cached_input_tokens", json!(101)),
            ("input_tokens", json!(u64::MAX)),
        ] {
            let mut r = m1_records("a", 20, 2000);
            r[2]["payload"]["usage"][key] = bad;
            let v = m1_poll(&r);
            assert_eq!(v["quality"]["status"], "incomplete", "{key}");
        }
        for stamp in [
            json!(null),
            json!("1970-01-01T00:00:04.000Z"),
            json!("1970-02-30T00:00:02Z"),
            json!("1970-01-01T00:00:02junk"),
        ] {
            let mut r = m1_records("a", 20, 2000);
            r[2]["timestamp"] = stamp;
            assert_eq!(m1_poll(&r)["quality"]["status"], "incomplete");
        }
        let mut r = m1_records("a", 20, 2000);
        r[2]["payload"]["thread_id"] = json!("other");
        assert_eq!(m1_poll(&r)["quality"]["status"], "conflict");
        r[2]["payload"].as_object_mut().unwrap().remove("thread_id");
        assert_eq!(m1_poll(&r)["quality"]["status"], "reported_only");
    }
    #[test]
    fn session_m1_late_compatible_usage_can_verify_and_cross_turn_response_cannot() {
        let mut r = m1_records("a", 20, 2000);
        let usage = r.remove(2);
        r.push(usage);
        assert_eq!(m1_poll(&r)["quality"]["status"], "verified");
        let mut b = m1_records("b", 20, 2000);
        b[2]["payload"]["response_id"] = json!("r-a");
        r.extend(b.into_iter().skip(1));
        let v = m1_poll(&r);
        assert_eq!(v["quality"]["status"], "conflict");
        assert_eq!(v["verifiedGroups"], json!([]));
    }
    #[test]
    fn session_m1_conflicting_item_content_is_invalid() {
        let mut r = m1_records("a", 20, 2000);
        for content in ["one", "two"] {
            r.push(json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","started_at_ms":1000,"completed_at_ms":2000,"item":{"id":"i","type":"AgentMessage","content":content}}}));
        }
        assert_eq!(m1_poll(&r)["quality"]["status"], "conflict");
    }
    #[test]
    fn session_m1_first_token_cannot_exceed_duration() {
        let mut r = m1_records("a", 20, 2000);
        r[3]["payload"]["time_to_first_token_ms"] = json!(3000);
        assert_eq!(m1_poll(&r)["quality"]["status"], "incomplete");
    }
    #[test]
    fn session_m1_snapshot_counter_disagreement_cannot_verify() {
        let mut r = m1_records("a", 10, 2000);
        r.insert(3, m1_usage("a", "r2", 10, 20));
        // The complete output ledger is20, but reasoning5+5 cannot reconcile
        // with a final snapshot claiming only5 reasoning tokens.
        assert_eq!(m1_poll(&r)["quality"]["status"], "incomplete");
    }
    #[test]
    fn session_m1_missing_turn_identity_cannot_hide_known_response_conflicts() {
        for identity in [json!(null), json!(""), json!(123), json!("   ")] {
            let mut r = m1_records("a", 20, 2000);
            let mut malformed = r[2].clone();
            malformed["payload"]["turn_id"] = identity;
            malformed["payload"]["usage"]["output_tokens"] = json!(21);
            r.push(malformed);
            let v = m1_poll(&r);
            assert_eq!(v["quality"]["status"], "conflict");
            assert!(v["last"]["verifiedTokensPerSecond"].is_null());
            assert_eq!(v["verifiedGroups"], json!([]));
        }
    }
    #[test]
    fn session_m1_unresolved_relevant_identity_downgrades_collection() {
        let mut r = m1_records("a", 20, 2000);
        let mut malformed = m1_usage("a", "unresolved", 10, 10);
        malformed["payload"]
            .as_object_mut()
            .unwrap()
            .remove("turn_id");
        r.push(malformed);
        let v = m1_poll(&r);
        assert_eq!(v["quality"]["status"], "incomplete");
        assert!(v["quality"]["reasons"]
            .as_array()
            .unwrap()
            .contains(&json!("missing_identity")));
        assert!(v["last"]["verifiedTokensPerSecond"].is_null());
    }
    #[test]
    fn session_m1_context_request_model_disagreement_never_merges() {
        let mut r = m1_records("a", 20, 2000);
        r.extend(m1_records("b", 80, 4000).into_iter().skip(1));
        r[5]["payload"]["model"] = json!("other-model");
        let v = m1_poll(&r);
        assert_eq!(v["quality"]["status"], "conflict");
        assert!(v["last"]["verifiedTokensPerSecond"].is_null());
        assert_eq!(v["verifiedGroups"].as_array().unwrap().len(), 1);
        assert_eq!(v["verifiedGroups"][0]["turnCount"], 1);
        assert_eq!(v["verifiedGroups"][0]["outputTokens"], 20);
    }
    #[test]
    fn session_m1_cross_response_model_disagreement_is_conflict() {
        let mut r = m1_records("a", 10, 2000);
        r.remove(1); // No context: requests themselves must still agree.
        let mut second = m1_usage("a", "r2", 10, 20);
        second["payload"]["model"] = json!("other-model");
        second["payload"]["turn_token_usage"]["reasoning_output_tokens"] = json!(10);
        second["payload"]["thread_token_usage"]["reasoning_output_tokens"] = json!(10);
        r.push(second);
        assert_eq!(m1_poll(&r)["quality"]["status"], "conflict");
    }
    #[test]
    fn session_m1_unsupported_capability_survives_without_completed_turn() {
        for legacy in [
            json!({"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":20}}}}),
            json!({"type":"compacted","payload":{"compaction_response_id":"c"}}),
        ] {
            let r = vec![m1_records("a", 20, 2000)[0].clone(), legacy];
            let v = m1_poll(&r);
            assert!(v["last"].is_null());
            assert_eq!(v["quality"]["status"], "unsupported");
            assert!(v["quality"]["reasons"]
                .as_array()
                .unwrap()
                .contains(&json!("unsupported_token_schema")));
        }
    }
    #[test]
    fn recent_uses_modification_time_and_exposes_only_metadata() {
        let dir = tempfile::tempdir().unwrap();
        for (name, stamp) in [("rollout-z.jsonl", 100), ("rollout-a.jsonl", 200)] {
            let path = dir.path().join(name);
            let mut file = File::create(path).unwrap();
            writeln!(file, "{}", json!({"type":"session_meta","payload":{"id":name,"cwd":"fixture","source":"vscode","title":"safe title"}})).unwrap();
            writeln!(
                file,
                "{}",
                json!({"type":"event_msg","payload":{"message":"private prompt"}})
            )
            .unwrap();
            file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(stamp))
                .unwrap();
        }
        let rows = recent(&dir.path().canonicalize().unwrap());
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], "rollout-a.jsonl");
        assert_eq!(rows[0]["modifiedMs"], 200000);
        assert_eq!(rows[0]["title"], "safe title");
        assert!(!serde_json::to_string(&rows)
            .unwrap()
            .contains("private prompt"));
    }
    #[test]
    fn lifecycle_replay_cancel_and_log_reset_are_explicit() {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        let record = |kind: &str, id: &str| json!({"type":"event_msg","payload":{"type":kind,"turn_id":id,"duration_ms":2000}});
        for v in [
            record("task_started", "old"),
            record("task_complete", "old"),
            record("task_started", "live"),
            record("task_complete", "old"),
        ] {
            writeln!(f, "{}", v).unwrap();
        }
        let mut reader = Reader::default();
        let path = f.path().to_path_buf();
        let a = reader.poll(path.clone()).unwrap();
        assert_eq!(a["current"]["turnId"], "live");
        assert_eq!(a["current"]["status"], "running");
        assert_eq!(a["terminals"].as_array().unwrap().len(), 1);
        for v in [
            record("turn_aborted", "live"),
            record("task_complete", "live"),
            record("task_started", "live"),
        ] {
            writeln!(f, "{}", v).unwrap();
        }
        let b = reader.poll(path.clone()).unwrap();
        assert_eq!(b["current"]["status"], "cancelled");
        assert_eq!(b["last"]["turnId"], "old");
        assert_eq!(b["active"], false);
        f.as_file().set_len(0).unwrap();
        let c = reader.poll(path).unwrap();
        assert_ne!(a["logEpoch"], c["logEpoch"]);
        assert!(c["current"].is_null());
    }
    #[test]
    fn item_events_are_scoped_to_completed_turn_and_exclude_content() {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        let records = [
            json!({"type":"token_usage_record","payload":{"turn_id":"a","response_id":"r","usage":{"output_tokens":20},"turn_token_usage":{"output_tokens":20}}}),
            json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","started_at_ms":1000,"completed_at_ms":2000,"item":{"id":"i","type":"CommandExecution","command":"PRIVATE"}}}),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","started_at":1,"completed_at":3,"duration_ms":2000}}),
            json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"b","started_at_ms":1000,"completed_at_ms":3000,"item":{"id":"other","type":"AgentMessage"}}}),
        ];
        for value in records {
            writeln!(f, "{}", value).unwrap();
        }
        let result = Reader::default().poll(f.path().to_path_buf()).unwrap();
        assert_eq!(result["last"]["turnId"], "a");
        assert_eq!(result["last"]["analysis"]["toolMs"], 1000);
        assert_eq!(result["last"]["analysis"]["unclassifiedMs"], 1000);
        assert_eq!(result["last"]["analysis"]["usageMatchesTurn"], true);
        assert!(!result.to_string().contains("PRIVATE"));
    }
    #[test]
    fn snapshots_partial_append_and_truncation() {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        writeln!(
            f,
            "{}",
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}})
        )
        .unwrap();
        for n in [10, 20, 20] {
            writeln!(f,"{}",json!({"type":"token_usage_record","payload":{"turn_id":"a","turn_token_usage":{"output_tokens":n,"reasoning_output_tokens":5}}})).unwrap();
        }
        let mut r = Reader::default();
        let path = f.path().to_path_buf();
        assert_eq!(r.poll(path.clone()).unwrap()["active"], true);
        let done=json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","duration_ms":2000,"time_to_first_token_ms":100}}).to_string();
        write!(f, "{done}").unwrap();
        assert!(r.poll(path.clone()).unwrap()["last"].is_null());
        writeln!(f).unwrap();
        let v = r.poll(path.clone()).unwrap();
        assert_eq!(v["last"]["tokensPerSecond"], 10.0);
        assert_eq!(v["last"]["reasoningTokens"], 5);
        assert_eq!(v["active"], false);
        f.as_file().set_len(0).unwrap();
        assert!(r.poll(path).unwrap()["last"].is_null());
    }
    #[test]
    fn aborted_turn_is_not_active_or_a_completed_sample() {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        for kind in ["task_started", "turn_aborted"] {
            writeln!(
                f,
                "{}",
                json!({"type":"event_msg","payload":{"type":kind,"turn_id":"a"}})
            )
            .unwrap();
        }
        let v = Reader::default().poll(f.path().to_path_buf()).unwrap();
        assert_eq!(v["active"], false);
        assert!(v["last"].is_null());
    }
    #[test]
    fn missing_usage_and_zero_duration_are_unavailable() {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        writeln!(f,"{}",json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","duration_ms":0}})).unwrap();
        let v = Reader::default().poll(f.path().to_path_buf()).unwrap();
        assert!(v["last"]["tokensPerSecond"].is_null());
    }
}
