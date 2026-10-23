//! Privacy-safe projection of persisted item timestamps onto conservative turn bounds.
use serde_json::{json, Value};

const DISPLAY_LIMIT: usize = 200;

// The caller supplies only fields required by this projection. Item content is
// deliberately absent; IDs are borrowed solely for deterministic tie-breaking.
pub(super) struct Record<'a> {
    pub id: &'a str,
    pub kind: &'a str,
    pub start: Option<u64>,
    pub end: Option<u64>,
}

pub(super) fn category_index(kind: &str) -> usize {
    match kind {
        "AgentMessage" => 0,
        "Reasoning" => 1,
        "CommandExecution" | "McpToolCall" | "FileChange" | "DynamicToolCall"
        | "CollabToolCall" => 2,
        _ => 3,
    }
}

pub(super) fn project<'a>(
    bounds: Option<(u64, u64)>,
    source_partial: bool,
    records: impl Iterator<Item = Record<'a>>,
) -> Value {
    let mut records: Vec<_> = records.collect();
    records.sort_by_key(|r| (r.start.is_none(), r.start, r.end.is_none(), r.end, r.id));
    let total = records.len();
    let items: Vec<_> = records
        .into_iter()
        .take(DISPLAY_LIMIT)
        .enumerate()
        .map(|(index, record)| {
            let mut reasons = Vec::new();
            if record.start.is_none() {
                reasons.push("missing_start");
            }
            if record.end.is_none() {
                reasons.push("missing_end");
            }
            let duration = record.start.zip(record.end).and_then(|(a, b)| {
                if b < a {
                    reasons.push("reversed");
                } else if b == a {
                    reasons.push("zero_duration");
                }
                b.checked_sub(a)
            });
            let offsets = match bounds {
                None => {
                    reasons.push("missing_turn_bounds");
                    None
                }
                Some((start, end)) => record.start.zip(record.end).and_then(|(a, b)| {
                    if a < start || a > end || b < start || b > end {
                        reasons.push("outside_bounds");
                        return None;
                    }
                    if b < a {
                        return None;
                    }
                    Some((a.checked_sub(start)?, b.checked_sub(start)?))
                }),
            };
            let category = ["message", "reasoning", "tool", "other"][category_index(record.kind)];
            json!({
                "ordinal":index + 1,"category":category,
                "startedAtMs":record.start,"completedAtMs":record.end,
                "offsetStartMs":offsets.map(|(a,_)|a),
                "offsetEndMs":offsets.map(|(_,b)|b),
                "durationMs":duration,
                "drawable":offsets.is_some() && duration.is_some_and(|d|d>0),
                "reasons":reasons
            })
        })
        .collect();
    let shown = items.len();
    json!({
        "version":1,"coordinateKind":"logged_turn_window",
        "startEpochMs":bounds.map(|(a,_)|a),
        "endEpochMsExclusive":bounds.map(|(_,b)|b),
        "spanMs":bounds.and_then(|(a,b)|b.checked_sub(a)),
        "boundsResolutionMs":1000,"limit":DISPLAY_LIMIT,"order":"start_end_id",
        "totalItems":total,"shownItems":shown,"omittedItems":total-shown,
        "sourcePartial":source_partial,
        "coverageInterpretation":if bounds.is_some() && !source_partial && total == shown {"approximate"} else {"unavailable"},
        "items":items
    })
}
