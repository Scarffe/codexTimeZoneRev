use serde_json::{json, Value};
use std::collections::BTreeMap;

#[path = "session_timeline.rs"]
mod session_timeline;

const LIMIT: usize = 10_000;
#[derive(Default)]
pub(super) struct Timing {
    items: BTreeMap<String, Item>,
    responses: BTreeMap<String, (Option<u64>, Option<u64>, u64)>,
    start: Option<u64>,
    end: Option<u64>,
    terminal_seen: bool,
    pub conflicting_item: bool,
    pub conflicting_usage: bool,
    pub truncated: bool,
    missing_ids: u64,
}
#[derive(PartialEq)]
struct Item {
    identity_content: Value,
    kind: String,
    start: Option<u64>,
    end: Option<u64>,
}
fn union(intervals: &mut [(u64, u64)]) -> u64 {
    intervals.sort_unstable();
    let mut span = None;
    let mut total = 0;
    for &(a, b) in intervals.iter() {
        match span {
            Some((s, e)) if a <= e => span = Some((s, e.max(b))),
            Some((s, e)) => {
                total += e - s;
                span = Some((a, b));
            }
            None => span = Some((a, b)),
        }
    }
    if let Some((s, e)) = span {
        total += e - s;
    }
    total
}
impl Timing {
    pub fn accept(&mut self, kind: &str, p: &Value, serial: u64) {
        match kind {
            "task_complete" => {
                if !self.terminal_seen {
                    self.start = p["started_at"].as_u64();
                    self.end = p["completed_at"].as_u64();
                    self.terminal_seen = true;
                }
            }
            "turn_aborted" => self.terminal_seen = true,
            "token_usage_record" => {
                if let Some(id) = p["response_id"].as_str().filter(|s| !s.is_empty()) {
                    let row = (
                        p["usage"]["output_tokens"].as_u64(),
                        p["usage"]["reasoning_output_tokens"].as_u64(),
                        serial,
                    );
                    if let Some(old) = self.responses.get(id) {
                        self.conflicting_usage |= old.0 != row.0 || old.1 != row.1;
                    } else if self.responses.len() < LIMIT {
                        self.responses.insert(
                            id.into(),
                            (
                                p["usage"]["output_tokens"].as_u64(),
                                p["usage"]["reasoning_output_tokens"].as_u64(),
                                serial,
                            ),
                        );
                    } else {
                        self.truncated = true;
                    }
                } else {
                    self.missing_ids += 1;
                }
            }
            "item_completed" => {
                let item = &p["item"];
                if item["type"] == "UserMessage" {
                    return;
                }
                if let Some(id) = item["id"].as_str().filter(|s| !s.is_empty()) {
                    let row = Item {
                        identity_content: item.clone(),
                        kind: item["type"].as_str().unwrap_or("Unknown").into(),
                        start: p["started_at_ms"].as_u64(),
                        end: p["completed_at_ms"].as_u64(),
                    };
                    if let Some(old) = self.items.get(id) {
                        self.conflicting_item |= old != &row;
                    } else if self.items.len() < LIMIT {
                        self.items.insert(id.into(), row);
                    } else {
                        self.truncated = true;
                    }
                } else {
                    self.missing_ids += 1;
                }
            }
            _ => {}
        }
    }
    fn bounds(&self, duration: Option<u64>) -> Option<(u64, u64)> {
        // Epoch-second bounds have up to 999 ms quantization error. Never claim
        // they identify response generation boundaries or first visible text.
        self.start.zip(self.end).and_then(|(s, e)| {
            let a = s.checked_mul(1000)?;
            let b = e.checked_add(1)?.checked_mul(1000)?;
            let span = e.checked_sub(s)?.checked_mul(1000)?;
            if duration?.abs_diff(span) > 999 {
                return None;
            }
            Some((a, b))
        })
    }
    pub fn bounds_valid(&self, duration: Option<u64>) -> bool {
        self.bounds(duration).is_some()
    }
    pub fn report(&self, duration: Option<u64>, output: Option<u64>) -> Value {
        let bounds = self.bounds(duration);
        let mut groups: [Vec<(u64, u64)>; 4] = Default::default();
        let mut invalid = 0;
        let mut zero = 0;
        let mut outside = 0;
        for item in self.items.values() {
            let Some((a, b)) = item.start.zip(item.end) else {
                invalid += 1;
                continue;
            };
            if b < a {
                invalid += 1;
                continue;
            }
            if b == a {
                zero += 1;
                continue;
            }
            if bounds.is_some_and(|(s, e)| a < s || b > e) {
                outside += 1;
                continue;
            }
            let category = session_timeline::category_index(&item.kind);
            groups[category].push((a, b));
        }
        let mut all: Vec<_> = groups.iter().flatten().copied().collect();
        let valid_count = all.len();
        let observed = union(&mut all);
        let group_ms: Vec<_> = groups
            .iter_mut()
            .map(|g| if g.is_empty() { None } else { Some(union(g)) })
            .collect();
        let group_sum = group_ms
            .iter()
            .flatten()
            .try_fold(0u64, |sum, n| sum.checked_add(*n));
        let coverage_valid =
            bounds.is_some() && valid_count > 0 && duration.is_some_and(|d| observed <= d);
        let mut responses: Vec<_> = self.responses.iter().collect();
        responses.sort_by_key(|(_, (_, _, order))| *order);
        let sum = self
            .responses
            .values()
            .try_fold(0u64, |sum, (n, _, _)| sum.checked_add((*n)?));
        let agreement = if self.responses.is_empty()
            || self.truncated
            || self.missing_ids > 0
            || self.conflicting_usage
        {
            None
        } else {
            sum.zip(output).map(|(a, b)| a == b)
        };
        let recent:Vec<_>=responses.iter().rev().take(12).map(|(id,(out,reason,_))|json!({"responseId":id,"outputTokens":out,"reasoningTokens":reason})).collect();
        let partial = !coverage_valid
            || group_sum.is_none()
            || invalid > 0
            || outside > 0
            || self.truncated
            || self.missing_ids > 0;
        let timeline = session_timeline::project(
            bounds,
            partial || self.conflicting_item || self.conflicting_usage,
            self.items
                .iter()
                .map(|(id, item)| session_timeline::Record {
                    id,
                    kind: &item.kind,
                    start: item.start,
                    end: item.end,
                }),
        );
        json!({"source":"local_item_completed", "responseCount":self.responses.len(), "responseOutputTokens":if self.responses.is_empty(){None}else{sum}, "usageMatchesTurn":agreement, "recentResponses":recent,
            "messageMs":group_ms[0],"reasoningMs":group_ms[1],"toolMs":group_ms[2],"otherMs":group_ms[3],
            "observedMs":if valid_count>0{Some(observed)}else{None},
            "overlapMs":if valid_count>0{group_sum.map(|sum| sum.saturating_sub(observed))}else{None},
            "unclassifiedMs":if coverage_valid{duration.map(|d|d-observed)}else{None},
            "boundsValid":bounds.is_some(),"coverageValid":coverage_valid,"boundsResolutionMs":1000,
            "validItems":valid_count,"invalidItems":invalid,"zeroItems":zero,"outOfBoundsItems":outside,"missingIdentityRecords":self.missing_ids,"truncated":self.truncated,
            "partial":partial,"timeline":timeline,
            "streamingAvailable":false,"generationTokensPerSecond":null})
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn item(t: &mut Timing, id: &str, kind: &str, a: u64, b: u64) {
        t.accept("item_completed",&json!({"item":{"id":id,"type":kind,"content":"PRIVATE"},"started_at_ms":a,"completed_at_ms":b}),1);
    }
    fn timeline_turn() -> Timing {
        let mut t = Timing::default();
        t.accept(
            "task_complete",
            &json!({"started_at":100,"completed_at":110}),
            0,
        );
        t
    }
    #[test]
    fn timeline_quantized_axis_keeps_actual_h2_duration_and_private_rows() {
        let mut t = timeline_turn();
        item(&mut t, "PRIVATE-message", "AgentMessage", 103000, 108000);
        item(&mut t, "PRIVATE-reason", "Reasoning", 101000, 104000);
        item(&mut t, "PRIVATE-tool", "CommandExecution", 102000, 106000);
        let a = t.report(Some(10000), None);
        for (key, want) in [
            ("messageMs", 5000),
            ("reasoningMs", 3000),
            ("toolMs", 4000),
            ("observedMs", 7000),
            ("overlapMs", 5000),
            ("unclassifiedMs", 3000),
        ] {
            assert_eq!(a[key], want, "{key}");
        }
        let v = &a["timeline"];
        assert_eq!(v["version"], 1);
        assert_eq!(v["coordinateKind"], "logged_turn_window");
        assert_eq!(v["startEpochMs"], 100000);
        assert_eq!(v["endEpochMsExclusive"], 111000);
        assert_eq!(v["spanMs"], 11000);
        assert_eq!(v["boundsResolutionMs"], 1000);
        assert_eq!(v["sourcePartial"], false);
        assert_eq!(v["coverageInterpretation"], "approximate");
        assert_eq!(
            v["items"],
            json!([
                {"ordinal":1,"category":"reasoning","startedAtMs":101000,"completedAtMs":104000,"offsetStartMs":1000,"offsetEndMs":4000,"durationMs":3000,"drawable":true,"reasons":[]},
                {"ordinal":2,"category":"tool","startedAtMs":102000,"completedAtMs":106000,"offsetStartMs":2000,"offsetEndMs":6000,"durationMs":4000,"drawable":true,"reasons":[]},
                {"ordinal":3,"category":"message","startedAtMs":103000,"completedAtMs":108000,"offsetStartMs":3000,"offsetEndMs":8000,"durationMs":5000,"drawable":true,"reasons":[]}
            ])
        );
        assert!(!v.to_string().contains("PRIVATE"));
    }
    #[test]
    fn timeline_chronological_ties_use_end_then_full_id_without_exposing_ids() {
        let mut t = timeline_turn();
        item(&mut t, "PRIVATE-z", "Reasoning", 102000, 103000);
        item(&mut t, "PRIVATE-a", "AgentMessage", 102000, 103000);
        item(&mut t, "PRIVATE-b", "Unknown", 102000, 102500);
        t.accept("item_completed", &json!({"item":{"id":"PRIVATE-missing","type":"AgentMessage"},"completed_at_ms":104000}), 1);
        let a = t.report(Some(10000), None);
        let rows = a["timeline"]["items"].as_array().unwrap();
        assert_eq!(
            rows.iter()
                .map(|r| r["category"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["other", "message", "reasoning", "message"]
        );
        assert_eq!(rows[3]["ordinal"], 4);
        assert_eq!(rows[3]["reasons"], json!(["missing_start"]));
        assert!(!a["timeline"].to_string().contains("PRIVATE"));
    }
    #[test]
    fn timeline_invalid_rows_remain_facts_and_never_clamp_into_bars() {
        let mut t = timeline_turn();
        item(&mut t, "outside", "FileChange", 99000, 102000);
        item(&mut t, "zero", "DynamicToolCall", 101000, 101000);
        item(&mut t, "reverse", "CollabToolCall", 103000, 102000);
        t.accept(
            "item_completed",
            &json!({"item":{"id":"no-end","type":"Reasoning"},"started_at_ms":104000}),
            1,
        );
        t.accept(
            "item_completed",
            &json!({"item":{"id":"no-both","type":"Unknown"}}),
            1,
        );
        let a = t.report(Some(10000), None);
        let rows = a["timeline"]["items"].as_array().unwrap();
        assert!(rows.iter().all(|r| r["drawable"] == false));
        assert_eq!(rows[0]["startedAtMs"], 99000);
        assert!(rows[0]["offsetStartMs"].is_null());
        assert!(rows[0]["offsetEndMs"].is_null());
        assert_eq!(rows[0]["durationMs"], 3000);
        assert_eq!(rows[0]["reasons"], json!(["outside_bounds"]));
        assert_eq!(rows[1]["offsetStartMs"], 1000);
        assert_eq!(rows[1]["durationMs"], 0);
        assert_eq!(rows[1]["reasons"], json!(["zero_duration"]));
        assert!(rows[2]["durationMs"].is_null());
        assert_eq!(rows[2]["reasons"], json!(["reversed"]));
        assert_eq!(rows[3]["reasons"], json!(["missing_end"]));
        assert_eq!(rows[4]["reasons"], json!(["missing_start", "missing_end"]));
        assert_eq!(a["timeline"]["coverageInterpretation"], "unavailable");
    }
    #[test]
    fn timeline_missing_reversed_overflow_and_mismatched_bounds_fail_closed() {
        for (start, end, duration) in [
            (None, None, Some(10000)),
            (Some(110), Some(100), Some(10000)),
            (Some(u64::MAX), Some(u64::MAX), Some(0)),
            (Some(u64::MAX / 1000), Some(u64::MAX / 1000), Some(0)),
            (Some(100), Some(110), Some(9000)),
            (Some(100), Some(110), None),
        ] {
            let mut t = Timing::default();
            t.accept(
                "task_complete",
                &json!({"started_at":start,"completed_at":end}),
                0,
            );
            item(&mut t, "a", "AgentMessage", 101000, 102000);
            let a = t.report(duration, None);
            let v = &a["timeline"];
            assert_eq!(a["boundsValid"], false);
            assert!(v["startEpochMs"].is_null());
            assert!(v["endEpochMsExclusive"].is_null());
            assert!(v["spanMs"].is_null());
            assert_eq!(v["items"][0]["drawable"], false);
            assert!(v["items"][0]["offsetStartMs"].is_null());
            assert!(v["items"][0]["offsetEndMs"].is_null());
            assert_eq!(v["items"][0]["durationMs"], 1000);
            assert_eq!(v["items"][0]["reasons"], json!(["missing_turn_bounds"]));
            assert_eq!(v["coverageInterpretation"], "unavailable");
        }
        for duration in [9001, 10000, 10999] {
            assert_eq!(
                timeline_turn().report(Some(duration), None)["boundsValid"],
                true
            );
        }
    }
    #[test]
    fn timeline_zero_actual_duration_still_has_a_quantized_window() {
        let mut t = Timing::default();
        t.accept(
            "task_complete",
            &json!({"started_at":100,"completed_at":100}),
            0,
        );
        item(&mut t, "zero", "AgentMessage", 100000, 100000);
        let a = t.report(Some(0), None);
        assert_eq!(a["boundsValid"], true);
        assert_eq!(a["timeline"]["spanMs"], 1000);
        assert_eq!(a["timeline"]["items"][0]["durationMs"], 0);
        assert_eq!(a["timeline"]["items"][0]["drawable"], false);
    }
    #[test]
    fn timeline_display_limit_preserves_full_h2_union() {
        let mut t = timeline_turn();
        for n in (0..201).rev() {
            item(
                &mut t,
                &format!("PRIVATE-{n}"),
                "AgentMessage",
                100000 + n * 10,
                100010 + n * 10,
            );
        }
        let a = t.report(Some(10000), None);
        let v = &a["timeline"];
        assert_eq!(a["messageMs"], 2010);
        assert_eq!(a["observedMs"], 2010);
        assert_eq!(a["unclassifiedMs"], 7990);
        assert_eq!(v["limit"], 200);
        assert_eq!(v["order"], "start_end_id");
        assert_eq!(v["totalItems"], 201);
        assert_eq!(v["shownItems"], 200);
        assert_eq!(v["omittedItems"], 1);
        assert_eq!(v["items"].as_array().unwrap().len(), 200);
        assert_eq!(v["items"][199]["offsetEndMs"], 2000);
        assert_eq!(v["items"][199]["ordinal"], 200);
        assert_eq!(v["sourcePartial"], false);
        assert_eq!(v["coverageInterpretation"], "unavailable");
    }
    #[test]
    fn timeline_conflict_truncation_and_missing_identity_are_partial() {
        for cause in ["item", "usage", "truncated", "identity"] {
            let mut t = timeline_turn();
            item(&mut t, "a", "AgentMessage", 101000, 102000);
            match cause {
                "item" => item(&mut t, "a", "AgentMessage", 101000, 103000),
                "usage" => {
                    t.accept(
                        "token_usage_record",
                        &json!({"response_id":"r","usage":{"output_tokens":1}}),
                        1,
                    );
                    t.accept(
                        "token_usage_record",
                        &json!({"response_id":"r","usage":{"output_tokens":2}}),
                        2,
                    );
                }
                "truncated" => {
                    for n in 0..=10_000 {
                        t.accept(
                            "token_usage_record",
                            &json!({"response_id":format!("r-{n}"),"usage":{"output_tokens":1}}),
                            n,
                        );
                    }
                }
                _ => t.accept(
                    "item_completed",
                    &json!({"item":{"type":"AgentMessage"}}),
                    1,
                ),
            }
            let a = t.report(Some(10000), None);
            assert_eq!(a["timeline"]["sourcePartial"], true, "{cause}");
            assert_eq!(
                a["timeline"]["coverageInterpretation"], "unavailable",
                "{cause}"
            );
        }
    }
    #[test]
    fn overlap_dedup_and_response_reconciliation() {
        let mut t = Timing::default();
        t.accept(
            "task_complete",
            &json!({"started_at":1,"completed_at":11}),
            0,
        );
        item(&mut t, "a", "CommandExecution", 1000, 5000);
        item(&mut t, "b", "McpToolCall", 3000, 6000);
        item(&mut t, "a", "CommandExecution", 1000, 5000);
        item(&mut t, "c", "Reasoning", 5000, 7000);
        item(&mut t, "d", "AgentMessage", 7000, 8000);
        for serial in [1, 2] {
            t.accept("token_usage_record",&json!({"response_id":"r","usage":{"output_tokens":20,"reasoning_output_tokens":5}}),serial);
        }
        let v = t.report(Some(10000), Some(20));
        assert_eq!(v["toolMs"], 5000);
        assert_eq!(v["observedMs"], 7000);
        assert_eq!(v["overlapMs"], 1000);
        assert_eq!(v["unclassifiedMs"], 3000);
        assert_eq!(v["responseCount"], 1);
        assert_eq!(v["usageMatchesTurn"], true);
        assert_eq!(v["partial"], false);
        assert!(v["generationTokensPerSecond"].is_null());
        assert!(!v.to_string().contains("PRIVATE"));
    }
    #[test]
    fn invalid_missing_zero_and_bounds_do_not_create_generation_time() {
        let mut t = Timing::default();
        item(&mut t, "a", "AgentMessage", 5, 5);
        item(&mut t, "b", "Reasoning", 20, 10);
        t.accept(
            "item_completed",
            &json!({"item":{"id":"c","type":"Unknown"}}),
            0,
        );
        let v = t.report(Some(100), None);
        assert!(v["unclassifiedMs"].is_null());
        assert!(v["toolMs"].is_null());
        assert_eq!(v["zeroItems"], 1);
        assert_eq!(v["invalidItems"], 2);
        assert_eq!(v["partial"], true);
        t.accept(
            "task_complete",
            &json!({"started_at":1,"completed_at":2}),
            0,
        );
        item(&mut t, "d", "AgentMessage", 4000, 4100);
        let v = t.report(Some(1000), None);
        assert_eq!(v["outOfBoundsItems"], 1);
        assert_eq!(v["coverageValid"], false);
    }
    #[test]
    fn absent_old_schema_and_mismatched_usage_are_explicit() {
        let mut t = Timing::default();
        let v = t.report(Some(2000), Some(20));
        assert!(v["observedMs"].is_null());
        assert!(v["usageMatchesTurn"].is_null());
        t.accept(
            "token_usage_record",
            &json!({"response_id":"r","usage":{"output_tokens":19}}),
            1,
        );
        assert_eq!(t.report(None, Some(20))["usageMatchesTurn"], false);
    }
}
