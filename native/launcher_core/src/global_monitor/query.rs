use super::*;
use reduce::{Fact, Tokens};

struct Query {
    from: Option<u64>,
    to: Option<u64>,
    edges: Vec<u64>,
    project: Option<String>,
    model: Option<String>,
    status: Option<String>,
    search: Option<String>,
    sort: String,
    offset: usize,
    limit: usize,
}
impl Query {
    fn parse(v: &Value) -> Result<Self, String> {
        checked_request(
            v,
            &[
                "action",
                "fromMs",
                "toMs",
                "dayEdgesMs",
                "project",
                "model",
                "status",
                "search",
                "sort",
                "offset",
                "limit",
                "expectedRevision",
            ],
        )?;
        let from = number(v, "fromMs")?;
        let to = number(v, "toMs")?;
        if from.zip(to).is_some_and(|(a, b)| a >= b) {
            return Err("global_invalid_range".into());
        }
        let edges = match v.get("dayEdgesMs") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(a)) if a.len() <= 94 => a
                .iter()
                .map(|n| n.as_u64().ok_or("global_invalid_range".to_owned()))
                .collect::<Result<Vec<_>, _>>()?,
            _ => return Err("global_invalid_range".into()),
        };
        if edges.len() == 1 || edges.windows(2).any(|w| w[0] >= w[1]) {
            return Err("global_invalid_range".into());
        }
        let field = |key: &str| -> Result<Option<String>, String> {
            match v.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(x) => text(x)
                    .map(Some)
                    .ok_or_else(|| "global_invalid_request".into()),
            }
        };
        let sort = field("sort")?.unwrap_or_else(|| "recent".into());
        if !matches!(sort.as_str(), "recent" | "tokens") {
            return Err("global_invalid_request".into());
        }
        let limit = number(v, "limit")?.unwrap_or(100);
        if !(1..=200).contains(&limit) {
            return Err("global_invalid_request".into());
        }
        let offset = usize::try_from(number(v, "offset")?.unwrap_or(0))
            .map_err(|_| "global_invalid_request")?;
        let status = field("status")?;
        if status.as_ref().is_some_and(|s| {
            !matches!(
                s.as_str(),
                "running" | "completed" | "cancelled" | "failed" | "unknown" | "all"
            )
        }) {
            return Err("global_invalid_request".into());
        }
        Ok(Self {
            from,
            to,
            edges,
            project: field("project")?,
            model: field("model")?,
            status,
            search: field("search")?.map(|s| s.to_lowercase()),
            sort,
            offset,
            limit: limit as usize,
        })
    }
    fn time(&self, time: Option<u64>) -> bool {
        if self.from.is_none() && self.to.is_none() {
            return true;
        }
        time.is_some_and(|t| self.from.is_none_or(|a| t >= a) && self.to.is_none_or(|b| t < b))
    }
    fn dimensions(&self, project: &str, model: &str) -> bool {
        self.project.as_ref().is_none_or(|p| p == project)
            && self.model.as_ref().is_none_or(|m| m == model)
    }
}
#[derive(Default)]
struct Bucket {
    tokens: Tokens,
    count: usize,
    threads: BTreeSet<String>,
    estimated: bool,
}
impl Bucket {
    fn add(&mut self, thread: &str, tokens: &Tokens, estimated: bool) {
        self.tokens.add(tokens, self.count == 0);
        self.count += 1;
        self.threads.insert(thread.to_owned());
        self.estimated |= estimated;
    }
    fn value(&self, key: &str, partial: bool) -> Value {
        json!({"key":key,"tokens":self.tokens,"sessions":self.threads.len(),"basis":if self.estimated{"mixed"}else{"identified_request"},"quality":if partial{"partial"}else if self.estimated{"estimated"}else if self.count==0{"unavailable"}else{"reported"}})
    }
}
struct Contribution {
    fact: Fact,
    project: String,
    model: String,
    estimated: bool,
}

fn current_tail(source: &Source) -> Option<&reduce::TailState> {
    source
        .tail
        .as_ref()
        .filter(|tail| tail.length == source.length)
}

impl Kernel {
    pub(super) fn query(&self, value: &Value) -> Result<Value, String> {
        let mut q = Query::parse(value)?;
        let coverage = self.coverage();
        let partial = coverage["complete"] != true || self.phase() == "partial";
        let expected = number(value, "expectedRevision")?;
        let changed = expected.is_some_and(|r| r != self.revision);
        let mut warnings: Vec<_> = self.store_error.iter().cloned().collect();
        if self.directory_errors > 0 {
            warnings.push("directory_unreadable".into());
        }
        if !self.discovery_done {
            warnings.push("catalog_discovery_incomplete".into());
        }
        let utc = q.edges.is_empty();
        let mut bucket_days = 1;
        if utc {
            let times: Vec<u64> = self
                .sources
                .values()
                .flat_map(|s| s.responses.values().chain(s.legacy.iter()))
                .filter_map(|f| f.time)
                .filter(|t| q.time(Some(*t)))
                .collect();
            let first = q.from.or_else(|| times.iter().copied().min());
            let last =
                q.to.or_else(|| times.iter().copied().max().and_then(|t| t.checked_add(1)));
            if let Some((first, last)) = first.zip(last).filter(|(a, b)| a < b) {
                const DAY: u64 = 86_400_000;
                let start = first / DAY * DAY;
                let end = (last.saturating_add(DAY - 1) / DAY).saturating_mul(DAY);
                let days = (end - start) / DAY;
                bucket_days = days.div_ceil(90).max(1);
                let step = bucket_days * DAY;
                q.edges.push(start);
                let mut edge = start;
                while edge < end {
                    edge = edge.saturating_add(step).min(end);
                    q.edges.push(edge);
                }
                if bucket_days > 1 {
                    warnings.push("daily_grouped_utc_days".into());
                }
            }
        }
        let mut snapshot = json!({"globalVersion":1,"revision":self.revision,"indexEpoch":self.index_epoch,"changed":changed,"phase":self.phase(),"observedAtMs":self.observed_at_ms,"restored":self.restored,"roots":self.roots,"rootsMode":if self.roots_explicit{"explicit"}else{"defaults"},"coverage":coverage,"quality":"unavailable","conflicts":0,"reasons":[],"totals":{},"daily":[],"dailyBasis":if utc{"utc"}else{"civil"},"dailyBucketDays":bucket_days,"dailyFromMs":q.edges.first(),"dailyToMs":q.edges.last(),"projects":[],"models":[],"sessions":[],"filteredCount":0,"offset":q.offset,"hasMore":false,"warnings":warnings});
        if changed {
            return Ok(snapshot);
        }
        let mut logical: BTreeMap<&str, Vec<&Source>> = BTreeMap::new();
        for source in self.sources.values().filter(|s| !s.thread_id.is_empty()) {
            logical.entry(&source.thread_id).or_default().push(source);
        }
        let mut rows = Vec::new();
        let mut totals = Bucket::default();
        let mut projects: BTreeMap<String, Bucket> = BTreeMap::new();
        let mut models: BTreeMap<String, Bucket> = BTreeMap::new();
        let mut daily: Vec<Bucket> = (0..q.edges.len().saturating_sub(1))
            .map(|_| Bucket::default())
            .collect();
        let mut states: BTreeMap<String, usize> =
            ["running", "completed", "cancelled", "failed", "unknown"]
                .into_iter()
                .map(|s| (s.into(), 0))
                .collect();
        let mut stale_running = 0;
        let mut excluded_conflicts = 0;
        let mut unknown_time = 0;
        for (thread, sources) in logical {
            let best = *sources
                .iter()
                .max_by_key(|s| {
                    (
                        s.source_state == "ok",
                        s.offset,
                        s.last_event_ms.unwrap_or(0),
                    )
                })
                .unwrap();
            let mut reasons: BTreeSet<String> = sources
                .iter()
                .flat_map(|s| s.reasons.iter().cloned())
                .collect();
            let lifecycle_gap = sources.iter().any(|s| {
                s.offset < s.length && current_tail(s).is_none_or(|t| t.latest_turn.is_none())
            });
            let latest = sources
                .iter()
                .flat_map(|s| {
                    if s.offset < s.length {
                        current_tail(s)
                            .and_then(|t| t.latest_turn.as_ref())
                            .into_iter()
                            .collect::<Vec<_>>()
                    } else {
                        s.turns.values().collect::<Vec<_>>()
                    }
                })
                .max_by_key(|t| (t.started_at.or(t.completed_at).unwrap_or(0), t.order));
            if lifecycle_gap {
                reasons.insert("lifecycle_backlog_unknown".into());
            }
            let observed_lifecycle = latest
                .filter(|_| !lifecycle_gap)
                .map(|t| {
                    if t.state.is_empty() {
                        "unknown"
                    } else {
                        t.state.as_str()
                    }
                })
                .unwrap_or("unknown");
            let mut contexts = BTreeMap::new();
            for source in &sources {
                for (turn, context) in &source.contexts {
                    contexts.entry(turn.as_str()).or_insert(context);
                }
            }
            let latest_context = contexts.values().max_by_key(|c| c.order);
            let project = latest_context
                .and_then(|c| c.project.clone())
                .or_else(|| best.project.clone());
            let model = latest_context.and_then(|c| c.model.clone());
            let last = sources
                .iter()
                .flat_map(|s| {
                    [
                        s.last_event_ms,
                        current_tail(s).and_then(|t| t.last_event_ms),
                    ]
                })
                .flatten()
                .max();
            let freshness = if sources.iter().all(|s| s.source_state == "missing") {
                "missing"
            } else if sources.iter().all(|s| s.source_state == "unreadable") {
                "unreadable"
            } else if sources.iter().any(|s| s.restored)
                || last.is_none_or(|t| self.observed_at_ms.saturating_sub(t) > 120_000)
            {
                "stale"
            } else {
                "fresh"
            };
            let unclosed_stale = observed_lifecycle == "running" && freshness != "fresh";
            let lifecycle = if unclosed_stale {
                reasons.insert("unclosed_task_stale".into());
                "unknown"
            } else {
                observed_lifecycle
            };
            if q.status
                .as_ref()
                .is_some_and(|s| s != "all" && s != lifecycle)
            {
                continue;
            }
            if let Some(search) = &q.search {
                let haystack = format!(
                    "{thread} {} {}",
                    project.as_deref().unwrap_or(""),
                    model.as_deref().unwrap_or("")
                )
                .to_lowercase();
                if !haystack.contains(search) {
                    continue;
                }
            }
            let mut requests: BTreeMap<String, Fact> = BTreeMap::new();
            let mut conflicts = BTreeSet::new();
            for source in &sources {
                conflicts.extend(source.conflicting_responses.iter().cloned());
                for (id, fact) in &source.responses {
                    if let Some(old) = requests.get_mut(id) {
                        if old.turn_id != fact.turn_id || old.tokens != fact.tokens {
                            conflicts.insert(id.clone());
                        } else {
                            old.time = reduce::earliest(old.time, fact.time);
                        }
                    } else {
                        requests.insert(id.clone(), fact.clone());
                    }
                }
            }
            excluded_conflicts += conflicts.len();
            let strong_turns: BTreeSet<_> = requests.values().map(|f| f.turn_id.clone()).collect();
            let mut contributions = Vec::new();
            let mut push = |fact: Fact, estimated: bool| {
                let context = contexts.get(fact.turn_id.as_str());
                let p = context
                    .and_then(|c| c.project.clone())
                    .or_else(|| best.project.clone())
                    .unwrap_or_else(|| "unknown".into());
                let m = context
                    .and_then(|c| c.model.clone())
                    .unwrap_or_else(|| "unknown".into());
                contributions.push(Contribution {
                    fact,
                    project: p,
                    model: m,
                    estimated,
                });
            };
            for (id, fact) in requests {
                if !conflicts.contains(&id) {
                    push(fact, false);
                }
            }
            let mut legacy_seen: BTreeMap<String, Fact> = BTreeMap::new();
            let mut legacy_conflicts = BTreeSet::new();
            for source in &sources {
                for fact in &source.legacy {
                    if source.child || source.parent_thread_id.is_some() {
                        reasons.insert("ambiguous_legacy_fork".into());
                        continue;
                    }
                    if strong_turns.contains(&fact.turn_id)
                        || fact.turn_id.is_empty() && !strong_turns.is_empty()
                    {
                        continue;
                    }
                    let Some(checkpoint) = &fact.checkpoint else {
                        reasons.insert("missing_legacy_checkpoint".into());
                        continue;
                    };
                    let key = serde_json::to_string(checkpoint).unwrap_or_default();
                    if let Some(old) = legacy_seen.get_mut(&key) {
                        if old.tokens != fact.tokens {
                            legacy_conflicts.insert(key);
                        } else {
                            old.time = reduce::earliest(old.time, fact.time);
                        }
                    } else {
                        legacy_seen.insert(key, fact.clone());
                    }
                }
            }
            excluded_conflicts += legacy_conflicts.len();
            for (key, fact) in legacy_seen {
                if !legacy_conflicts.contains(&key) {
                    push(fact, true);
                }
            }
            let relevant: Vec<_> = contributions
                .into_iter()
                .filter(|c| q.time(c.fact.time) && q.dimensions(&c.project, &c.model))
                .collect();
            let row_dimensions = q.dimensions(
                project.as_deref().unwrap_or("unknown"),
                model.as_deref().unwrap_or("unknown"),
            );
            if relevant.is_empty() && (!q.time(last) || !row_dimensions) {
                continue;
            }
            let mut row_bucket = Bucket::default();
            for c in relevant {
                row_bucket.add(thread, &c.fact.tokens, c.estimated);
                totals.add(thread, &c.fact.tokens, c.estimated);
                projects.entry(c.project.clone()).or_default().add(
                    thread,
                    &c.fact.tokens,
                    c.estimated,
                );
                models
                    .entry(c.model.clone())
                    .or_default()
                    .add(thread, &c.fact.tokens, c.estimated);
                if let Some(time) = c.fact.time {
                    for (index, edges) in q.edges.windows(2).enumerate() {
                        if time >= edges[0] && time < edges[1] {
                            daily[index].add(thread, &c.fact.tokens, c.estimated);
                            break;
                        }
                    }
                } else {
                    unknown_time += 1;
                }
            }
            if row_bucket.count == 0 {
                reasons.insert("missing_usage".into());
            }
            if last.is_none() {
                reasons.insert("missing_event_time".into());
            }
            if !conflicts.is_empty() || !legacy_conflicts.is_empty() {
                reasons.insert("conflicting_usage".into());
            }
            if best.offset < best.length {
                reasons.insert("incomplete_history".into());
            }
            let quality = if !conflicts.is_empty() || !legacy_conflicts.is_empty() {
                "conflict"
            } else if partial || !reasons.is_empty() {
                "partial"
            } else if row_bucket.estimated {
                "estimated"
            } else if row_bucket.count == 0 {
                "unavailable"
            } else {
                "reported"
            };
            let basis = if row_bucket.count == 0 {
                "none"
            } else if row_bucket.estimated && strong_turns.is_empty() {
                "legacy_cumulative_delta"
            } else if row_bucket.estimated {
                "mixed"
            } else {
                "identified_request"
            };
            *states.entry(lifecycle.into()).or_default() += 1;
            if unclosed_stale {
                stale_running += 1;
            }
            rows.push(json!({"path":best.path,"threadId":thread,"sessionId":best.session_id,"project":project,"model":model,"lifecycleState":lifecycle,"attentionState":"unknown","freshness":freshness,"lastEventMs":last,"tokens":row_bucket.tokens,"basis":basis,"quality":quality,"reasons":reasons,"canOpenDetail":!best.child&&best.source_state=="ok"&&catalog::strict_detail_supported(&best.path),"sourceState":best.source_state}));
        }
        if q.sort == "tokens" {
            rows.sort_by(|a, b| {
                b["tokens"]["totalTokens"]
                    .as_u64()
                    .unwrap_or(0)
                    .cmp(&a["tokens"]["totalTokens"].as_u64().unwrap_or(0))
                    .then_with(|| a["threadId"].as_str().cmp(&b["threadId"].as_str()))
            });
        } else {
            rows.sort_by(|a, b| {
                b["lastEventMs"]
                    .as_u64()
                    .unwrap_or(0)
                    .cmp(&a["lastEventMs"].as_u64().unwrap_or(0))
                    .then_with(|| a["threadId"].as_str().cmp(&b["threadId"].as_str()))
            });
        }
        let count = rows.len();
        let page: Vec<_> = rows.into_iter().skip(q.offset).take(q.limit).collect();
        let aggregate_partial = partial || excluded_conflicts > 0;
        let aggregate_quality = if aggregate_partial {
            "partial"
        } else if totals.estimated {
            "estimated"
        } else if totals.count == 0 {
            "unavailable"
        } else {
            "reported"
        };
        let mut aggregate_reasons = Vec::new();
        if partial {
            aggregate_reasons.push("incomplete_coverage");
        }
        if excluded_conflicts > 0 {
            aggregate_reasons.push("conflicting_usage");
            warnings.push("conflicting_usage".into());
            if snapshot["phase"] == "ready" {
                snapshot["phase"] = json!("partial");
            }
        }
        snapshot["quality"] = json!(aggregate_quality);
        snapshot["conflicts"] = json!(excluded_conflicts);
        snapshot["reasons"] = json!(aggregate_reasons);
        snapshot["warnings"] = json!(warnings);
        snapshot["totals"] = json!({"tokens":totals.tokens,"sessions":count,"states":states,"attention":{"input":Value::Null,"approval":Value::Null,"tool_pending":Value::Null,"unknown":count},"staleRunning":stale_running,"quality":aggregate_quality,"unknownTime":unknown_time,"excludedConflicts":excluded_conflicts});
        snapshot["sessions"] = json!(page);
        snapshot["filteredCount"] = json!(count);
        snapshot["hasMore"] = json!(q.offset.saturating_add(q.limit) < count);
        snapshot["projects"] = json!(projects
            .iter()
            .map(|(key, b)| b.value(key, aggregate_partial))
            .collect::<Vec<_>>());
        snapshot["models"] = json!(models
            .iter()
            .map(|(key, b)| b.value(key, aggregate_partial))
            .collect::<Vec<_>>());
        snapshot["daily"] = json!(daily
            .iter()
            .enumerate()
            .map(|(i, b)| {
                let mut v = b.value(&q.edges[i].to_string(), aggregate_partial);
                v["fromMs"] = json!(q.edges[i]);
                v["toMs"] = json!(q.edges[i + 1]);
                v
            })
            .collect::<Vec<_>>());
        Ok(snapshot)
    }
}
