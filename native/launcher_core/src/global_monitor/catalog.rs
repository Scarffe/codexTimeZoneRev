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
    pub(super) fn start_discovery(&mut self) {
        self.pending_dirs = self
            .roots
            .iter()
            .flat_map(|p| children(p))
            .filter(|p| p.exists())
            .collect();
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
                let Some(path) = self.pending_dirs.pop_front() else {
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
                self.pending_dirs.push_back(path);
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
            self.sources
                .entry(path.clone())
                .or_insert_with(|| Source::new(path));
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
    source.source_state = "ok".into();
    source.restored = false;
    let mut reader = BufReader::new(file);
    if reader.seek(SeekFrom::Start(source.offset)).is_err() {
        source.source_state = "unreadable".into();
        return 0;
    }
    let mut read = 0;
    while read < budget && !cancelled(generation, epoch) {
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
    if source.offset >= source.length && source.thread_id.is_empty() {
        source.source_state = "unsupported".into();
        source.reasons.insert("missing_session_meta".into());
    }
    read
}
