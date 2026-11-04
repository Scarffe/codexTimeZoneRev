//! Explicit local conversation names only; never derive a title from messages.
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

// The official append-only index is usually small. Bound every read while
// retaining the most recent names/renames if an unusually large index is used.
const MAX_INDEX_BYTES: u64 = 4 * 1024 * 1024;
const MAX_ROW_BYTES: usize = 64 * 1024;
const MAX_TITLE_BYTES: usize = 32768;

pub(crate) fn title(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|text| text.len() <= MAX_TITLE_BYTES)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

pub(crate) fn default_home() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE")
                .or_else(|| std::env::var_os("HOME"))
                .map(|path| PathBuf::from(path).join(".codex"))
        })
}

pub(crate) fn home_for_root(root: &Path) -> &Path {
    if matches!(
        root.file_name().and_then(|name| name.to_str()),
        Some("sessions" | "archived_sessions")
    ) {
        root.parent().unwrap_or(root)
    } else {
        root
    }
}

pub(crate) fn home_for_rollout(path: &Path) -> Option<&Path> {
    path.ancestors().skip(1).find_map(|ancestor| {
        matches!(
            ancestor.file_name().and_then(|name| name.to_str()),
            Some("sessions" | "archived_sessions")
        )
        .then(|| ancestor.parent())
        .flatten()
    })
}

pub(crate) fn read(home: &Path) -> BTreeMap<String, String> {
    let mut names = BTreeMap::new();
    let path = home.join("session_index.jsonl");
    let Ok(metadata) = fs::symlink_metadata(&path) else {
        return names;
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return names;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return names;
        }
    }
    let Ok(mut file) = File::open(path) else {
        return names;
    };
    let Ok(metadata) = file.metadata() else {
        return names;
    };
    let start = metadata.len().saturating_sub(MAX_INDEX_BYTES);
    let mut bytes = Vec::new();
    if file.seek(SeekFrom::Start(start)).is_err()
        || file.take(MAX_INDEX_BYTES).read_to_end(&mut bytes).is_err()
    {
        return names;
    }
    for (index, row) in bytes.split_inclusive(|byte| *byte == b'\n').enumerate() {
        // A truncated head or unfinished append is not a complete metadata row.
        if start > 0 && index == 0 || row.last() != Some(&b'\n') || row.len() > MAX_ROW_BYTES {
            continue;
        }
        let row = if start == 0 && index == 0 {
            row.strip_prefix(b"\xef\xbb\xbf").unwrap_or(row)
        } else {
            row
        };
        let Ok(value) = serde_json::from_slice::<Value>(row) else {
            continue;
        };
        let Some(id) = value["id"]
            .as_str()
            .filter(|id| !id.trim().is_empty() && id.len() <= 32768)
        else {
            continue;
        };
        if let Some(name) = title(&value["thread_name"]) {
            // Append order is authoritative, including repeated IDs on rename.
            names.insert(id.to_owned(), name);
        }
    }
    names
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    #[test]
    fn session_names_skip_malformed_blank_and_partial_rows_without_reading_message_text() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("session_index.jsonl");
        let mut index = File::create(&path).unwrap();
        writeln!(index, "{}", json!({"id":"thread","thread_name":"Old name"})).unwrap();
        writeln!(index, "not json").unwrap();
        for name in [
            Value::Null,
            json!(12),
            json!("  "),
            json!("x".repeat(MAX_TITLE_BYTES + 1)),
        ] {
            writeln!(index, "{}", json!({"id":"thread","thread_name":name})).unwrap();
        }
        writeln!(
            index,
            "{}",
            json!({"id":"no-title","message":"Private message"})
        )
        .unwrap();
        write!(index, "{}", json!({"id":"thread","thread_name":"New name"})).unwrap();
        index.flush().unwrap();
        assert_eq!(
            read(home.path()).get("thread").map(String::as_str),
            Some("Old name")
        );
        assert_eq!(read(home.path()).len(), 1);
        writeln!(index).unwrap();
        index.flush().unwrap();
        assert_eq!(
            read(home.path()).get("thread").map(String::as_str),
            Some("New name")
        );
    }

    #[test]
    fn session_names_bound_large_indexes_and_keep_recent_complete_rows() {
        let home = tempfile::tempdir().unwrap();
        let mut index = File::create(home.path().join("session_index.jsonl")).unwrap();
        index
            .write_all(&vec![b'x'; MAX_INDEX_BYTES as usize + 100])
            .unwrap();
        writeln!(index).unwrap();
        writeln!(
            index,
            "{}",
            json!({"id":"recent","thread_name":"Recent name"})
        )
        .unwrap();
        index.flush().unwrap();
        let names = read(home.path());
        assert_eq!(names.len(), 1);
        assert_eq!(names["recent"], "Recent name");
    }
}
