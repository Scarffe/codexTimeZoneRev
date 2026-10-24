//! Synthetic-process isolation proof; absent from release builds and FFI.
//!
//! The trusted fixture blocks on stdin before doing work. Its Windows Job is
//! assigned before releasing that barrier. This is not atomic suspended-process
//! creation and is not safe for an arbitrary executable.
use serde_json::Value;
use std::{
    collections::VecDeque,
    fs,
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
        Arc, Mutex, OnceLock,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
const MAX_FRAME: usize = 65_536;
const MAX_QUEUE: usize = 32;
const TICK: Duration = Duration::from_millis(5);
const CLEANUP_LIMIT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProcessError {
    InvalidPath,
    Startup,
    Cancelled,
    Deadline,
    Eof,
    Malformed,
    Oversized,
    QueueOverflow,
    InvalidMessage,
    Io,
    ForeignIdentity,
    /// Child/job/thread teardown unconfirmed: retain any profile lease.
    Cleanup,
    #[cfg(not(windows))]
    Unsupported,
}
#[derive(Debug, Clone, Copy)]
pub(crate) enum FixtureMode {
    Normal,
    StartupError,
    Crash,
    Silent,
    Malformed,
    Oversized,
    Flood,
    BlockInput,
    Descendant,
}
impl FixtureMode {
    fn argument(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::StartupError => "startup-error",
            Self::Crash => "crash",
            Self::Silent => "silent",
            Self::Malformed => "malformed",
            Self::Oversized => "oversized",
            Self::Flood => "flood",
            Self::BlockInput => "block-input",
            Self::Descendant => "descendant",
        }
    }
}
pub(crate) struct FixtureLaunch {
    pub home: PathBuf,
    pub workspace: PathBuf,
    pub mode: FixtureMode,
}
// Private fields: PID alone is never authority.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProcessIdentity {
    pid: u32,
    token: u64,
}
impl ProcessIdentity {
    pub(crate) fn pid(&self) -> u32 {
        self.pid
    }
}
#[derive(Debug, Clone)]
pub(crate) struct CleanupReceipt {
    identity: ProcessIdentity,
}
impl CleanupReceipt {
    pub(crate) fn pid(&self) -> u32 {
        self.identity.pid
    }
    pub(crate) fn is_complete(&self) -> bool {
        true
    }
    pub(crate) fn belongs_to(&self, identity: &ProcessIdentity) -> bool {
        &self.identity == identity
    }
}
struct FixtureBinary {
    _directory: tempfile::TempDir,
    executable: PathBuf,
}
pub(crate) fn fixture_executable() -> PathBuf {
    static BINARY: OnceLock<FixtureBinary> = OnceLock::new();
    BINARY
        .get_or_init(|| {
            let directory = tempfile::Builder::new()
                .prefix("k31-fixture-bin-")
                .tempdir()
                .expect("fixture temp directory");
            let executable = directory.path().join(if cfg!(windows) {
                "task_server.exe"
            } else {
                "task_server"
            });
            // Only the absolute cached compiler explicitly supplied by the launcher.
            let compiler =
                PathBuf::from(std::env::var_os("RUSTC").expect("cached RUSTC must be explicit"));
            assert!(
                compiler.is_absolute() && compiler.is_file(),
                "cached compiler unavailable"
            );
            let mut child = Command::new(compiler)
                .args(["--edition=2021", "-C", "opt-level=0"])
                .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/task_server.rs"))
                .arg("-o")
                .arg(&executable)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("fixture compiler could not start");
            let deadline = Instant::now() + Duration::from_secs(45);
            loop {
                if let Some(status) = child.try_wait().expect("fixture compiler status") {
                    assert!(status.success(), "fixture compilation failed");
                    break;
                }
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("fixture compiler deadline");
                }
                thread::sleep(TICK);
            }
            FixtureBinary {
                _directory: directory,
                executable,
            }
        })
        .executable
        .clone()
}
fn checked_directory(path: &Path) -> Result<PathBuf, ProcessError> {
    if !path.is_absolute() {
        return Err(ProcessError::InvalidPath);
    }
    for component in path.ancestors() {
        let metadata = fs::symlink_metadata(component).map_err(|_| ProcessError::InvalidPath)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(ProcessError::InvalidPath);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return Err(ProcessError::InvalidPath);
            }
        }
    }
    fs::canonicalize(path).map_err(|_| ProcessError::InvalidPath)
}
fn valid_message(message: &Value) -> bool {
    let Some(object) = message.as_object() else {
        return false;
    };
    if let Some(id) = object.get("id") {
        if !(id.as_u64().is_some()
            || id.as_i64().is_some()
            || id
                .as_str()
                .is_some_and(|id| !id.is_empty() && id.len() <= 128))
        {
            return false;
        }
    }
    !object
        .get("method")
        .is_some_and(|method| !method.is_string())
}

// Bound work and memory before serialization. Raw string lengths are lower
// bounds on JSON bytes; a bounded writer below accounts for escaping exactly.
fn input_budget(
    value: &Value,
    depth: usize,
    remaining: &mut usize,
    cancel: &AtomicBool,
    deadline: Instant,
) -> Result<(), ProcessError> {
    if cancel.load(Ordering::Acquire) {
        return Err(ProcessError::Cancelled);
    }
    if Instant::now() >= deadline {
        return Err(ProcessError::Deadline);
    }
    if depth > 128 {
        return Err(ProcessError::InvalidMessage);
    }
    let size = match value {
        Value::String(text) => text.len().saturating_add(2),
        _ => 1,
    };
    *remaining = remaining.checked_sub(size).ok_or(ProcessError::Oversized)?;
    match value {
        Value::Array(values) => {
            for value in values {
                input_budget(value, depth + 1, remaining, cancel, deadline)?;
            }
        }
        Value::Object(values) => {
            for (key, value) in values {
                *remaining = remaining
                    .checked_sub(key.len().saturating_add(3))
                    .ok_or(ProcessError::Oversized)?;
                input_budget(value, depth + 1, remaining, cancel, deadline)?;
            }
        }
        _ => {}
    }
    Ok(())
}
fn encode_frame(
    message: &Value,
    cancel: &AtomicBool,
    deadline: Instant,
) -> Result<Vec<u8>, ProcessError> {
    input_budget(message, 0, &mut (MAX_FRAME - 1), cancel, deadline)?;
    struct FrameWriter<'a> {
        bytes: Vec<u8>,
        error: Option<ProcessError>,
        cancel: &'a AtomicBool,
        deadline: Instant,
    }
    impl Write for FrameWriter<'_> {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            let error = if self.cancel.load(Ordering::Acquire) {
                Some(ProcessError::Cancelled)
            } else if Instant::now() >= self.deadline {
                Some(ProcessError::Deadline)
            } else if bytes.len() >= MAX_FRAME - self.bytes.len() {
                Some(ProcessError::Oversized)
            } else {
                None
            };
            if let Some(error) = error {
                self.error = Some(error);
                return Err(std::io::Error::other("fixture frame budget"));
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut writer = FrameWriter {
        bytes: Vec::with_capacity(MAX_FRAME),
        error: None,
        cancel,
        deadline,
    };
    if serde_json::to_writer(&mut writer, message).is_err() {
        return Err(writer.error.unwrap_or(ProcessError::InvalidMessage));
    }
    writer.bytes.push(b'\n');
    Ok(writer.bytes)
}
type WriteRequest = (Vec<u8>, SyncSender<Result<(), ProcessError>>);
pub(crate) struct TaskProcess {
    child: Child,
    #[cfg(windows)]
    job: OwnedJob,
    identity: ProcessIdentity,
    cancel: Arc<AtomicBool>,
    input: Option<SyncSender<WriteRequest>>,
    output: Receiver<Value>,
    terminal: Arc<Mutex<Option<ProcessError>>>,
    initial: VecDeque<Value>,
    reader: Option<JoinHandle<()>>,
    writer: Option<JoinHandle<()>>,
    receipt: Option<CleanupReceipt>,
}
fn terminal_error(state: &Mutex<Option<ProcessError>>) -> Option<ProcessError> {
    *state.lock().unwrap_or_else(|poison| poison.into_inner())
}
fn set_terminal(state: &Mutex<Option<ProcessError>>, error: ProcessError) {
    let mut guard = state.lock().unwrap_or_else(|poison| poison.into_inner());
    if guard.is_none() {
        *guard = Some(error);
    }
}
#[cfg(windows)]
struct OwnedJob(windows::Win32::Foundation::HANDLE);
#[cfg(windows)]
impl OwnedJob {
    fn create() -> Result<Self, ProcessError> {
        use windows::Win32::System::JobObjects::*;
        unsafe {
            let job = Self(CreateJobObjectW(None, None).map_err(|_| ProcessError::Startup)?);
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                std::mem::size_of_val(&info) as u32,
            )
            .map_err(|_| ProcessError::Startup)?;
            Ok(job)
        }
    }
    fn attach(&self, child: &Child) -> Result<(), ProcessError> {
        use std::os::windows::io::AsRawHandle;
        unsafe {
            windows::Win32::System::JobObjects::AssignProcessToJobObject(
                self.0,
                windows::Win32::Foundation::HANDLE(child.as_raw_handle()),
            )
            .map_err(|_| ProcessError::Startup)
        }
    }
    fn terminate(&self) -> Result<(), ProcessError> {
        unsafe {
            windows::Win32::System::JobObjects::TerminateJobObject(self.0, 1)
                .map_err(|_| ProcessError::Cleanup)
        }
    }
    fn is_empty(&self) -> Result<bool, ProcessError> {
        use windows::Win32::System::JobObjects::*;
        let mut info = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
        unsafe {
            QueryInformationJobObject(
                Some(self.0),
                JobObjectBasicAccountingInformation,
                &mut info as *mut _ as *mut _,
                std::mem::size_of_val(&info) as u32,
                None,
            )
            .map_err(|_| ProcessError::Cleanup)?;
        }
        Ok(info.ActiveProcesses == 0)
    }
}
#[cfg(windows)]
impl Drop for OwnedJob {
    fn drop(&mut self) {
        unsafe {
            let _ = windows::Win32::Foundation::CloseHandle(self.0);
        }
    }
}
impl TaskProcess {
    pub(crate) fn spawn_fixture(
        launch: FixtureLaunch,
        cancel: Arc<AtomicBool>,
    ) -> Result<Self, ProcessError> {
        if cancel.load(Ordering::Acquire) {
            return Err(ProcessError::Cancelled);
        }
        #[cfg(not(windows))]
        {
            let _ = launch;
            return Err(ProcessError::Unsupported);
        }
        #[cfg(windows)]
        {
            let home = checked_directory(&launch.home)?;
            let workspace = checked_directory(&launch.workspace)?;
            if home == workspace || home.starts_with(&workspace) || workspace.starts_with(&home) {
                return Err(ProcessError::InvalidPath);
            }
            let executable = fixture_executable();
            let job = OwnedJob::create()?;
            if cancel.load(Ordering::Acquire) {
                return Err(ProcessError::Cancelled);
            }
            let mut command = Command::new(executable);
            command.env_clear();
            // OS runtime location only; no PATH, provider, CA or proxy inheritance.
            for key in ["SystemRoot", "WINDIR"] {
                if let Some(value) = std::env::var_os(key) {
                    command.env(key, value);
                }
            }
            for key in [
                "CODEX_HOME",
                "HOME",
                "USERPROFILE",
                "APPDATA",
                "LOCALAPPDATA",
                "TEMP",
                "TMP",
            ] {
                command.env(key, &home);
            }
            command
                .current_dir(&workspace)
                .args([
                    "--fixture-mode",
                    launch.mode.argument(),
                    "-c",
                    "cli_auth_credentials_store=\"file\"",
                ])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null());
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
            let mut child = command.spawn().map_err(|_| ProcessError::Startup)?;
            if let Err(error) = job.attach(&child) {
                let _ = child.kill();
                let deadline = Instant::now() + CLEANUP_LIMIT;
                loop {
                    match child.try_wait() {
                        Ok(Some(_)) => return Err(error),
                        Ok(None) if Instant::now() < deadline => thread::sleep(TICK),
                        _ => return Err(ProcessError::Cleanup),
                    }
                }
            }
            static NEXT_IDENTITY: AtomicU64 = AtomicU64::new(1);
            let identity = ProcessIdentity {
                pid: child.id(),
                token: NEXT_IDENTITY.fetch_add(1, Ordering::Relaxed),
            };
            let mut stdin = child.stdin.take().expect("piped fixture stdin");
            let stdout = child.stdout.take().expect("piped fixture stdout");
            let (input, writes) = mpsc::sync_channel::<WriteRequest>(1);
            // One reserved slot holds the initial ready message for the caller.
            let (outputs, output) = mpsc::sync_channel(MAX_QUEUE - 1);
            let terminal = Arc::new(Mutex::new(None));
            let reader_terminal = terminal.clone();
            let reader = thread::spawn(move || {
                let mut reader = BufReader::new(stdout);
                loop {
                    let mut frame = Vec::new();
                    let read = reader
                        .by_ref()
                        .take((MAX_FRAME + 1) as u64)
                        .read_until(b'\n', &mut frame);
                    let error = match read {
                        Ok(0) => Some(ProcessError::Eof),
                        Err(_) => Some(ProcessError::Io),
                        Ok(_) if frame.len() > MAX_FRAME => Some(ProcessError::Oversized),
                        Ok(_) if frame.last() != Some(&b'\n') => Some(ProcessError::Malformed),
                        Ok(_) => None,
                    };
                    if let Some(error) = error {
                        set_terminal(&reader_terminal, error);
                        break;
                    }
                    let message = match serde_json::from_slice::<Value>(&frame) {
                        Ok(message) if valid_message(&message) => message,
                        _ => {
                            set_terminal(&reader_terminal, ProcessError::Malformed);
                            break;
                        }
                    };
                    if outputs.try_send(message).is_err() {
                        set_terminal(&reader_terminal, ProcessError::QueueOverflow);
                        break;
                    }
                }
            });
            let writer_cancel = cancel.clone();
            let writer = thread::spawn(move || {
                while let Ok((frame, acknowledgement)) = writes.recv() {
                    let result = if writer_cancel.load(Ordering::Acquire) {
                        Err(ProcessError::Cancelled)
                    } else {
                        stdin
                            .write_all(&frame)
                            .and_then(|_| stdin.flush())
                            .map_err(|_| ProcessError::Io)
                    };
                    let failed = result.is_err();
                    let _ = acknowledgement.try_send(result);
                    if failed {
                        break;
                    }
                }
            });
            let mut process = Self {
                child,
                job,
                identity,
                cancel,
                input: Some(input),
                output,
                terminal,
                initial: VecDeque::new(),
                reader: Some(reader),
                writer: Some(writer),
                receipt: None,
            };
            // write_frame rechecks cancellation after Job assignment, before work.
            let startup = process
                .write_frame(b"K31_OWNED_START\n".to_vec(), CLEANUP_LIMIT)
                .and_then(|_| process.receive(CLEANUP_LIMIT))
                .and_then(|ready| {
                    if ready["method"] != "fixture/ready" {
                        return Err(ProcessError::Startup);
                    }
                    process.initial.push_back(ready);
                    Ok(())
                });
            if let Err(error) = startup {
                let identity = process.identity();
                process.shutdown(&identity, CLEANUP_LIMIT)?;
                return Err(if error == ProcessError::Cancelled {
                    error
                } else {
                    ProcessError::Startup
                });
            }
            Ok(process)
        }
    }
    pub(crate) fn identity(&self) -> ProcessIdentity {
        self.identity.clone()
    }
    fn operation_check(&self, deadline: Instant) -> Result<(), ProcessError> {
        if self.cancel.load(Ordering::Acquire) {
            return Err(ProcessError::Cancelled);
        }
        if self.receipt.is_some() {
            return Err(ProcessError::Eof);
        }
        if Instant::now() >= deadline {
            return Err(ProcessError::Deadline);
        }
        Ok(())
    }
    fn write_frame(&mut self, frame: Vec<u8>, timeout: Duration) -> Result<(), ProcessError> {
        let result = self.write_frame_inner(frame, timeout);
        if let Err(error) = result {
            // A timed-out/cancelled pipe write may already have delivered bytes.
            // Never retry or enqueue more work on that uncertain stream. Only
            // own-job teardown can make cleanup safe; retain valid queued output.
            set_terminal(&self.terminal, error);
            self.input.take();
        }
        result
    }
    fn write_frame_inner(&mut self, frame: Vec<u8>, timeout: Duration) -> Result<(), ProcessError> {
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or(ProcessError::Deadline)?;
        let (acknowledgement, result) = mpsc::sync_channel(1);
        let mut request = (frame, acknowledgement);
        loop {
            self.operation_check(deadline)?;
            match self
                .input
                .as_ref()
                .ok_or(ProcessError::Eof)?
                .try_send(request)
            {
                Ok(()) => break,
                Err(TrySendError::Full(returned)) => request = returned,
                Err(TrySendError::Disconnected(_)) => return Err(ProcessError::Io),
            }
            thread::sleep(TICK.min(deadline.saturating_duration_since(Instant::now())));
        }
        loop {
            self.operation_check(deadline)?;
            match result.try_recv() {
                Ok(result) => return result,
                Err(TryRecvError::Disconnected) => return Err(ProcessError::Io),
                Err(TryRecvError::Empty) => {
                    thread::sleep(TICK.min(deadline.saturating_duration_since(Instant::now())))
                }
            }
        }
    }
    pub(crate) fn send(&mut self, message: Value, timeout: Duration) -> Result<(), ProcessError> {
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or(ProcessError::Deadline)?;
        self.operation_check(deadline)?;
        if let Some(error) = terminal_error(&self.terminal) {
            return Err(error);
        }
        if !valid_message(&message) {
            return Err(ProcessError::InvalidMessage);
        }
        let frame = encode_frame(&message, &self.cancel, deadline)?;
        self.write_frame(frame, deadline.saturating_duration_since(Instant::now()))
    }
    pub(crate) fn receive(&mut self, timeout: Duration) -> Result<Value, ProcessError> {
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or(ProcessError::Deadline)?;
        loop {
            self.operation_check(deadline)?;
            if let Some(initial) = self.initial.pop_front() {
                return Ok(initial);
            }
            match self.output.try_recv() {
                Ok(message) => return Ok(message),
                Err(TryRecvError::Disconnected) => {
                    return Err(terminal_error(&self.terminal).unwrap_or(ProcessError::Eof))
                }
                Err(TryRecvError::Empty) => {
                    if let Some(error) = terminal_error(&self.terminal) {
                        return Err(error);
                    }
                    thread::sleep(TICK.min(deadline.saturating_duration_since(Instant::now())));
                }
            }
        }
    }
    pub(crate) fn shutdown(
        &mut self,
        expected: &ProcessIdentity,
        timeout: Duration,
    ) -> Result<CleanupReceipt, ProcessError> {
        if expected != &self.identity {
            return Err(ProcessError::ForeignIdentity);
        }
        if let Some(receipt) = &self.receipt {
            return Ok(receipt.clone());
        }
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or(ProcessError::Cleanup)?;
        self.input.take();
        #[cfg(windows)]
        self.job.terminate()?;
        #[cfg(not(windows))]
        self.child.kill().map_err(|_| ProcessError::Cleanup)?;
        loop {
            let reaped = self
                .child
                .try_wait()
                .map_err(|_| ProcessError::Cleanup)?
                .is_some();
            #[cfg(windows)]
            let tree_dead = self.job.is_empty()?;
            #[cfg(not(windows))]
            let tree_dead = reaped;
            let reader_done = self.reader.as_ref().is_none_or(JoinHandle::is_finished);
            let writer_done = self.writer.as_ref().is_none_or(JoinHandle::is_finished);
            if reaped && tree_dead && reader_done && writer_done {
                if let Some(reader) = self.reader.take() {
                    reader.join().map_err(|_| ProcessError::Cleanup)?;
                }
                if let Some(writer) = self.writer.take() {
                    writer.join().map_err(|_| ProcessError::Cleanup)?;
                }
                let receipt = CleanupReceipt {
                    identity: self.identity.clone(),
                };
                self.receipt = Some(receipt.clone());
                return Ok(receipt);
            }
            if Instant::now() >= deadline {
                return Err(ProcessError::Cleanup);
            }
            thread::sleep(TICK.min(deadline.saturating_duration_since(Instant::now())));
        }
    }
}
impl Drop for TaskProcess {
    fn drop(&mut self) {
        if self.receipt.is_none() {
            let identity = self.identity();
            // Explicit callers must inspect shutdown. Drop cannot return errors;
            // Job close remains an own-tree kill fallback on unconfirmed cleanup.
            let _ = self.shutdown(&identity, CLEANUP_LIMIT);
        }
    }
}

#[cfg(all(test, windows))]
mod tests;
