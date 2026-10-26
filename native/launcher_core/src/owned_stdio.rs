//! Production Windows child ownership. No shell, PID-based control, or daemon reuse.
use std::{collections::BTreeMap, ffi::OsString, path::Path, time::Duration};
pub(crate) const FRAME_LIMIT: usize = 1_048_576;
pub(crate) struct StartFailure {
    pub kind: &'static str,
    pub retained: Option<OwnedStdio>,
}
#[cfg(windows)]
mod platform {
    use super::*;
    use std::{
        ffi::c_void,
        fs::File,
        io::{BufRead, BufReader, Read, Write},
        mem::{size_of, zeroed},
        os::windows::{ffi::OsStrExt, io::FromRawHandle},
        ptr::{null, null_mut},
        sync::{
            atomic::{AtomicBool, Ordering},
            mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
            Arc, Mutex,
        },
        thread::{self, JoinHandle},
        time::Instant,
    };
    type H = *mut c_void;
    #[repr(C)]
    struct Security {
        length: u32,
        descriptor: H,
        inherit: i32,
    }
    #[repr(C)]
    struct Startup {
        size: u32,
        reserved: *mut u16,
        desktop: *mut u16,
        title: *mut u16,
        x: u32,
        y: u32,
        xsize: u32,
        ysize: u32,
        xchars: u32,
        ychars: u32,
        fill: u32,
        flags: u32,
        show: u16,
        reserved_len: u16,
        reserved_ptr: *mut u8,
        input: H,
        output: H,
        error: H,
    }
    #[repr(C)]
    struct StartupEx {
        startup: Startup,
        attributes: H,
    }
    #[repr(C)]
    struct ProcessInfo {
        process: H,
        thread: H,
        pid: u32,
        tid: u32,
    }
    #[repr(C)]
    struct BasicLimit {
        process_time: i64,
        job_time: i64,
        flags: u32,
        min_work: usize,
        max_work: usize,
        active: u32,
        affinity: usize,
        priority: u32,
        scheduling: u32,
    }
    #[repr(C)]
    struct ExtendedLimit {
        basic: BasicLimit,
        io: [u64; 6],
        process_mem: usize,
        job_mem: usize,
        peak_process: usize,
        peak_job: usize,
    }
    #[repr(C)]
    struct Accounting {
        process_time: i64,
        job_time: i64,
        period_process: i64,
        period_job: i64,
        faults: u32,
        total: u32,
        active: u32,
        terminated: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateJobObjectW(attributes: H, name: *const u16) -> H;
        fn SetInformationJobObject(job: H, class: u32, info: *const c_void, len: u32) -> i32;
        fn AssignProcessToJobObject(job: H, process: H) -> i32;
        fn TerminateJobObject(job: H, code: u32) -> i32;
        fn QueryInformationJobObject(
            job: H,
            class: u32,
            info: *mut c_void,
            len: u32,
            returned: H,
        ) -> i32;
        fn CreatePipe(read: *mut H, write: *mut H, attributes: *const Security, size: u32) -> i32;
        fn SetHandleInformation(handle: H, mask: u32, flags: u32) -> i32;
        fn CreateFileW(
            path: *const u16,
            access: u32,
            share: u32,
            security: *const Security,
            creation: u32,
            flags: u32,
            template: H,
        ) -> H;
        fn InitializeProcThreadAttributeList(
            list: H,
            count: u32,
            flags: u32,
            size: *mut usize,
        ) -> i32;
        fn UpdateProcThreadAttribute(
            list: H,
            flags: u32,
            attribute: usize,
            value: *const c_void,
            size: usize,
            previous: H,
            returned: *mut usize,
        ) -> i32;
        fn DeleteProcThreadAttributeList(list: H);
        fn CreateProcessW(
            application: *const u16,
            command: *mut u16,
            process_attributes: *const c_void,
            thread_attributes: *const c_void,
            inherit: i32,
            flags: u32,
            environment: *const c_void,
            cwd: *const u16,
            startup: *const Startup,
            info: *mut ProcessInfo,
        ) -> i32;
        fn ResumeThread(thread: H) -> u32;
        fn TerminateProcess(process: H, code: u32) -> i32;
        fn WaitForSingleObject(handle: H, milliseconds: u32) -> u32;
        fn CloseHandle(handle: H) -> i32;
    }
    struct Handle(H);
    unsafe impl Send for Handle {}
    impl Handle {
        fn empty() -> Self {
            Self(null_mut())
        }
        fn take(&mut self) -> H {
            std::mem::replace(&mut self.0, null_mut())
        }
    }
    impl Drop for Handle {
        fn drop(&mut self) {
            if !self.0.is_null() && self.0 as isize != -1 {
                unsafe {
                    CloseHandle(self.0);
                }
            }
        }
    }
    fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
        value.encode_wide().chain(Some(0)).collect()
    }
    fn quote(value: &std::ffi::OsStr) -> String {
        let mut result = String::from("\"");
        let mut slashes = 0;
        for ch in value.to_string_lossy().chars() {
            match ch {
                '\\' => slashes += 1,
                '"' => {
                    result.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
                    result.push(ch);
                    slashes = 0;
                }
                _ => {
                    result.extend(std::iter::repeat_n('\\', slashes));
                    result.push(ch);
                    slashes = 0;
                }
            }
        }
        result.extend(std::iter::repeat_n('\\', slashes * 2));
        result.push('"');
        result
    }
    type WriteRequest = (Vec<u8>, SyncSender<Result<(), &'static str>>);
    pub(crate) struct OwnedStdio {
        process: Handle,
        job: Handle,
        input: Option<SyncSender<WriteRequest>>,
        output: Receiver<Vec<u8>>,
        fault: Arc<Mutex<Option<&'static str>>>,
        stop: Arc<AtomicBool>,
        reader: Option<JoinHandle<()>>,
        writer: Option<JoinHandle<()>>,
        cleaned: bool,
    }
    impl OwnedStdio {
        pub(crate) fn start(
            executable: &Path,
            args: &[String],
            cwd: &Path,
            environment: &BTreeMap<OsString, OsString>,
        ) -> Result<Self, StartFailure> {
            let (out_tx, output) = mpsc::sync_channel(32);
            let (input, in_rx) = mpsc::sync_channel::<WriteRequest>(1);
            let fault = Arc::new(Mutex::new(None));
            let stop = Arc::new(AtomicBool::new(false));
            let mut child = Self {
                process: Handle::empty(),
                job: Handle::empty(),
                input: Some(input),
                output,
                fault: fault.clone(),
                stop: stop.clone(),
                reader: None,
                writer: None,
                cleaned: false,
            };
            let mut stage = "inputs";
            let launch = (|| -> Result<(), &'static str> {
                if !executable.is_absolute() || !cwd.is_absolute() {
                    return Err("startup_failed");
                }
                let executable_w = wide(executable.as_os_str());
                let cwd_w = wide(cwd.as_os_str());
                if executable_w[..executable_w.len() - 1].contains(&0)
                    || cwd_w[..cwd_w.len() - 1].contains(&0)
                {
                    return Err("startup_failed");
                }
                let mut command = quote(executable.as_os_str());
                for arg in args {
                    if arg.contains('\0') {
                        return Err("startup_failed");
                    }
                    command.push(' ');
                    command.push_str(&quote(std::ffi::OsStr::new(arg)));
                }
                let mut command = wide(std::ffi::OsStr::new(&command));
                if command.len() > 32767 {
                    return Err("startup_failed");
                }
                stage = "environment";
                let mut pairs = environment.iter().collect::<Vec<_>>();
                pairs.sort_by_key(|(k, _)| k.to_string_lossy().to_uppercase());
                let mut block = Vec::<u16>::new();
                let mut prior = String::new();
                for (key, value) in pairs {
                    let key = key.to_string_lossy();
                    if key.is_empty() || key.contains(['=', '\0']) || key.to_uppercase() == prior {
                        #[cfg(test)]
                        eprintln!(
                            "owned_environment_rejected category={}",
                            if key.is_empty() {
                                "empty"
                            } else if key.contains('\0') {
                                "nul"
                            } else if key.contains('=') {
                                "equals"
                            } else {
                                "case_duplicate"
                            }
                        );
                        return Err("startup_failed");
                    }
                    prior = key.to_uppercase();
                    block.extend(key.encode_utf16());
                    block.push('=' as u16);
                    let value = value.encode_wide().collect::<Vec<_>>();
                    if value.contains(&0) {
                        return Err("startup_failed");
                    }
                    block.extend(value);
                    block.push(0);
                }
                block.push(0);
                if block.len() == 1 {
                    block.push(0)
                }
                unsafe {
                    stage = "job_create";
                    child.job = Handle(CreateJobObjectW(null_mut(), null()));
                    if child.job.0.is_null() {
                        return Err("startup_failed");
                    }
                    let mut limits: ExtendedLimit = zeroed();
                    limits.basic.flags = 0x2000;
                    stage = "job_limits";
                    if SetInformationJobObject(
                        child.job.0,
                        9,
                        &limits as *const _ as _,
                        size_of::<ExtendedLimit>() as u32,
                    ) == 0
                    {
                        return Err("startup_failed");
                    }
                    let security = Security {
                        length: size_of::<Security>() as u32,
                        descriptor: null_mut(),
                        inherit: 1,
                    };
                    let mut stdin_read = Handle::empty();
                    let mut stdin_write = Handle::empty();
                    let mut stdout_read = Handle::empty();
                    let mut stdout_write = Handle::empty();
                    stage = "pipes";
                    if CreatePipe(&mut stdin_read.0, &mut stdin_write.0, &security, 0) == 0
                        || CreatePipe(&mut stdout_read.0, &mut stdout_write.0, &security, 0) == 0
                    {
                        return Err("startup_failed");
                    }
                    stage = "pipe_inheritance";
                    if SetHandleInformation(stdin_write.0, 1, 0) == 0
                        || SetHandleInformation(stdout_read.0, 1, 0) == 0
                    {
                        return Err("startup_failed");
                    }
                    stage = "stderr";
                    let stderr = Handle(CreateFileW(
                        wide(std::ffi::OsStr::new("NUL")).as_ptr(),
                        0x40000000,
                        3,
                        &security,
                        3,
                        0,
                        null_mut(),
                    ));
                    if stderr.0.is_null() || stderr.0 as isize == -1 {
                        return Err("startup_failed");
                    }
                    let mut length = 0;
                    InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut length);
                    let mut storage = vec![0usize; length.div_ceil(size_of::<usize>())];
                    let attributes = storage.as_mut_ptr() as H;
                    stage = "attributes";
                    if InitializeProcThreadAttributeList(attributes, 1, 0, &mut length) == 0 {
                        return Err("startup_failed");
                    }
                    struct Attributes(H);
                    impl Drop for Attributes {
                        fn drop(&mut self) {
                            unsafe { DeleteProcThreadAttributeList(self.0) }
                        }
                    }
                    let _attributes = Attributes(attributes);
                    let mut inherited = [stdin_read.0, stdout_write.0, stderr.0];
                    stage = "handle_list";
                    if UpdateProcThreadAttribute(
                        attributes,
                        0,
                        0x20002,
                        inherited.as_mut_ptr() as _,
                        size_of::<[H; 3]>(),
                        null_mut(),
                        null_mut(),
                    ) == 0
                    {
                        return Err("startup_failed");
                    }
                    let mut startup: StartupEx = zeroed();
                    startup.startup.size = size_of::<StartupEx>() as u32;
                    startup.startup.flags = 0x100;
                    startup.startup.input = stdin_read.0;
                    startup.startup.output = stdout_write.0;
                    startup.startup.error = stderr.0;
                    startup.attributes = attributes;
                    let mut info: ProcessInfo = zeroed();
                    stage = "create_suspended";
                    if CreateProcessW(
                        executable_w.as_ptr(),
                        command.as_mut_ptr(),
                        null_mut(),
                        null_mut(),
                        1,
                        0x4 | 0x08000000 | 0x400 | 0x80000,
                        block.as_mut_ptr() as _,
                        cwd_w.as_ptr(),
                        &startup.startup,
                        &mut info,
                    ) == 0
                    {
                        return Err("startup_failed");
                    }
                    child.process = Handle(info.process);
                    let primary_thread = Handle(info.thread);
                    // Parent copies cannot keep the child's pipes alive after launch.
                    drop(stdin_read);
                    drop(stdout_write);
                    drop(stderr);
                    stage = "job_assign";
                    if AssignProcessToJobObject(child.job.0, child.process.0) == 0 {
                        return Err("startup_failed");
                    }
                    let reader_file = File::from_raw_handle(stdout_read.take());
                    let writer_file = File::from_raw_handle(stdin_write.take());
                    let reader_fault = fault.clone();
                    let reader_stop = stop.clone();
                    stage = "io_workers";
                    child.reader = Some(
                        thread::Builder::new()
                            .name("task-owned-stdout".into())
                            .spawn(move || {
                                let mut reader = BufReader::new(reader_file);
                                loop {
                                    let mut frame = Vec::new();
                                    let read = reader
                                        .by_ref()
                                        .take((FRAME_LIMIT + 2) as u64)
                                        .read_until(b'\n', &mut frame);
                                    let error = match read {
                                        Ok(0) => Some("disconnected"),
                                        Err(_) => Some("disconnected"),
                                        Ok(_) if frame.len() > FRAME_LIMIT + 1 => {
                                            Some("protocol_error")
                                        }
                                        Ok(_) if frame.last() != Some(&b'\n') => {
                                            Some("protocol_error")
                                        }
                                        _ => None,
                                    };
                                    if let Some(error) = error {
                                        *reader_fault.lock().unwrap() = Some(error);
                                        break;
                                    }
                                    frame.pop();
                                    if frame.last() == Some(&b'\r') {
                                        frame.pop();
                                    }
                                    if reader_stop.load(Ordering::SeqCst) {
                                        break;
                                    }
                                    match out_tx.try_send(frame) {
                                        Ok(()) => {}
                                        Err(TrySendError::Full(_)) => {
                                            *reader_fault.lock().unwrap() = Some("protocol_error");
                                            break;
                                        }
                                        Err(TrySendError::Disconnected(_)) => break,
                                    }
                                }
                            })
                            .map_err(|_| "startup_failed")?,
                    );
                    child.writer = Some(
                        thread::Builder::new()
                            .name("task-owned-stdin".into())
                            .spawn(move || {
                                let mut writer = writer_file;
                                while !stop.load(Ordering::SeqCst) {
                                    match in_rx.recv_timeout(Duration::from_millis(25)) {
                                        Ok((bytes, ack)) => {
                                            let result = writer
                                                .write_all(&bytes)
                                                .and_then(|_| writer.flush())
                                                .map_err(|_| "disconnected");
                                            let failed = result.is_err();
                                            let _ = ack.try_send(result);
                                            if failed {
                                                break;
                                            }
                                        }
                                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                                        Err(_) => break,
                                    }
                                }
                            })
                            .map_err(|_| "startup_failed")?,
                    );
                    stage = "resume";
                    if ResumeThread(primary_thread.0) == u32::MAX {
                        return Err("startup_failed");
                    }
                }
                Ok(())
            })();
            match launch {
                Ok(()) => Ok(child),
                Err(kind) => {
                    // Internal fake-only diagnostics: finite stage + numeric OS
                    // code, never environment values, paths or payloads.
                    #[cfg(test)]
                    eprintln!(
                        "owned_stdio_failure stage={stage} osCode={:?}",
                        std::io::Error::last_os_error().raw_os_error()
                    );
                    #[cfg(not(test))]
                    let _ = stage;
                    if child.cleanup(Duration::from_secs(3)) {
                        Err(StartFailure {
                            kind,
                            retained: None,
                        })
                    } else {
                        Err(StartFailure {
                            kind: "cleanup_failed",
                            retained: Some(child),
                        })
                    }
                }
            }
        }
        pub(crate) fn send(
            &mut self,
            mut bytes: Vec<u8>,
            budget: Duration,
        ) -> Result<(), &'static str> {
            if bytes.len() > FRAME_LIMIT || bytes.contains(&b'\n') || bytes.contains(&b'\r') {
                return Err("protocol_error");
            }
            bytes.push(b'\n');
            let (tx, rx) = mpsc::sync_channel(1);
            let end = Instant::now() + budget;
            let mut request = (bytes, tx);
            loop {
                if self.stop.load(Ordering::SeqCst) {
                    return Err("cancelled");
                }
                match self.input.as_ref().ok_or("disconnected")?.try_send(request) {
                    Ok(()) => break,
                    Err(TrySendError::Full(back)) => {
                        request = back;
                        if Instant::now() >= end {
                            return Err("timeout");
                        }
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(_) => return Err("disconnected"),
                }
            }
            rx.recv_timeout(end.saturating_duration_since(Instant::now()))
                .map_err(|_| "timeout")?
        }
        pub(crate) fn receive(&mut self, budget: Duration) -> Result<Vec<u8>, &'static str> {
            let end = Instant::now() + budget;
            loop {
                let fault = *self.fault.lock().unwrap();
                if fault.is_some_and(|fault| fault != "disconnected") {
                    return Err(fault.unwrap());
                }
                match self.output.try_recv() {
                    Ok(value) => return Ok(value),
                    Err(TryRecvError::Disconnected) => return Err("disconnected"),
                    Err(TryRecvError::Empty) => {}
                }
                if let Some(fault) = fault {
                    return Err(fault);
                }
                if self.stop.load(Ordering::SeqCst) {
                    return Err("cancelled");
                }
                if Instant::now() >= end {
                    return Err("timeout");
                }
                thread::sleep(Duration::from_millis(2));
            }
        }
        pub(crate) fn cleanup(&mut self, budget: Duration) -> bool {
            if self.cleaned {
                return true;
            }
            let end = Instant::now() + budget;
            self.stop.store(true, Ordering::SeqCst);
            self.input.take();
            unsafe {
                if !self.job.0.is_null() {
                    TerminateJobObject(self.job.0, 1);
                }
                if !self.process.0.is_null() {
                    TerminateProcess(self.process.0, 1);
                }
            }
            let reaped = self.process.0.is_null()
                || unsafe {
                    WaitForSingleObject(
                        self.process.0,
                        end.saturating_duration_since(Instant::now())
                            .as_millis()
                            .min(u32::MAX as u128) as u32,
                    ) == 0
                };
            let empty = loop {
                if self.job.0.is_null() {
                    break true;
                }
                let mut info: Accounting = unsafe { zeroed() };
                let queried = unsafe {
                    QueryInformationJobObject(
                        self.job.0,
                        1,
                        &mut info as *mut _ as _,
                        size_of::<Accounting>() as u32,
                        null_mut(),
                    )
                };
                if queried == 0 {
                    break false;
                }
                if info.active == 0 {
                    break true;
                }
                if Instant::now() >= end {
                    break false;
                }
                thread::sleep(Duration::from_millis(2));
            };
            for worker in [&mut self.reader, &mut self.writer] {
                while worker.as_ref().is_some_and(|worker| !worker.is_finished())
                    && Instant::now() < end
                {
                    thread::sleep(Duration::from_millis(2));
                }
                if worker.as_ref().is_some_and(JoinHandle::is_finished) {
                    let _ = worker.take().unwrap().join();
                }
            }
            self.cleaned = reaped && empty && self.reader.is_none() && self.writer.is_none();
            self.cleaned
        }
    }
    impl Drop for OwnedStdio {
        fn drop(&mut self) {
            if !self.cleaned {
                unsafe {
                    if !self.job.0.is_null() {
                        TerminateJobObject(self.job.0, 1);
                    }
                    if !self.process.0.is_null() {
                        TerminateProcess(self.process.0, 1);
                    }
                }
            }
        }
    }
}
#[cfg(windows)]
pub(crate) use platform::OwnedStdio;
#[cfg(not(windows))]
pub(crate) struct OwnedStdio;
#[cfg(not(windows))]
impl OwnedStdio {
    pub(crate) fn start(
        _: &Path,
        _: &[String],
        _: &Path,
        _: &BTreeMap<OsString, OsString>,
    ) -> Result<Self, StartFailure> {
        Err(StartFailure {
            kind: "unsupported",
            retained: None,
        })
    }
    pub(crate) fn send(&mut self, _: Vec<u8>, _: Duration) -> Result<(), &'static str> {
        Err("unsupported")
    }
    pub(crate) fn receive(&mut self, _: Duration) -> Result<Vec<u8>, &'static str> {
        Err("unsupported")
    }
    pub(crate) fn cleanup(&mut self, _: Duration) -> bool {
        true
    }
}
