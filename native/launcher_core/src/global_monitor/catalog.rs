use super::*;
use std::io::{BufRead, BufReader, Seek, SeekFrom};

pub(super) fn roots(explicit: Option<&Value>) -> Result<Vec<PathBuf>, String> {
    let homes: Vec<PathBuf> = match explicit {
        Some(Value::Array(values)) if !values.is_empty() && values.len() <= 64 => values
            .iter()
            .map(|v| {
                text(v)
                    .map(PathBuf::from)
                    .ok_or_else(|| "global_invalid_roots".to_owned())
            })
            .collect::<Result<_, _>>()?,
        Some(Value::Null) | None => {
            let default = std::env::var_os("USERPROFILE")
                .or_else(|| std::env::var_os("HOME"))
                .map(|p| PathBuf::from(p).join(".codex"));
            let mut homes = Vec::new();
            if let Some(home) = std::env::var_os("CODEX_HOME").map(PathBuf::from) {
                homes.push(home);
            }
            if let Some(home) = default {
                if home.exists() {
                    homes.push(home);
                }
            }
            homes
        }
        _ => return Err("global_invalid_roots".into()),
    };
    let mut roots = BTreeSet::new();
    for home in homes {
        // A fixture/user home is permitted; only its fixed rollout directories are opened.
        let canonical = home
            .canonicalize()
            .map_err(|_| "global_roots_unavailable")?;
        if !canonical.is_dir() {
            return Err("global_invalid_roots".into());
        }
        roots.insert(canonical);
    }
    Ok(roots.into_iter().collect())
}
fn children(root: &Path) -> Vec<PathBuf> {
    if matches!(
        root.file_name().and_then(|s| s.to_str()),
        Some("sessions" | "archived_sessions")
    ) {
        vec![root.to_path_buf()]
    } else {
        vec![root.join("sessions"), root.join("archived_sessions")]
    }
}
pub(super) fn is_active_session_path(path: &Path) -> bool {
    path.components().any(|c| c.as_os_str() == "sessions")
}
pub(super) fn strict_detail_supported(path: &Path) -> bool {
    let home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE")
                .or_else(|| std::env::var_os("HOME"))
                .map(|p| PathBuf::from(p).join(".codex"))
        });
    home.and_then(|p| p.join("sessions").canonicalize().ok())
        .is_some_and(|base| path.starts_with(base))
}
fn reparse(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}
impl Kernel {
    fn queue_directory(&mut self, path: PathBuf, modified: SystemTime) {
        let active = is_active_session_path(&path);
        let position = self
            .pending_dirs
            .iter()
            .position(|(other, stamp)| {
                let other_active = is_active_session_path(other);
                active && !other_active
                    || active == other_active
                        && (modified > *stamp
                            || modified == *stamp && path.as_path() < other.as_path())
            })
            .unwrap_or(self.pending_dirs.len());
        self.pending_dirs.insert(position, (path, modified));
    }
    pub(super) fn start_discovery(&mut self) {
        let directories: Vec<_> = self
            .roots
            .iter()
            .flat_map(|p| children(p))
            .filter(|p| p.exists())
            .collect();
        self.pending_dirs.clear();
        for path in directories {
            let modified = fs::symlink_metadata(&path)
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(UNIX_EPOCH);
            self.queue_directory(path, modified);
        }
        self.current_dir = None;
        self.discovery_done = self.pending_dirs.is_empty();
        self.directory_errors = 0;
        self.discovered.clear();
    }
    pub(super) fn advance_discovery(&mut self, generation: u64, epoch: u64) {
        for _ in 0..256 {
            if cancelled(generation, epoch) {
                return;
            }
            if self.current_dir.is_none() {
                let Some((path, _)) = self.pending_dirs.pop_front() else {
                    self.discovery_done = true;
                    return;
                };
                match fs::symlink_metadata(&path) {
                    Ok(meta) if !reparse(&meta) => {}
                    _ => {
                        self.directory_errors += 1;
                        continue;
                    }
                }
                match fs::read_dir(&path) {
                    Ok(dir) => self.current_dir = Some((path, dir)),
                    Err(_) => {
                        self.directory_errors += 1;
                        continue;
                    }
                }
            }
            let entry = self.current_dir.as_mut().and_then(|(_, dir)| dir.next());
            let Some(entry) = entry else {
                self.current_dir = None;
                continue;
            };
            let Ok(entry) = entry else {
                self.directory_errors += 1;
                continue;
            };
            let path = entry.path();
            let Ok(meta) = fs::symlink_metadata(&path) else {
                self.directory_errors += 1;
                continue;
            };
            if reparse(&meta) {
                continue;
            }
            let Ok(path) = path.canonicalize() else {
                continue;
            };
            if !self.roots.iter().any(|r| path.starts_with(r)) {
                continue;
            }
            if meta.is_dir() {
                self.queue_directory(path, meta.modified().unwrap_or(UNIX_EPOCH));
                continue;
            }
            if !meta.is_file()
                || !path
                    .file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(|s| s.starts_with("rollout-"))
            {
                continue;
            }
            if !matches!(
                path.extension().and_then(|s| s.to_str()),
                Some("jsonl" | "gz" | "zst" | "zip")
            ) {
                continue;
            }
            self.discovered.insert(path.clone());
            let source = self
                .sources
                .entry(path.clone())
                .or_insert_with(|| Source::new(path));
            source.priority_modified = meta.modified().ok();
            if source.path.extension().is_none_or(|e| e != "jsonl") {
                source.source_state = "unsupported".into();
                source.length = meta.len();
            }
        }
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct Identity {
    native: Option<(u64, u64)>,
    head: u64,
    tail: u64,
    offset: u64,
}
fn native(file: &File) -> Option<(u64, u64)> {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows::Win32::{
            Foundation::HANDLE,
            Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION},
        };
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        unsafe {
            GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info).ok()?;
        }
        Some((
            u64::from(info.dwVolumeSerialNumber),
            u64::from(info.nFileIndexHigh) << 32 | u64::from(info.nFileIndexLow),
        ))
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let m = file.metadata().ok()?;
        Some((m.dev(), m.ino()))
    }
    #[cfg(not(any(windows, unix)))]
    {
        let _ = file;
        None
    }
}
fn fingerprint(file: &mut File, offset: u64, len: usize) -> std::io::Result<u64> {
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = vec![0; len];
    file.read_exact(&mut bytes)?;
    // Stable non-cryptographic continuity checksum; only the digest is persisted.
    Ok(bytes.into_iter().fold(0xcbf29ce484222325, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x100000001b3)
    }))
}
impl Identity {
    fn capture(file: &mut File, offset: u64) -> std::io::Result<Self> {
        let n = offset.min(4096) as usize;
        Ok(Self {
            native: native(file),
            head: fingerprint(file, 0, n)?,
            tail: fingerprint(file, offset - n as u64, n)?,
            offset,
        })
    }
    fn matches(&self, file: &mut File) -> bool {
        if native(file) != self.native
            || file
                .metadata()
                .map(|m| m.len() < self.offset)
                .unwrap_or(true)
        {
            return false;
        }
        let n = self.offset.min(4096) as usize;
        fingerprint(file, 0, n).ok() == Some(self.head)
            && fingerprint(file, self.offset - n as u64, n).ok() == Some(self.tail)
    }
}
fn line(reader: &mut impl BufRead) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.take(MAX_LINE + 1).read_until(b'\n', &mut bytes)?;
    if bytes.len() as u64 > MAX_LINE {
        return Err(std::io::Error::other("oversized_record"));
    }
    Ok(bytes)
}
const TAIL_BYTES: usize = 64 * 1024;

// Only lifecycle/activity metadata is projected. Usage always comes from the
// sequential ledger; a tail scan must never duplicate or attribute token facts.
fn recent_tail(
    file: &mut File,
    source: &Source,
    generation: u64,
    epoch: u64,
) -> (Option<reduce::TailState>, usize) {
    if source.thread_id.is_empty() || source.child || source.parent_thread_id.is_some() {
        return (None, 0);
    }
    let start = source.length.saturating_sub(TAIL_BYTES as u64);
    let mut bytes = Vec::new();
    if file.seek(SeekFrom::Start(start)).is_err()
        || file
            .take(source.length - start)
            .read_to_end(&mut bytes)
            .is_err()
    {
        return (None, 0);
    }
    let read = bytes.len();
    let Some(end) = bytes.iter().rposition(|b| *b == b'\n') else {
        return (None, read);
    };
    let begin = if start == 0 {
        0
    } else {
        match bytes.iter().position(|b| *b == b'\n') {
            Some(i) => i + 1,
            None => return (None, read),
        }
    };
    if begin > end {
        return (None, read);
    }
    let mut projection = Source::new(source.path.clone());
    projection.thread_id = source.thread_id.clone();
    for line in bytes[begin..=end].split(|b| *b == b'\n') {
        if cancelled(generation, epoch) {
            return (None, read);
        }
        let Ok(row) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        let kind = row["type"].as_str().unwrap_or("");
        let payload = &row["payload"];
        if kind == "event_msg"
            && matches!(
                payload["type"].as_str(),
                Some("task_started" | "task_complete" | "task_completed" | "turn_aborted")
            )
        {
            projection.accept(&row);
        } else if kind == "token_usage_record"
            && payload["thread_id"].as_str() == Some(source.thread_id.as_str())
        {
            if let Some(time) = reduce::timestamp(&row["timestamp"]) {
                projection.last_event_ms = Some(projection.last_event_ms.unwrap_or(0).max(time));
            }
        }
    }
    let latest_turn = projection
        .turns
        .values()
        .max_by_key(|t| (t.started_at.or(t.completed_at).unwrap_or(0), t.order))
        .cloned();
    (
        Some(reduce::TailState {
            length: source.length,
            last_event_ms: projection.last_event_ms,
            latest_turn,
        }),
        read,
    )
}

pub(super) fn read_source(
    source: &mut Source,
    budget: usize,
    generation: u64,
    epoch: u64,
) -> usize {
    if source.path.extension().is_none_or(|s| s != "jsonl") {
        source.source_state = "unsupported".into();
        return 0;
    }
    let Ok(meta) = fs::symlink_metadata(&source.path) else {
        source.source_state = "missing".into();
        return 0;
    };
    if reparse(&meta) {
        source.source_state = "unsupported".into();
        return 0;
    }
    let Ok(mut file) = File::open(&source.path) else {
        source.source_state = "unreadable".into();
        return 0;
    };
    let Ok(meta) = file.metadata() else {
        source.source_state = "unreadable".into();
        return 0;
    };
    if source
        .identity
        .as_ref()
        .is_some_and(|i| !i.matches(&mut file))
        || meta.len() < source.offset
    {
        let path = source.path.clone();
        *source = Source::new(path);
    }
    source.length = meta.len();
    source.priority_modified = meta.modified().ok();
    source.source_state = "ok".into();
    source.restored = false;
    let mut reader = BufReader::new(file);
    let mut read = 0;
    // Pre-title version-2 caches retain their usage ledger. Recover only the
    // first metadata record once, without replaying usage or changing identity.
    if !source.metadata_title_read && source.offset > 0 {
        if reader.seek(SeekFrom::Start(0)).is_ok() {
            if let Ok(bytes) = line(&mut reader) {
                read += bytes.len();
                if let Ok(row) = serde_json::from_slice::<Value>(&bytes) {
                    if row["type"] == "session_meta" && row["payload"]["id"] == source.thread_id {
                        source.metadata_title =
                            crate::session_names::title(&row["payload"]["title"]);
                    }
                }
                source.metadata_title_read = true;
            }
        }
    }
    if reader.seek(SeekFrom::Start(source.offset)).is_err() {
        source.source_state = "unreadable".into();
        return 0;
    }
    while read < budget.saturating_sub(TAIL_BYTES) && !cancelled(generation, epoch) {
        let bytes = match line(&mut reader) {
            Ok(v) => v,
            Err(_) => {
                source.source_state = "unsupported".into();
                source
                    .reasons
                    .insert("oversized_or_unreadable_record".into());
                break;
            }
        };
        if bytes.is_empty() || bytes.last() != Some(&b'\n') {
            break;
        }
        source.offset += bytes.len() as u64;
        read += bytes.len();
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(v) => source.accept(&v),
            Err(_) => {
                source.reasons.insert("malformed_record".into());
            }
        }
    }
    source.length = reader
        .get_ref()
        .metadata()
        .map(|m| m.len())
        .unwrap_or(source.length);
    if source.length < source.offset {
        let path = source.path.clone();
        *source = Source::new(path);
        return read;
    }
    source.identity = Identity::capture(reader.get_mut(), source.offset).ok();
    source.tail = None;
    if source.offset < source.length {
        let (tail, tail_bytes) = recent_tail(reader.get_mut(), source, generation, epoch);
        source.tail = tail;
        read += tail_bytes;
    }
    if source.offset >= source.length && source.thread_id.is_empty() {
        source.source_state = "unsupported".into();
        source.reasons.insert("missing_session_meta".into());
    }
    read
}
