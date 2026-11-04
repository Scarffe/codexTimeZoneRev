//! Passive local-rollout index. No CLI, credentials, RPC or network access.
mod catalog;
mod query;
mod reduce;

use reduce::Source;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        LazyLock, Mutex,
    },
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_LINE: u64 = 8 * 1024 * 1024;
const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_FILES: usize = 32;
const RECENT_FILES: usize = 8;
const FILE_BYTES: usize = 512 * 1024;
static CANCELLED: AtomicU64 = AtomicU64::new(0);
// One admission word: odd while stopping, even only after drain has completed.
static ADMISSION: AtomicU64 = AtomicU64::new(0);
static INDEX: LazyLock<Mutex<Kernel>> = LazyLock::new(|| {
    let path = std::env::current_exe()
        .ok()
        .and_then(|p| {
            p.parent()
                .map(|p| p.join("global-monitor-v2").join("index.json"))
        })
        .unwrap_or_else(|| PathBuf::from("global-monitor-v2/index.json"));
    Mutex::new(Kernel::new(path))
});

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| u64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}
fn text(v: &Value) -> Option<String> {
    v.as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 32768)
        .map(str::to_owned)
}
fn checked_request(value: &Value, allowed: &[&str]) -> Result<(), String> {
    let object = value.as_object().ok_or("global_invalid_request")?;
    if object.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err("global_invalid_request".into());
    }
    Ok(())
}
fn number(value: &Value, key: &str) -> Result<Option<u64>, String> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .filter(|n| *n <= 8_640_000_000_000_000)
            .map(Some)
            .ok_or_else(|| "global_invalid_request".into()),
    }
}

/// Cancellation is deliberately handled before acquiring the index lock.
pub fn execute(payload: Value) -> Result<Value, String> {
    match payload["action"].as_str().ok_or("global_invalid_request")? {
        "capabilities" => {
            checked_request(&payload, &["action"])?;
            Ok(
                json!({"globalVersion":1,"localReadOnly":true,"modelRequests":false,"accountQueries":false,"queryScans":false,"attentionEvidence":"unsupported","persistentIndex":true}),
            )
        }
        "cancel" => {
            checked_request(&payload, &["action", "generation"])?;
            let generation = number(&payload, "generation")?
                .filter(|g| *g > 0)
                .ok_or("global_invalid_request")?;
            CANCELLED.fetch_max(generation, Ordering::SeqCst);
            Ok(json!({"globalVersion":1,"cancelled":true,"generation":generation}))
        }
        "shutdown" => {
            checked_request(&payload, &["action"])?;
            let ticket = begin_shutdown();
            // Drains an in-flight scan after publishing its cancellation barrier.
            let mut kernel = INDEX.lock().map_err(|_| "global_index_unavailable")?;
            kernel.finish_shutdown(ticket);
            Ok(json!({"globalVersion":1,"stopped":true}))
        }
        "scan" => {
            checked_request(&payload, &["action", "roots", "generation", "nowMs"])?;
            let epoch = ADMISSION.load(Ordering::SeqCst);
            if epoch & 1 != 0 {
                return Ok(json!({"globalVersion":1,"cancelled":true}));
            }
            INDEX
                .lock()
                .map_err(|_| "global_index_unavailable")?
                .scan_at(&payload, epoch)
        }
        "query" => INDEX
            .lock()
            .map_err(|_| "global_index_unavailable")?
            .query(&payload),
        _ => Err("global_invalid_request".into()),
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DiskIndex {
    schema_version: u32,
    index_epoch: u64,
    revision: u64,
    roots: Vec<PathBuf>,
    roots_explicit: bool,
    sources: BTreeMap<PathBuf, Source>,
    observed_at_ms: u64,
}

struct Kernel {
    cache: PathBuf,
    roots: Vec<PathBuf>,
    roots_explicit: bool,
    sources: BTreeMap<PathBuf, Source>,
    pending_dirs: VecDeque<(PathBuf, SystemTime)>,
    current_dir: Option<(PathBuf, fs::ReadDir)>,
    discovered: BTreeSet<PathBuf>,
    discovery_done: bool,
    directory_errors: usize,
    next_file: usize,
    last_discovery: u64,
    revision: u64,
    index_epoch: u64,
    observed_at_ms: u64,
    restored: bool,
    store_error: Option<String>,
    store_blocked: bool,
    after_shutdown: bool,
}
impl Kernel {
    fn new(cache: PathBuf) -> Self {
        let mut result = Self {
            cache,
            roots: Vec::new(),
            roots_explicit: false,
            sources: BTreeMap::new(),
            pending_dirs: VecDeque::new(),
            current_dir: None,
            discovered: BTreeSet::new(),
            discovery_done: true,
            directory_errors: 0,
            next_file: 0,
            last_discovery: 0,
            revision: 0,
            index_epoch: now_ms(),
            observed_at_ms: 0,
            restored: false,
            store_error: None,
            store_blocked: false,
            after_shutdown: false,
        };
        if result.cache.exists() {
            let loaded = File::open(&result.cache).ok().and_then(|f| {
                serde_json::from_reader::<_, DiskIndex>(f.take(256 * 1024 * 1024)).ok()
            });
            match loaded {
                Some(disk)
                    if disk.schema_version == 2
                        && disk.sources.values().all(Source::valid_cache) =>
                {
                    result.roots = disk.roots;
                    result.roots_explicit = disk.roots_explicit;
                    result.sources = disk.sources;
                    result.revision = disk.revision;
                    result.index_epoch = disk.index_epoch;
                    result.observed_at_ms = disk.observed_at_ms;
                    result.restored = true;
                    for source in result.sources.values_mut() {
                        source.restored = true;
                    }
                    result.start_discovery();
                }
                _ => {
                    result.store_error = Some("cache_invalid".into());
                    result.store_blocked = true;
                }
            }
        }
        result
    }
    fn save(&mut self, guard: Option<(u64, u64)>) -> bool {
        if self.store_blocked {
            return false;
        }
        let save = (|| -> std::io::Result<()> {
            let parent = self
                .cache
                .parent()
                .ok_or_else(|| std::io::Error::other("cache_parent"))?;
            fs::create_dir_all(parent)?;
            let mut temp = tempfile::NamedTempFile::new_in(parent)?;
            let disk = DiskIndex {
                schema_version: 2,
                index_epoch: self.index_epoch,
                revision: self.revision,
                roots: self.roots.clone(),
                roots_explicit: self.roots_explicit,
                sources: self.sources.clone(),
                observed_at_ms: self.observed_at_ms,
            };
            serde_json::to_writer(temp.as_file_mut(), &disk)?;
            temp.as_file_mut().flush()?;
            temp.as_file().sync_all()?;
            if guard.is_some_and(|(generation, epoch)| cancelled(generation, epoch)) {
                return Err(std::io::Error::from(std::io::ErrorKind::Interrupted));
            }
            temp.persist(&self.cache).map_err(|e| e.error)?;
            Ok(())
        })();
        match save {
            Ok(()) => {
                self.store_error = None;
                true
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => false,
            Err(_) => {
                self.store_error = Some("cache_write_failed".into());
                false
            }
        }
    }
    #[cfg(test)]
    fn scan(&mut self, payload: &Value) -> Result<Value, String> {
        self.scan_at(payload, ADMISSION.load(Ordering::SeqCst))
    }
    fn finish_shutdown(&mut self, ticket: u64) -> bool {
        // Only the most recent shutdown can reopen admission; stale shutdowns
        // cannot change the recovery flag or cancel a newer scan generation.
        if ticket & 1 == 0 {
            return false;
        }
        if ADMISSION
            .compare_exchange(
                ticket,
                ticket.wrapping_add(1),
                Ordering::SeqCst,
                Ordering::SeqCst,
            )
            .is_ok()
        {
            self.after_shutdown = true;
            true
        } else {
            false
        }
    }
    fn scan_at(&mut self, payload: &Value, epoch: u64) -> Result<Value, String> {
        let generation = number(payload, "generation")?
            .filter(|g| *g > 0)
            .ok_or("global_invalid_request")?;
        let now = number(payload, "nowMs")?.unwrap_or_else(now_ms);
        if epoch & 1 != 0 || epoch != ADMISSION.load(Ordering::SeqCst) {
            return Ok(json!({"globalVersion":1,"cancelled":true,"revision":self.revision}));
        }
        if self.after_shutdown {
            CANCELLED.store(0, Ordering::SeqCst);
            self.after_shutdown = false;
        }
        if CANCELLED.load(Ordering::SeqCst) >= generation {
            return Ok(json!({"globalVersion":1,"cancelled":true,"revision":self.revision}));
        }
        let roots_explicit = match payload.get("roots") {
            None => self.roots_explicit,
            Some(Value::Null) => false,
            Some(_) => true,
        };
        let roots = if roots_explicit && payload.get("roots").is_none() {
            self.roots.clone()
        } else {
            catalog::roots(payload.get("roots"))?
        };
        let old_roots_explicit = self.roots_explicit;
        let old_roots = self.roots.clone();
        let old_sources = self.sources.clone();
        let old_epoch = self.index_epoch;
        let old_restored = self.restored;
        let old_revision = self.revision;
        let old_observed = self.observed_at_ms;
        let old_store_error = self.store_error.clone();
        let old_directory_errors = self.directory_errors;
        let old_discovery_done = self.discovery_done;
        self.roots_explicit = roots_explicit;
        if self.roots != roots {
            self.roots = roots;
            self.sources.clear();
            self.discovered.clear();
            self.next_file = 0;
            self.index_epoch = self.index_epoch.saturating_add(1);
            self.restored = false;
            self.start_discovery();
        } else if self.discovery_done
            && (self.last_discovery == 0 || now.saturating_sub(self.last_discovery) >= 10_000)
        {
            self.start_discovery();
        }
        let was_discovering = !self.discovery_done;
        self.advance_discovery(generation, epoch);
        if was_discovering && self.discovery_done {
            self.last_discovery = now;
        }
        // Unsupported compressed rollouts remain coverage gaps, never read slots.
        let paths: Vec<_> = self
            .sources
            .keys()
            .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
            .cloned()
            .collect();
        let mut recent = paths.clone();
        recent.sort_by(|a, b| {
            catalog::is_active_session_path(b)
                .cmp(&catalog::is_active_session_path(a))
                .then_with(|| {
                    self.sources[b]
                        .priority_modified
                        .cmp(&self.sources[a].priority_modified)
                })
                .then_with(|| a.cmp(b))
        });
        let mut bytes = 0;
        let mut visited = 0;
        let mut seen = BTreeSet::new();
        // Reserve half the byte budget for fair backlog work, even when all
        // recent rollouts are large. Complete records retain the existing cap.
        for path in recent.into_iter().take(RECENT_FILES) {
            if bytes >= MAX_BYTES / 2 || cancelled(generation, epoch) {
                break;
            }
            if let Some(source) = self.sources.get_mut(&path) {
                let budget = FILE_BYTES.min(MAX_BYTES / 2 - bytes);
                bytes += catalog::read_source(source, budget, generation, epoch);
                seen.insert(path);
                visited += 1;
            }
        }
        let mut considered = 0;
        while !paths.is_empty()
            && visited < MAX_FILES
            && bytes < MAX_BYTES
            && considered < paths.len()
            && !cancelled(generation, epoch)
        {
            let index = self.next_file % paths.len();
            self.next_file = (index + 1) % paths.len();
            considered += 1;
            if !seen.insert(paths[index].clone()) {
                continue;
            }
            visited += 1;
            if let Some(source) = self.sources.get_mut(&paths[index]) {
                bytes += catalog::read_source(
                    source,
                    FILE_BYTES.min(MAX_BYTES - bytes),
                    generation,
                    epoch,
                );
            }
        }
        if cancelled(generation, epoch) {
            self.roots = old_roots;
            self.roots_explicit = old_roots_explicit;
            self.sources = old_sources;
            self.index_epoch = old_epoch;
            self.restored = old_restored;
            self.start_discovery();
            return Ok(json!({"globalVersion":1,"cancelled":true,"revision":self.revision}));
        }
        // Names are independent metadata: a rename need not append rollout
        // bytes. Scope each index to its home and refresh outside query().
        let mut names = BTreeMap::new();
        for root in &self.roots {
            let home = crate::session_names::home_for_root(root);
            names
                .entry(home.to_path_buf())
                .or_insert_with(|| crate::session_names::read(home));
        }
        for source in self.sources.values_mut() {
            source.title = crate::session_names::home_for_rollout(&source.path)
                .and_then(|home| names.get(home))
                .and_then(|index| index.get(&source.thread_id))
                .cloned()
                .or_else(|| source.metadata_title.clone());
        }
        self.observed_at_ms = now;
        self.revision = self.revision.saturating_add(1);
        let dirty = bytes > 0
            || old_roots != self.roots
            || old_roots_explicit != self.roots_explicit
            || old_sources.len() != self.sources.len()
            || old_directory_errors != self.directory_errors
            || old_discovery_done != self.discovery_done
            || self.sources.iter().any(|(path, s)| {
                old_sources.get(path).is_none_or(|old| {
                    old.source_state != s.source_state
                        || old.length != s.length
                        || old.reasons != s.reasons
                        || old.title != s.title
                        || old.metadata_title != s.metadata_title
                        || old.metadata_title_read != s.metadata_title_read
                })
            });
        let committed = dirty && self.save(Some((generation, epoch)));
        if cancelled(generation, epoch) {
            self.roots = old_roots;
            self.roots_explicit = old_roots_explicit;
            self.sources = old_sources;
            self.index_epoch = old_epoch;
            self.restored = old_restored;
            self.revision = old_revision;
            self.observed_at_ms = old_observed;
            self.store_error = old_store_error;
            self.start_discovery();
            if committed {
                self.save(None);
            }
            return Ok(json!({"globalVersion":1,"cancelled":true,"revision":self.revision}));
        }
        let warnings: Vec<_> = self
            .store_error
            .iter()
            .cloned()
            .chain((self.directory_errors > 0).then_some("directory_unreadable".into()))
            .collect();
        Ok(
            json!({"globalVersion":1,"revision":self.revision,"indexEpoch":self.index_epoch,"phase":self.phase(),"observedAtMs":self.observed_at_ms,"restored":self.restored,"roots":self.roots,"coverage":self.coverage(),"warnings":warnings,"bytesRead":bytes,"visitedFiles":visited}),
        )
    }
    fn coverage(&self) -> Value {
        let unreadable = self
            .sources
            .values()
            .filter(|s| s.source_state == "unreadable")
            .count()
            + self.directory_errors;
        let unsupported = self
            .sources
            .values()
            .filter(|s| s.source_state == "unsupported")
            .count();
        let missing = self
            .sources
            .values()
            .filter(|s| s.source_state == "missing")
            .count();
        let pending = self
            .sources
            .values()
            .filter(|s| {
                s.source_state == "pending" || (s.offset < s.length && s.source_state == "ok")
            })
            .count();
        let indexed = self
            .sources
            .values()
            .filter(|s| s.source_state == "ok" && s.offset >= s.length)
            .count();
        json!({"discovered":self.sources.len(),"indexed":indexed,"pending":pending,"unreadable":unreadable,"unsupported":unsupported,"missing":missing,"complete":self.discovery_done&&pending==0&&unreadable==0&&unsupported==0&&missing==0})
    }
    fn phase(&self) -> &str {
        if !self.discovery_done
            || self.sources.values().any(|s| {
                s.source_state == "pending" || s.source_state == "ok" && s.offset < s.length
            })
        {
            "scanning"
        } else if self.store_error.is_some()
            || self.directory_errors > 0
            || self
                .sources
                .values()
                .any(|s| s.source_state != "ok" || !s.reasons.is_empty())
        {
            "partial"
        } else if self.sources.is_empty() {
            "empty"
        } else {
            "ready"
        }
    }
}
fn begin_shutdown() -> u64 {
    let old = ADMISSION
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |t| {
            Some((t | 1).wrapping_add(2))
        })
        .unwrap();
    (old | 1).wrapping_add(2)
}
fn cancelled(generation: u64, epoch: u64) -> bool {
    epoch & 1 != 0
        || CANCELLED.load(Ordering::SeqCst) >= generation
        || ADMISSION.load(Ordering::SeqCst) != epoch
}

#[cfg(test)]
#[path = "global_monitor_tests.rs"]
mod tests;
