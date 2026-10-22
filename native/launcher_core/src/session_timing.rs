use serde_json::{json, Value};
use std::collections::BTreeMap;

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
    pub fn report(&self, duration: Option<u64>, output: Option<u64>) -> Value {
        // Epoch-second bounds have up to 999 ms quantization error. Never claim
        // they identify response generation boundaries or first visible text.
        let bounds = self.start.zip(self.end).and_then(|(s, e)| {
            let a = s.checked_mul(1000)?;
            let b = e.checked_add(1)?.checked_mul(1000)?;
            let span = e.checked_sub(s)?.checked_mul(1000)?;
            if duration?.abs_diff(span) > 999 {
                return None;
            }
            Some((a, b))
        });
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
            let category = match item.kind.as_str() {
                "AgentMessage" => 0,
                "Reasoning" => 1,
                "CommandExecution" | "McpToolCall" | "FileChange" | "DynamicToolCall"
                | "CollabToolCall" => 2,
                _ => 3,
            };
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
        json!({"source":"local_item_completed", "responseCount":self.responses.len(), "responseOutputTokens":if self.responses.is_empty(){None}else{sum}, "usageMatchesTurn":agreement, "recentResponses":recent,
            "messageMs":group_ms[0],"reasoningMs":group_ms[1],"toolMs":group_ms[2],"otherMs":group_ms[3],
            "observedMs":if valid_count>0{Some(observed)}else{None},
            "overlapMs":if valid_count>0{group_sum.map(|sum| sum.saturating_sub(observed))}else{None},
            "unclassifiedMs":if coverage_valid{duration.map(|d|d-observed)}else{None},
            "boundsValid":bounds.is_some(),"coverageValid":coverage_valid,"boundsResolutionMs":1000,
            "validItems":valid_count,"invalidItems":invalid,"zeroItems":zero,"outOfBoundsItems":outside,"missingIdentityRecords":self.missing_ids,"truncated":self.truncated,
            "partial":!coverage_valid || group_sum.is_none() || invalid>0 || outside>0 || self.truncated || self.missing_ids>0,
            "streamingAvailable":false,"generationTokensPerSecond":null})
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn item(t: &mut Timing, id: &str, kind: &str, a: u64, b: u64) {
        t.accept("item_completed",&json!({"item":{"id":id,"type":kind,"content":"PRIVATE"},"started_at_ms":a,"completed_at_ms":b}),1);
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
