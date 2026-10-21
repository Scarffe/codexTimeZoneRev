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
#[derive(Default)]
struct Turn {
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
}
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
static READER: Mutex<Option<Reader>> = Mutex::new(None);
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
    let mut reader = BufReader::new(File::open(path).ok()?);
    let value: Value = serde_json::from_slice(&line(&mut reader).ok()?).ok()?;
    if value["type"] != "session_meta" || value["payload"]["source"].is_object() {
        return None;
    }
    let p = &value["payload"];
    Some(
        json!({"id":p["id"],"cwd":p["cwd"],"timestamp":p["timestamp"],"source":p["source"],"path":path}),
    )
}
impl Reader {
    fn poll(&mut self, path: PathBuf) -> Result<Value, String> {
        let file = File::open(&path).map_err(|_| "所选会话已移除或不可读取")?;
        let meta = file.metadata().map_err(|_| "会话属性读取失败")?;
        let modified = meta.modified().ok();
        if self.path != path
            || meta.len() < self.offset
            || (meta.len() == self.offset && self.stamp != modified)
        {
            *self = Reader {
                path,
                epoch: NEXT_EPOCH.fetch_add(1, Ordering::Relaxed),
                ..Default::default()
            };
        }
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
                continue;
            };
            if v["type"] != "event_msg" && v["type"] != "token_usage_record" {
                continue;
            }
            let p = &v["payload"];
            let Some(id) = p["turn_id"].as_str() else {
                continue;
            };
            let kind = if v["type"] == "token_usage_record" {
                "token_usage_record"
            } else {
                p["type"].as_str().unwrap_or("")
            };
            if ![
                "task_started",
                "task_complete",
                "turn_aborted",
                "token_usage_record",
                "item_completed",
            ]
            .contains(&kind)
            {
                continue;
            }
            self.serial += 1;
            let t = self.turns.entry(id.to_owned()).or_default();
            t.timing.accept(kind, p, self.serial);
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
                // turn_token_usage is a snapshot: replace, never sum repeated/cumulative notifications.
                if let Some(n) = p["turn_token_usage"]["output_tokens"].as_u64() {
                    t.output = Some(n);
                    t.reasoning = p["turn_token_usage"]["reasoning_output_tokens"].as_u64();
                }
            }
        }
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
        let last = latest.map(|(id,t)| json!({"turnId":id,"outputTokens":t.output,"reasoningTokens":t.reasoning,"durationMs":t.duration,"firstTokenMs":t.first,"analysis":t.timing.report(t.duration,t.output),"tokensPerSecond": t.output.zip(t.duration).filter(|(_,d)| *d>0).map(|(n,d)| n as f64*1000.0/d as f64)}));
        Ok(
            json!({"logEpoch":self.epoch,"current":current,"terminals":terminals,"active":active,"catchingUp":self.offset<meta.len(),"last":last,"completedTurns":self.turns.values().filter(|t|t.complete).count()}),
        )
    }
}
pub fn execute(payload: Value) -> Result<Value, String> {
    let base = root()?;
    if payload["action"] == "list" {
        let mut files = Vec::new();
        walk(&base, 0, &mut files);
        files.sort();
        files.reverse();
        let sessions: Vec<_> = files
            .iter()
            .filter_map(|p| p.canonicalize().ok())
            .filter(|p| p.starts_with(&base))
            .filter_map(|p| metadata(&p))
            .take(100)
            .collect();
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
    let mut guard = READER.lock().map_err(|_| "会话采集锁不可用")?;
    guard.get_or_insert_with(Reader::default).poll(path)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
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
