//! Opened-file identity and bounded continuity checkpoints; size/mtime alone
//! cannot distinguish replacement by a longer file with the same session ID.
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
};

#[derive(Default)]
pub(super) struct Identity {
    native: Option<(u64, u64)>,
    prefix: Vec<u8>,
    tail: Vec<u8>,
    offset: u64,
}
#[cfg(windows)]
fn native(file: &File) -> Option<(u64, u64)> {
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
fn native(file: &File) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let m = file.metadata().ok()?;
    Some((m.dev(), m.ino()))
}
#[cfg(not(any(windows, unix)))]
fn native(_: &File) -> Option<(u64, u64)> {
    None
}
fn bytes(file: &mut File, offset: u64, len: usize) -> std::io::Result<Vec<u8>> {
    file.seek(SeekFrom::Start(offset))?;
    let mut v = vec![0; len];
    file.read_exact(&mut v)?;
    Ok(v)
}
impl Identity {
    pub fn matches(&self, file: &mut File) -> std::io::Result<bool> {
        if self.native != native(file) || file.metadata()?.len() < self.offset {
            return Ok(false);
        }
        Ok(bytes(file, 0, self.prefix.len())? == self.prefix
            && bytes(file, self.offset - self.tail.len() as u64, self.tail.len())? == self.tail)
    }
    pub fn capture(file: &mut File, offset: u64) -> std::io::Result<Self> {
        let n = offset.min(4096) as usize;
        Ok(Self {
            native: native(file),
            prefix: bytes(file, 0, n)?,
            tail: bytes(file, offset - n as u64, n)?,
            offset,
        })
    }
}
