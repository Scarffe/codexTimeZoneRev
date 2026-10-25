use super::{session_quality, Reader};
use serde_json::{json, Value};
use std::collections::BTreeSet;

pub(super) struct Request {
    after: u64,
    limit: usize,
    epoch: Option<u64>,
    revision: Option<u64>,
}
impl Request {
    pub fn parse(value: &Value) -> Result<Self, String> {
        let number = |key: &str| -> Result<Option<u64>, String> {
            match value.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(n) => n
                    .as_u64()
                    .map(Some)
                    .ok_or_else(|| format!("会话历史参数 {key} 必须为非负整数")),
            }
        };
        let limit = number("limit")?.unwrap_or(256);
        if !(1..=512).contains(&limit) {
            return Err("会话历史分页大小必须为 1..512".into());
        }
        Ok(Self {
            after: number("afterOrder")?.unwrap_or(0),
            limit: limit as usize,
            epoch: number("expectedEpoch")?,
            revision: number("expectedRevision")?,
        })
    }
}
#[derive(Clone, Copy)]
struct Time {
    ms: u64,
    resolution: u64,
}
fn explicit(value: &Value) -> Option<Time> {
    Some(Time {
        ms: value.as_u64()?.checked_mul(1000)?,
        resolution: 1000,
    })
}
fn timestamp(value: &Value) -> Option<Time> {
    let ms = session_quality::timestamp(value)?;
    let s = value.as_str()?;
    let digits = s
        .get(19..)?
        .strip_prefix('.')
        .map(|fraction| fraction.bytes().take_while(u8::is_ascii_digit).count())
        .unwrap_or(0);
    Some(Time {
        ms,
        resolution: match digits {
            0 => 1000,
            1 => 100,
            2 => 10,
            _ => 1,
        },
    })
}
#[derive(Default)]
pub(super) struct Lifecycle {
    start: Option<Time>,
    end: Option<Time>,
    terminal: bool,
}
impl Lifecycle {
    pub fn accept(&mut self, kind: &str, payload: &Value, record: &Value) {
        if self.terminal {
            return;
        }
        match kind {
            "task_started" if self.start.is_none() => {
                self.start =
                    explicit(&payload["started_at"]).or_else(|| timestamp(&record["timestamp"]));
            }
            "task_complete" | "turn_aborted" => {
                self.start = explicit(&payload["started_at"]).or(self.start);
                self.end =
                    explicit(&payload["completed_at"]).or_else(|| timestamp(&record["timestamp"]));
                self.terminal = true;
            }
            _ => {}
        }
    }
    fn resolution(&self) -> Option<u64> {
        self.start
            .into_iter()
            .chain(self.end)
            .map(|t| t.resolution)
            .max()
    }
    fn window(&self, duration: Option<u64>) -> Option<(u64, u64)> {
        let (start, end) = self.start.zip(self.end)?;
        let span = end.ms.checked_sub(start.ms)?;
        let resolution = self.resolution()?;
        if duration.is_some_and(|d| d.abs_diff(span) >= resolution) {
            return None;
        }
        // Epoch-second end fields describe a quantized logged window. Use the
        // same inclusive upper bucket as Timing; never invent finer precision.
        Some((start.ms, end.ms.checked_add(end.resolution)?))
    }
}
pub(super) fn project(reader: &Reader, request: &Request, catching_up: bool) -> Value {
    let changed = request.epoch.is_some_and(|e| e != reader.epoch)
        || request.revision.is_some_and(|r| r != reader.serial);
    let mut turns: Vec<_> = reader
        .turns
        .iter()
        .filter(|(_, t)| t.history_order > request.after)
        .collect();
    turns.sort_by_key(|(_, t)| t.history_order);
    let more = turns.len() > request.limit;
    let records: Vec<_> = if changed {
        Vec::new()
    } else {
        turns.into_iter().take(request.limit).map(|(id,t)| {
        let lifecycle = &t.lifecycle;
        let (intervals, activity_reasons) = t.timing.history_activity(lifecycle.window(t.duration),t.duration);
        let mut reasons: BTreeSet<String> = activity_reasons.into_iter().map(str::to_owned).collect();
        reasons.extend(t.evidence.conflicts.iter().cloned());
        if reader.incomplete || catching_up { reasons.insert("incomplete_history".into()); }
        if reader.missing_identity { reasons.insert("missing_identity".into()); }
        if reader.unsupported { reasons.insert("unsupported_token_schema".into()); }
        if lifecycle.start.is_none() { reasons.insert("missing_start_time".into()); }
        if lifecycle.end.is_none() { reasons.insert("missing_terminal_time".into()); }
        let available = reasons.is_empty();
        json!({"order":t.history_order,"turnId":id,"status":if t.state.is_empty(){"unknown"}else{&t.state},
            "startedAtMs":lifecycle.start.map(|t|t.ms),"completedAtMs":lifecycle.end.map(|t|t.ms),"timeResolutionMs":lifecycle.resolution(),
            "durationMs":t.duration,"firstTokenMs":t.first,"activityIntervals":intervals,"activityAvailable":available,"partial":!available,"reasons":reasons})
    }).collect()
    };
    let next = if !changed && more {
        records.last().map(|r| r["order"].clone())
    } else {
        None
    };
    json!({"historyVersion":1,"sourceInfo":reader.source_info,"logEpoch":reader.epoch,"revision":reader.serial,"catchingUp":catching_up,"changed":changed,"records":records,"nextOrder":next})
}

#[cfg(test)]
mod tests {
    use super::super::*;
    use std::io::Write;

    fn event(kind: &str, turn: &str, fields: Value) -> Value {
        let mut payload = fields;
        payload["type"] = json!(kind);
        payload["turn_id"] = json!(turn);
        json!({"type":"event_msg","payload":payload})
    }
    fn complete(turn: &str) -> Value {
        event(
            "task_complete",
            turn,
            json!({"started_at":100,"completed_at":110,"duration_ms":10000,"time_to_first_token_ms":50}),
        )
    }
    fn item(turn: &str, id: &str, kind: &str, a: u64, b: u64) -> Value {
        event(
            "item_completed",
            turn,
            json!({"item":{"id":id,"type":kind,"content":"PRIVATE","command":"PRIVATE"},"started_at_ms":a,"completed_at_ms":b}),
        )
    }
    fn file(records: &[Value]) -> tempfile::NamedTempFile {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        writeln!(f, "{}", json!({"type":"session_meta","payload":{"id":"session","source":"vscode","title":"synthetic"}})).unwrap();
        for record in records {
            writeln!(f, "{record}").unwrap();
        }
        f
    }
    fn read(pool: &mut ReaderPool, f: &tempfile::NamedTempFile, request: Value) -> Value {
        pool.history(f.path().to_path_buf(), &request).unwrap()
    }
    #[test]
    fn session_history_pages_all_turns_in_first_seen_order_beyond_terminal_limit() {
        let mut records = vec![event("turn_context", "old", json!({}))];
        records.extend((0..70).map(|n| complete(&format!("t{n}"))));
        records.push(complete("old"));
        let f = file(&records);
        let mut pool = ReaderPool::default();
        let first = read(&mut pool, &f, json!({"limit":32}));
        assert_eq!(first["historyVersion"], 1);
        assert_eq!(first["changed"], false);
        assert_eq!(first["records"].as_array().unwrap().len(), 32);
        assert_eq!(first["records"][0]["turnId"], "old");
        assert_eq!(first["records"][0]["order"], 1);
        let second = read(
            &mut pool,
            &f,
            json!({"limit":32,"afterOrder":first["nextOrder"],"expectedEpoch":first["logEpoch"],"expectedRevision":first["revision"]}),
        );
        let third = read(
            &mut pool,
            &f,
            json!({"limit":32,"afterOrder":second["nextOrder"],"expectedEpoch":first["logEpoch"],"expectedRevision":first["revision"]}),
        );
        assert_eq!(second["records"].as_array().unwrap().len(), 32);
        assert_eq!(third["records"].as_array().unwrap().len(), 7);
        assert!(third["nextOrder"].is_null());
        assert_eq!(third["records"][6]["turnId"], "t69");
        assert_eq!(first["sourceInfo"]["id"], "session");
    }
    #[test]
    fn session_history_first_terminal_wins_and_uses_only_strict_lifecycle_times() {
        let mut start = event("task_started", "cancel", json!({}));
        start["timestamp"] = json!("1970-01-01T00:01:40.12Z");
        let mut cancel = event("turn_aborted", "cancel", json!({}));
        cancel["timestamp"] = json!("1970-01-01T00:01:45Z");
        let mut done = complete("done");
        done["timestamp"] = json!("1970-01-01T00:09:00Z");
        let f = file(&[
            start,
            cancel,
            complete("cancel"),
            done,
            complete("done"),
            event("task_complete", "missing", json!({"duration_ms":-1})),
            event("task_started", "running", json!({})),
            event("turn_context", "unknown", json!({})),
        ]);
        let v = read(&mut ReaderPool::default(), &f, json!({}));
        let r = v["records"].as_array().unwrap();
        assert_eq!(r[0]["status"], "cancelled");
        assert_eq!(r[0]["startedAtMs"], 100120);
        assert_eq!(r[0]["completedAtMs"], 105000);
        assert_eq!(r[0]["timeResolutionMs"], 1000);
        assert!(r[0]["durationMs"].is_null());
        assert_eq!(r[1]["completedAtMs"], 110000);
        assert_eq!(r[1]["durationMs"], 10000);
        assert_eq!(r[1]["firstTokenMs"], 50);
        assert!(r[2]["completedAtMs"].is_null());
        assert!(r[2]["durationMs"].is_null());
        assert_eq!(r[3]["status"], "running");
        assert_eq!(r[4]["status"], "unknown");
    }
    #[test]
    fn session_history_merges_all_categories_without_display_cap_or_private_content() {
        let mut records = vec![
            complete("a"),
            item("a", "PRIVATE-reason", "Reasoning", 100000, 102000),
            item("a", "PRIVATE-tool", "CommandExecution", 101000, 103000),
        ];
        records.extend((0..205).map(|n| {
            item(
                "a",
                &format!("PRIVATE-{n}"),
                "AgentMessage",
                104000 + n * 10,
                104005 + n * 10,
            )
        }));
        let f = file(&records);
        let mut pool = ReaderPool::default();
        let v = read(&mut pool, &f, json!({}));
        let fact = &v["records"][0];
        assert_eq!(fact["activityAvailable"], true);
        assert_eq!(fact["partial"], false);
        assert_eq!(fact["activityIntervals"].as_array().unwrap().len(), 206);
        assert_eq!(fact["activityIntervals"][0], json!([100000, 103000]));
        assert!(!v["records"].to_string().contains("PRIVATE"));
        let mut keys: Vec<_> = fact
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "activityAvailable",
                "activityIntervals",
                "completedAtMs",
                "durationMs",
                "firstTokenMs",
                "order",
                "partial",
                "reasons",
                "startedAtMs",
                "status",
                "timeResolutionMs",
                "turnId"
            ]
        );
        assert_eq!(
            pool.poll(f.path().to_path_buf()).unwrap()["last"]["analysis"]["timeline"]["items"]
                .as_array()
                .unwrap()
                .len(),
            200
        );
    }
    #[test]
    fn session_history_invalid_missing_conflicting_and_incomplete_activity_is_unavailable() {
        for cause in [
            "invalid",
            "missing",
            "outside",
            "conflict",
            "malformed",
            "identity",
            "empty",
        ] {
            let mut records = vec![complete("a")];
            if cause != "empty" {
                records.push(item("a", "i", "AgentMessage", 100000, 101000));
            }
            match cause {
                "invalid" => records.push(item("a","bad","Reasoning",102000,101000)),
                "missing" => records.push(event("item_completed","a",json!({"item":{"id":"missing","type":"AgentMessage"}}))),
                "outside" => records.push(item("a","outside","Reasoning",99999,100001)),
                "conflict" => records.push(item("a","i","AgentMessage",100000,102000)),
                "identity" => records.push(json!({"type":"event_msg","payload":{"type":"item_completed","item":{"id":"no-owner"}}})),
                _ => {}
            }
            let mut f = file(&records);
            if cause == "malformed" {
                writeln!(f, "invalid synthetic JSON").unwrap();
            }
            let v = read(&mut ReaderPool::default(), &f, json!({}));
            assert_eq!(v["records"][0]["activityAvailable"], false, "{cause}");
            assert_eq!(v["records"][0]["partial"], true, "{cause}");
            assert!(
                !v["records"][0]["reasons"].as_array().unwrap().is_empty(),
                "{cause}"
            );
            assert_eq!(v["records"][0]["durationMs"], 10000);
        }
    }
    #[test]
    fn session_history_late_item_invalidates_revision_and_replaces_fact() {
        let mut f = file(&[
            complete("a"),
            item("a", "first", "Reasoning", 100000, 101000),
        ]);
        let mut pool = ReaderPool::default();
        let first = read(&mut pool, &f, json!({"limit":1}));
        writeln!(f, "{}", item("a", "late", "AgentMessage", 101000, 103000)).unwrap();
        let changed = read(
            &mut pool,
            &f,
            json!({"afterOrder":1,"expectedEpoch":first["logEpoch"],"expectedRevision":first["revision"]}),
        );
        assert_eq!(changed["changed"], true);
        assert_eq!(changed["records"], json!([]));
        assert!(changed["nextOrder"].is_null());
        let updated = read(&mut pool, &f, json!({}));
        assert_eq!(updated["records"][0]["order"], 1);
        assert_eq!(
            updated["records"][0]["activityIntervals"],
            json!([[100000, 103000]])
        );
        assert_ne!(updated["revision"], first["revision"]);
    }
    #[test]
    fn session_history_same_path_replacement_cannot_mix_epochs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout-synthetic.jsonl");
        fs::write(&path, format!("{}\n", complete("old"))).unwrap();
        let mut pool = ReaderPool::default();
        let first = pool.history(path.clone(), &json!({})).unwrap();
        fs::rename(&path, dir.path().join("old.jsonl")).unwrap();
        fs::write(&path, format!("{}\n", complete("new"))).unwrap();
        let changed = pool
            .history(path.clone(), &json!({"expectedEpoch":first["logEpoch"]}))
            .unwrap();
        assert_eq!(changed["changed"], true);
        assert_eq!(changed["records"], json!([]));
        assert_ne!(changed["logEpoch"], first["logEpoch"]);
        assert_eq!(
            pool.history(path, &json!({})).unwrap()["records"][0]["turnId"],
            "new"
        );
    }
    #[test]
    fn session_history_default_metrics_contract_has_no_history_payload() {
        let f = file(&[complete("a")]);
        let mut pool = ReaderPool::default();
        let default = pool.poll(f.path().to_path_buf()).unwrap();
        for key in [
            "historyVersion",
            "records",
            "revision",
            "nextOrder",
            "changed",
        ] {
            assert!(default.get(key).is_none(), "{key}");
        }
        assert_eq!(default["terminals"].as_array().unwrap().len(), 1);
        let history = read(&mut pool, &f, json!({}));
        assert_eq!(history["historyVersion"], 1);
        assert!(history.get("last").is_none());
    }
    #[test]
    fn session_history_partial_append_invalidates_the_next_page_version() {
        let mut f = file(&[
            complete("a"),
            item("a", "i-a", "AgentMessage", 100000, 101000),
            complete("b"),
            item("b", "i-b", "AgentMessage", 100000, 101000),
        ]);
        let mut pool = ReaderPool::default();
        let first = read(&mut pool, &f, json!({"limit":1}));
        assert_eq!(first["catchingUp"], false);
        assert_eq!(first["records"][0]["activityAvailable"], true);
        write!(f, "{{\"type\":\"response_item\",\"payload\":").unwrap();
        let next = read(
            &mut pool,
            &f,
            json!({"afterOrder":first["nextOrder"],"expectedEpoch":first["logEpoch"],"expectedRevision":first["revision"]}),
        );
        assert_eq!(next["changed"], true);
        assert_eq!(next["records"], json!([]));
        assert!(next["nextOrder"].is_null());
        assert_eq!(next["catchingUp"], true);
        assert_ne!(next["revision"], first["revision"]);
        let fresh = read(&mut pool, &f, json!({}));
        assert_eq!(fresh["revision"], next["revision"]);
        assert_eq!(fresh["records"][0]["order"], 1);
        assert_eq!(fresh["records"][1]["order"], 3);
        assert_eq!(fresh["records"][0]["activityAvailable"], false);
    }
    #[test]
    fn session_history_ignored_tail_completion_invalidates_the_next_page_version() {
        let mut f = file(&[
            complete("a"),
            item("a", "i-a", "AgentMessage", 100000, 101000),
            complete("b"),
            item("b", "i-b", "AgentMessage", 100000, 101000),
        ]);
        write!(f, "{{\"type\":\"response_item\",\"payload\":").unwrap();
        let mut pool = ReaderPool::default();
        let first = read(&mut pool, &f, json!({"limit":1}));
        assert_eq!(first["catchingUp"], true);
        assert_eq!(first["records"][0]["activityAvailable"], false);
        writeln!(f, "\"ignored\"}}").unwrap();
        let next = read(
            &mut pool,
            &f,
            json!({"afterOrder":first["nextOrder"],"expectedEpoch":first["logEpoch"],"expectedRevision":first["revision"]}),
        );
        assert_eq!(next["changed"], true);
        assert_eq!(next["records"], json!([]));
        assert!(next["nextOrder"].is_null());
        assert_eq!(next["catchingUp"], false);
        assert_ne!(next["revision"], first["revision"]);
        let fresh = read(&mut pool, &f, json!({}));
        assert_eq!(fresh["revision"], next["revision"]);
        assert_eq!(fresh["records"][0]["order"], 1);
        assert_eq!(fresh["records"][1]["order"], 3);
        assert_eq!(fresh["records"][0]["activityAvailable"], true);
        assert_eq!(fresh["records"][1]["activityAvailable"], true);
    }
    #[test]
    fn session_history_missing_identity_or_corrupt_append_also_changes_revision() {
        for corrupt in [false, true] {
            let mut f = file(&[complete("a"), complete("b")]);
            let mut pool = ReaderPool::default();
            let first = read(&mut pool, &f, json!({"limit":1}));
            if corrupt {
                writeln!(f, "invalid synthetic JSON").unwrap();
            } else {
                writeln!(
                    f,
                    "{}",
                    json!({"type":"event_msg","payload":{"type":"item_completed"}})
                )
                .unwrap();
            }
            let changed = read(
                &mut pool,
                &f,
                json!({"afterOrder":first["nextOrder"],"expectedRevision":first["revision"]}),
            );
            assert_eq!(changed["changed"], true);
            assert_eq!(changed["records"], json!([]));
        }
    }
    #[test]
    fn session_history_timestamp_resolution_is_coarsest_known_boundary_and_invalid_is_unknown() {
        let mut a = event("task_started", "a", json!({}));
        a["timestamp"] = json!("1970-01-01T00:01:40.1Z");
        let mut b = event("turn_aborted", "a", json!({}));
        b["timestamp"] = json!("1970-01-01T00:01:41.123Z");
        let mut invalid = event("turn_aborted", "invalid", json!({}));
        invalid["timestamp"] = json!("2026-02-30T12:00:00Z");
        let f = file(&[a, b, invalid]);
        let v = read(&mut ReaderPool::default(), &f, json!({}));
        assert_eq!(v["records"][0]["timeResolutionMs"], 100);
        assert_eq!(v["records"][0]["completedAtMs"], 101123);
        assert!(v["records"][1]["completedAtMs"].is_null());
        assert!(v["records"][1]["timeResolutionMs"].is_null());
    }
    #[test]
    fn session_history_rejects_invalid_page_arguments_and_uses_default_page_size() {
        let f = file(
            &(0..257)
                .map(|n| complete(&format!("t{n}")))
                .collect::<Vec<_>>(),
        );
        let mut pool = ReaderPool::default();
        for request in [
            json!({"limit":0}),
            json!({"limit":513}),
            json!({"limit":-1}),
            json!({"limit":"2"}),
            json!({"afterOrder":-1}),
            json!({"expectedRevision":"2"}),
        ] {
            assert!(
                pool.history(f.path().to_path_buf(), &request).is_err(),
                "{request}"
            );
        }
        let v = read(&mut pool, &f, json!({}));
        assert_eq!(v["records"].as_array().unwrap().len(), 256);
        assert_eq!(v["nextOrder"], 256);
    }
    #[test]
    fn session_history_truncated_and_pending_append_never_publish_complete_activity() {
        let mut records = vec![complete("a")];
        records.extend(
            (0..10001).map(|n| item("a", &format!("i{n}"), "AgentMessage", 100000, 100001)),
        );
        let f = file(&records);
        let v = read(&mut ReaderPool::default(), &f, json!({}));
        assert_eq!(v["records"][0]["activityAvailable"], false);
        assert!(v["records"][0]["reasons"]
            .as_array()
            .unwrap()
            .contains(&json!("truncated")));
        let mut pending = file(&[
            complete("a"),
            item("a", "i", "AgentMessage", 100000, 101000),
        ]);
        write!(pending, "{{\"type\":").unwrap();
        let v = read(&mut ReaderPool::default(), &pending, json!({}));
        assert_eq!(v["catchingUp"], true);
        assert_eq!(v["records"][0]["activityAvailable"], false);
        assert!(v["records"][0]["reasons"]
            .as_array()
            .unwrap()
            .contains(&json!("incomplete_history")));
    }
}
