//! Ephemeral runtime metadata, separate from the persisted token ledger.
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Clone)]
pub(crate) struct LiveEvent {
    pub generation: u64,
    pub sequence: u64,
    pub observed_at_ms: u64,
    pub kind: u32,
    pub lifecycle: u32,
    pub attention: u32,
    pub flags: u32,
    pub request_key: Option<String>,
    pub thread_id: String,
    pub turn_id: Option<String>,
}

#[derive(Default)]
struct ThreadState {
    turn_id: Option<String>,
    state: &'static str,
    snapshot: Option<u32>,
    pending: BTreeMap<String, u32>,
    observed_at_ms: u64,
    sequence: u64,
    last_live_sequence: u64,
}
#[derive(Default)]
pub(crate) struct LiveStore {
    generation: u64,
    sequence: u64,
    revision: u64,
    dropped: u32,
    remote_drops: u32,
    threads: BTreeMap<String, ThreadState>,
}
impl LiveStore {
    pub(crate) fn watermark(&self) -> u64 {
        self.sequence
    }
    pub(crate) fn apply_snapshot(&mut self, snapshot: crate::runtime_bootstrap::ThreadSnapshot) {
        if snapshot.thread_id.is_empty() || !(1..=4).contains(&snapshot.status) {
            return;
        }
        if self.generation == 0 {
            self.generation = snapshot.stamp.generation;
        }
        if self.generation != snapshot.stamp.generation
            || self
                .threads
                .get(&snapshot.thread_id)
                .is_some_and(|row| row.last_live_sequence > snapshot.live_watermark)
        {
            return;
        }
        self.reserve_thread(&snapshot.thread_id);
        self.revision = self.revision.saturating_add(1);
        let row = self.threads.entry(snapshot.thread_id).or_default();
        row.state = match snapshot.status {
            1 => "not_loaded",
            2 => "idle",
            3 => "failed",
            4 => "running",
            _ => "unknown",
        };
        let attention = if snapshot.status == 4 {
            snapshot.attention & 3
        } else {
            0
        };
        row.pending.retain(|_, value| *value & attention != 0);
        row.snapshot = Some(attention);
        row.observed_at_ms = snapshot.stamp.observed_at_ms;
        row.sequence = self.revision;
    }
    fn reserve_thread(&mut self, id: &str) {
        if !self.threads.contains_key(id) && self.threads.len() >= 48 {
            let oldest = self
                .threads
                .iter()
                .min_by_key(|(_, row)| {
                    let waiting =
                        row.snapshot.unwrap_or(0) != 0 || row.pending.values().any(|v| *v != 0);
                    (
                        waiting || row.state == "running" || row.state == "failed",
                        row.sequence,
                    )
                })
                .map(|(key, _)| key.clone());
            if let Some(key) = oldest {
                self.threads.remove(&key);
                self.dropped = self.dropped.saturating_add(1);
            }
        }
    }
    pub(crate) fn apply(&mut self, event: LiveEvent) {
        if event.flags & 1 == 0 || event.thread_id.is_empty() {
            return;
        }
        if event.generation != self.generation {
            *self = Self {
                generation: event.generation,
                ..Self::default()
            };
        }
        if event.sequence <= self.sequence {
            return;
        }
        self.sequence = event.sequence;
        // Keep the control frame below its 16 KiB protocol bound. This is the
        // recent observed working set, not another permanent thread catalog.
        self.reserve_thread(&event.thread_id);
        self.revision = self.revision.saturating_add(1);
        let row = self
            .threads
            .entry(event.thread_id)
            .or_insert_with(|| ThreadState {
                state: "unknown",
                ..Default::default()
            });
        row.sequence = self.revision;
        row.last_live_sequence = event.sequence;
        row.observed_at_ms = event.observed_at_ms;
        // Replies to a retired turn cannot move the current thread back to it.
        if event.kind <= 6 {
            if let Some(turn) = event.turn_id {
                if row.turn_id.as_ref().is_some_and(|current| current != &turn) {
                    row.pending.clear();
                    row.snapshot = None;
                }
                row.turn_id = Some(turn);
            }
        }
        let lifecycle = match event.lifecycle {
            1 => Some("not_loaded"),
            2 => Some("idle"),
            3 | 8 => Some("failed"),
            4 | 5 => Some("running"),
            6 => Some("completed"),
            7 => Some("cancelled"),
            _ => None,
        };
        if let Some(state) = lifecycle {
            row.state = state;
        }
        match event.kind {
            3 => {
                row.pending.clear();
                row.snapshot = None;
            }
            1 if event.flags & 2048 != 0 => {
                row.snapshot = Some(event.attention & 3);
                if event.attention == 0 {
                    row.pending.clear();
                }
            }
            4..=6 => {
                if let Some(key) = event.request_key {
                    // A nonblocking input card is not a blocked conversation.
                    let attention =
                        if event.kind == 5 && event.flags & 16 != 0 && event.flags & 32 == 0 {
                            0
                        } else {
                            event.attention & 3
                        };
                    row.pending.insert(key, attention);
                }
            }
            7 | 8 if event.flags & 64 != 0 => {
                if let Some(key) = event.request_key {
                    if row.pending.remove(&key).is_some() {
                        row.snapshot = None;
                    }
                }
            }
            _ => {}
        }
    }
    pub(crate) fn gap(&mut self, dropped: u32) {
        if dropped > self.remote_drops {
            self.dropped = self.dropped.saturating_add(dropped - self.remote_drops);
            self.remote_drops = dropped;
            self.invalidate();
        }
    }
    pub(crate) fn invalidate(&mut self) {
        for row in self.threads.values_mut() {
            row.state = "unknown";
            row.snapshot = None;
            row.pending.clear();
        }
    }
    pub(crate) fn snapshot(&self, connected: bool) -> Value {
        if !connected {
            return unavailable(false);
        }
        let mut rows: Vec<_> = self.threads.iter().collect();
        rows.sort_by_key(|(_, row)| std::cmp::Reverse(row.sequence));
        let items:Vec<_>=rows.into_iter().map(|(thread,row)| {
            let bits=row.pending.values().fold(row.snapshot.unwrap_or(0),|a,b|a|b);
            let attention=match bits {1=>"approval",2=>"input",3=>"approval_and_input",_=>if row.snapshot==Some(0){"none"}else{"unknown"}};
            json!({"threadId":thread,"turnId":row.turn_id,"state":row.state,"attention":attention,"observedAtMs":row.observed_at_ms,"sequence":row.sequence})
        }).collect();
        json!({"liveVersion":1,"connected":true,"coverage":"partial","initialGap":true,"dropped":self.dropped,"generation":self.generation,"items":items})
    }
}
pub(crate) fn unavailable(connected: bool) -> Value {
    json!({"liveVersion":1,"connected":connected,"coverage":if connected {"partial"}else{"unavailable"},
        "initialGap":true,"dropped":0,"generation":0,"items":[]})
}
pub(crate) fn execute(payload: Value) -> Result<Value, String> {
    if payload.as_object().is_none_or(|v| v.len() != 1) || payload["action"] != "status" {
        return Err("global_invalid_request".into());
    }
    #[cfg(windows)]
    {
        Ok(crate::desktop_runtime_client::live_snapshot())
    }
    #[cfg(not(windows))]
    {
        Ok(unavailable(false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn event(
        sequence: u64,
        kind: u32,
        lifecycle: u32,
        attention: u32,
        flags: u32,
        key: Option<&str>,
    ) -> LiveEvent {
        LiveEvent {
            generation: 1,
            sequence,
            observed_at_ms: sequence * 1000,
            kind,
            lifecycle,
            attention,
            flags: flags | 1,
            request_key: key.map(str::to_owned),
            thread_id: "thread-A".into(),
            turn_id: Some("turn-A".into()),
        }
    }
    fn row(store: &LiveStore) -> Value {
        store.snapshot(true)["items"][0].clone()
    }
    fn metadata(status: u32, watermark: u64) -> crate::runtime_bootstrap::ThreadSnapshot {
        crate::runtime_bootstrap::ThreadSnapshot {
            stamp: crate::runtime_bootstrap::MetadataStamp {
                generation: 1,
                sequence: 999,
                observed_at_ms: 9000,
            },
            thread_id: "thread-A".into(),
            status,
            attention: if status == 4 { 1 } else { 0 },
            live_watermark: watermark,
        }
    }
    #[test]
    fn bootstrap_snapshot_fills_preexisting_wait_without_claiming_idle_completed() {
        let mut store = LiveStore::default();
        store.apply_snapshot(metadata(4, 0));
        assert_eq!(row(&store)["state"], "running");
        assert_eq!(row(&store)["attention"], "approval");
        store.apply_snapshot(metadata(2, 0));
        assert_eq!(row(&store)["state"], "idle");
        assert_eq!(row(&store)["attention"], "none");
        assert_eq!(store.snapshot(true)["initialGap"], true);
    }
    #[test]
    fn bootstrap_snapshot_cannot_override_newer_live_or_advance_its_sequence_domain() {
        let mut store = LiveStore::default();
        store.apply(event(1, 3, 8, 0, 0, None));
        store.apply_snapshot(metadata(2, 0));
        assert_eq!(row(&store)["state"], "failed");
        store.apply_snapshot(metadata(2, 1));
        assert_eq!(row(&store)["state"], "idle");
        store.apply(event(2, 2, 5, 0, 0, None));
        assert_eq!(row(&store)["state"], "running");
        assert_eq!(store.watermark(), 2);
    }
    #[test]
    fn live_store_lifecycle_keeps_failure_and_cancel_distinct_and_deduplicates() {
        let mut store = LiveStore::default();
        store.apply(event(1, 2, 5, 0, 0, None));
        assert_eq!(row(&store)["state"], "running");
        store.apply(event(2, 3, 7, 0, 0, None));
        assert_eq!(row(&store)["state"], "cancelled");
        store.apply(event(3, 3, 8, 0, 0, None));
        store.apply(event(2, 3, 6, 0, 0, None));
        assert_eq!(row(&store)["state"], "failed");
        assert_eq!(store.snapshot(true)["items"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn live_store_exact_reply_only_clears_matching_attention_without_inventing_none() {
        let mut store = LiveStore::default();
        store.apply(event(1, 4, 0, 1, 2, Some("n:17")));
        store.apply(event(2, 5, 0, 2, 2 | 16 | 32, Some("s:input")));
        assert_eq!(row(&store)["attention"], "approval_and_input");
        store.apply(event(3, 7, 0, 0, 64, Some("s:17")));
        assert_eq!(row(&store)["attention"], "approval_and_input");
        store.apply(event(4, 7, 0, 0, 64, Some("n:17")));
        assert_eq!(row(&store)["attention"], "input");
        store.apply(event(5, 8, 0, 0, 64, Some("s:input")));
        assert_eq!(row(&store)["attention"], "unknown");
        store.apply(event(6, 1, 2, 0, 2048, None));
        assert_eq!(row(&store)["attention"], "none");
        assert_eq!(row(&store)["state"], "idle");
    }
    #[test]
    fn live_store_nonblocking_input_does_not_claim_waiting_and_new_generation_clears_old() {
        let mut store = LiveStore::default();
        store.apply(event(1, 5, 0, 2, 2 | 16, Some("n:18")));
        assert_eq!(row(&store)["attention"], "unknown");
        store.apply(event(2, 1, 4, 1, 2048, None));
        assert_eq!(row(&store)["attention"], "approval");
        store.gap(1);
        assert_eq!(row(&store)["attention"], "unknown");
        let mut next = event(1, 1, 4, 0, 2048, None);
        next.generation = 2;
        next.thread_id = "thread-B".into();
        store.apply(next);
        assert_eq!(row(&store)["threadId"], "thread-B");
        assert_eq!(store.snapshot(true)["initialGap"], true);
    }
    #[test]
    fn live_store_cancelled_turn_cannot_leave_approval_on_next_turn() {
        let mut store = LiveStore::default();
        store.apply(event(1, 4, 0, 1, 2, Some("n:17")));
        store.apply(event(2, 3, 7, 0, 0, None));
        let mut next = event(3, 2, 5, 0, 0, None);
        next.turn_id = Some("turn-B".into());
        store.apply(next);
        assert_eq!(row(&store)["state"], "running");
        assert_eq!(
            row(&store)["attention"],
            "unknown",
            "A's retired approval must not appear as B's wait"
        );
    }
}
