//! Current-user local control protocol. No bearer, model or raw-RPC action.
use crate::helper_host::{HostConfig, HostError, TargetIdentity};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, time::Instant};

pub(crate) const MAX_CONTROL_FRAME: usize = 16 * 1024;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ControlRequest {
    pub version: u32,
    pub request_id: u64,
    pub action: ControlAction,
}

#[derive(Serialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum ControlAction {
    Status,
    Live,
    Switch {
        #[serde(rename = "sourceId")]
        source_id: String,
        #[serde(rename = "profilesRoot")]
        profiles_root: PathBuf,
    },
    Quota {
        #[serde(rename = "sourceId")]
        source_id: String,
        #[serde(rename = "profilesRoot")]
        profiles_root: PathBuf,
        #[serde(default)]
        details: bool,
    },
    Cancel,
    Reconcile,
    StopUnowned,
}

impl<'de> Deserialize<'de> for ControlAction {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Empty struct variants enforce the same field rejection for Status
        // and Cancel as for the variants that carry parameters.
        #[derive(Deserialize)]
        #[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
        enum Fields {
            Status {},
            Live {},
            Switch {
                #[serde(rename = "sourceId")]
                source_id: String,
                #[serde(rename = "profilesRoot")]
                profiles_root: PathBuf,
            },
            Quota {
                #[serde(rename = "sourceId")]
                source_id: String,
                #[serde(rename = "profilesRoot")]
                profiles_root: PathBuf,
                #[serde(default)]
                details: bool,
            },
            Cancel {},
            Reconcile {},
            StopUnowned {},
        }
        Ok(match Fields::deserialize(deserializer)? {
            Fields::Status {} => Self::Status,
            Fields::Live {} => Self::Live,
            Fields::Switch {
                source_id,
                profiles_root,
            } => Self::Switch {
                source_id,
                profiles_root,
            },
            Fields::Quota {
                source_id,
                profiles_root,
                details,
            } => Self::Quota {
                source_id,
                profiles_root,
                details,
            },
            Fields::Cancel {} => Self::Cancel,
            Fields::Reconcile {} => Self::Reconcile,
            Fields::StopUnowned {} => Self::StopUnowned,
        })
    }
}

/// Independent of the control label: one target identity has one helper owner.
pub(crate) struct TargetReservation {
    #[cfg(windows)]
    _handle: local_pipe::OwnedHandle,
}

impl TargetReservation {
    pub(crate) fn acquire(target: TargetIdentity) -> Result<Self, HostError> {
        validate_target(target)?;
        #[cfg(windows)]
        {
            Ok(Self {
                _handle: local_pipe::reserve(target)?,
            })
        }
        #[cfg(not(windows))]
        {
            Err(HostError::Unsupported)
        }
    }
}

pub(crate) struct ControlServer {
    #[cfg(windows)]
    inner: local_pipe::Server,
}

impl ControlServer {
    pub(crate) fn bind(config: &HostConfig) -> Result<Self, HostError> {
        validate_config(config)?;
        #[cfg(windows)]
        {
            Ok(Self {
                inner: local_pipe::Server::bind(config)?,
            })
        }
        #[cfg(not(windows))]
        {
            Err(HostError::Unsupported)
        }
    }

    pub(crate) fn poll(&mut self) -> Result<Option<ControlRequest>, HostError> {
        #[cfg(windows)]
        {
            self.inner.poll()
        }
        #[cfg(not(windows))]
        {
            Err(HostError::Unsupported)
        }
    }

    pub(crate) fn respond(&mut self, reply: &serde_json::Value) -> Result<(), HostError> {
        #[cfg(windows)]
        {
            self.inner.respond(reply)
        }
        #[cfg(not(windows))]
        {
            let _ = reply;
            Err(HostError::Unsupported)
        }
    }

    // Only used after an accepted StopUnowned, while no provider needs refresh.
    // Keep the queued response alive until the one client reads and disconnects.
    pub(crate) fn finish_stop_reply(&mut self, deadline: Instant) -> Result<(), HostError> {
        #[cfg(windows)]
        {
            self.inner.finish_stop_reply(deadline)
        }
        #[cfg(not(windows))]
        {
            let _ = deadline;
            Err(HostError::Unsupported)
        }
    }
}

pub(crate) fn request(
    config: &HostConfig,
    request: ControlRequest,
    deadline: Instant,
) -> Result<serde_json::Value, HostError> {
    validate_config(config)?;
    if request.version != 1 {
        return Err(HostError::InvalidRequest);
    }
    #[cfg(windows)]
    {
        local_pipe::request(config, &request, deadline)
    }
    #[cfg(not(windows))]
    {
        let _ = deadline;
        Err(HostError::Unsupported)
    }
}

fn validate_target(target: TargetIdentity) -> Result<(), HostError> {
    if target.pid == 0 || target.creation_file_time == 0 {
        return Err(HostError::InvalidTarget);
    }
    Ok(())
}

fn validate_config(config: &HostConfig) -> Result<(), HostError> {
    validate_target(config.target)?;
    if !(16..=64).contains(&config.control_label.len())
        || !config
            .control_label
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(HostError::InvalidRequest);
    }
    Ok(())
}

// The existing Windows dependency does not enable named-pipe or SDDL helpers.
// Keep this small ABI surface local instead of broadening Cargo features.
#[cfg(windows)]
mod local_pipe {
    use super::*;
    use serde::de::DeserializeOwned;
    use std::{ffi::c_void, mem, ptr, thread, time::Duration};

    type Handle = *mut c_void;
    const INVALID_HANDLE: Handle = -1isize as Handle;
    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_BROKEN_PIPE: u32 = 109;
    const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
    const ERROR_ALREADY_EXISTS: u32 = 183;
    const ERROR_MORE_DATA: u32 = 234;
    const ERROR_PIPE_BUSY: u32 = 231;
    const ERROR_NO_DATA: u32 = 232;
    const ERROR_PIPE_NOT_CONNECTED: u32 = 233;
    const ERROR_PIPE_CONNECTED: u32 = 535;
    const ERROR_PIPE_LISTENING: u32 = 536;
    const ERROR_FILE_NOT_FOUND: u32 = 2;
    const PIPE_READMODE_MESSAGE: u32 = 2;
    const PIPE_NOWAIT: u32 = 1;
    const WIRE_LIMIT: usize = MAX_CONTROL_FRAME + 4;
    const CONNECTION_LEASE: Duration = Duration::from_secs(2);

    #[repr(C)]
    struct SecurityAttributes {
        length: u32,
        descriptor: *mut c_void,
        inherit_handle: i32,
    }

    #[repr(C)]
    struct SidAndAttributes {
        sid: *mut c_void,
        attributes: u32,
    }

    #[repr(C)]
    struct TokenUser {
        user: SidAndAttributes,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CloseHandle(handle: Handle) -> i32;
        fn GetCurrentProcess() -> Handle;
        fn GetLastError() -> u32;
        fn SetLastError(error: u32);
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
        fn CreateMutexW(
            attributes: *const SecurityAttributes,
            owner: i32,
            name: *const u16,
        ) -> Handle;
        fn CreateNamedPipeW(
            name: *const u16,
            open_mode: u32,
            pipe_mode: u32,
            instances: u32,
            output_size: u32,
            input_size: u32,
            timeout: u32,
            attributes: *const SecurityAttributes,
        ) -> Handle;
        fn ConnectNamedPipe(pipe: Handle, overlapped: *mut c_void) -> i32;
        fn DisconnectNamedPipe(pipe: Handle) -> i32;
        fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            attributes: *const SecurityAttributes,
            disposition: u32,
            flags: u32,
            template: Handle,
        ) -> Handle;
        fn SetNamedPipeHandleState(
            pipe: Handle,
            mode: *const u32,
            collection_count: *const u32,
            collection_timeout: *const u32,
        ) -> i32;
        fn ReadFile(
            handle: Handle,
            buffer: *mut c_void,
            length: u32,
            read: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
        fn WriteFile(
            handle: Handle,
            buffer: *const c_void,
            length: u32,
            written: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
    }

    #[link(name = "advapi32")]
    extern "system" {
        fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
        fn GetTokenInformation(
            token: Handle,
            class: u32,
            buffer: *mut c_void,
            length: u32,
            needed: *mut u32,
        ) -> i32;
        fn ConvertSidToStringSidW(sid: *mut c_void, text: *mut *mut u16) -> i32;
        fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text: *const u16,
            revision: u32,
            descriptor: *mut *mut c_void,
            size: *mut u32,
        ) -> i32;
    }

    pub(super) struct OwnedHandle(Handle);
    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    struct LocalAllocation(*mut c_void);
    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(Some(0)).collect()
    }

    /// Protected DACL with a single current-user ACE.
    fn current_user_descriptor() -> Result<LocalAllocation, HostError> {
        unsafe {
            let mut token = ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), 0x0008, &mut token) == 0 {
                return Err(HostError::Isolation);
            }
            let token = OwnedHandle(token);
            let mut needed = 0u32;
            if GetTokenInformation(token.0, 1, ptr::null_mut(), 0, &mut needed) != 0
                || GetLastError() != ERROR_INSUFFICIENT_BUFFER
                || needed < mem::size_of::<TokenUser>() as u32
                || needed > 64 * 1024
            {
                return Err(HostError::Isolation);
            }
            // usize storage keeps TOKEN_USER and the SID buffer aligned.
            let mut storage = vec![
                0usize;
                (needed as usize + mem::size_of::<usize>() - 1)
                    / mem::size_of::<usize>()
            ];
            if GetTokenInformation(token.0, 1, storage.as_mut_ptr().cast(), needed, &mut needed)
                == 0
            {
                return Err(HostError::Isolation);
            }
            let user = &*storage.as_ptr().cast::<TokenUser>();
            let mut sid_text = ptr::null_mut();
            if ConvertSidToStringSidW(user.user.sid, &mut sid_text) == 0 {
                return Err(HostError::Isolation);
            }
            let sid_text = LocalAllocation(sid_text.cast());
            let sid_wide = sid_text.0.cast::<u16>();
            let length = (0..256)
                .find(|index| *sid_wide.add(*index) == 0)
                .ok_or(HostError::Isolation)?;
            let sid = String::from_utf16(std::slice::from_raw_parts(sid_wide, length))
                .map_err(|_| HostError::Isolation)?;
            let sddl = wide(&format!("D:P(A;;GA;;;{sid})"));
            let mut descriptor = ptr::null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                ptr::null_mut(),
            ) == 0
            {
                return Err(HostError::Isolation);
            }
            Ok(LocalAllocation(descriptor))
        }
    }

    fn attributes(descriptor: &LocalAllocation) -> SecurityAttributes {
        SecurityAttributes {
            length: mem::size_of::<SecurityAttributes>() as u32,
            descriptor: descriptor.0,
            inherit_handle: 0,
        }
    }

    fn pipe_name(config: &HostConfig) -> Vec<u16> {
        wide(&format!(
            r"\\.\pipe\CodexTimeZone.RuntimeControl.v1.{}.{:016x}.{}",
            config.target.pid,
            config.target.creation_file_time,
            config.control_label.to_ascii_lowercase(),
        ))
    }

    pub(super) fn reserve(target: TargetIdentity) -> Result<OwnedHandle, HostError> {
        let descriptor = current_user_descriptor()?;
        let attributes = attributes(&descriptor);
        let name = wide(&format!(
            r"Local\CodexTimeZone.RuntimeOwner.v1.{}.{:016x}",
            target.pid, target.creation_file_time
        ));
        unsafe {
            SetLastError(0);
            // Object existence is the reservation. Closing releases it;
            // no thread-owned wait or target-process handle is needed.
            let raw = CreateMutexW(&attributes, 0, name.as_ptr());
            if raw.is_null() {
                return Err(HostError::Isolation);
            }
            let handle = OwnedHandle(raw);
            if GetLastError() == ERROR_ALREADY_EXISTS {
                return Err(HostError::SourceBusy);
            }
            Ok(handle)
        }
    }

    fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, HostError> {
        let json = serde_json::to_vec(value).map_err(|_| HostError::InvalidRequest)?;
        if json.is_empty() || json.len() > MAX_CONTROL_FRAME {
            return Err(HostError::InvalidRequest);
        }
        let mut frame = Vec::with_capacity(json.len() + 4);
        frame.extend_from_slice(&(json.len() as u32).to_le_bytes());
        frame.extend_from_slice(&json);
        Ok(frame)
    }

    fn decode<T: DeserializeOwned>(frame: &[u8]) -> Result<T, HostError> {
        let prefix: [u8; 4] = frame
            .get(..4)
            .ok_or(HostError::InvalidRequest)?
            .try_into()
            .map_err(|_| HostError::InvalidRequest)?;
        let size = u32::from_le_bytes(prefix) as usize;
        if size == 0 || size > MAX_CONTROL_FRAME || frame.len() != size + 4 {
            return Err(HostError::InvalidRequest);
        }
        serde_json::from_slice(&frame[4..]).map_err(|_| HostError::InvalidRequest)
    }

    // Message mode makes each bounded frame atomic. PIPE_NOWAIT applies to
    // both reads and writes, so a client cannot stall the host loop.
    fn read_frame(pipe: Handle) -> Result<Option<Vec<u8>>, HostError> {
        let mut frame = vec![0u8; WIRE_LIMIT];
        let mut read = 0;
        let result = unsafe {
            ReadFile(
                pipe,
                frame.as_mut_ptr().cast(),
                frame.len() as u32,
                &mut read,
                ptr::null_mut(),
            )
        };
        if result == 0 {
            return match unsafe { GetLastError() } {
                ERROR_NO_DATA => Ok(None),
                ERROR_MORE_DATA => Err(HostError::InvalidRequest),
                _ => Err(HostError::Unavailable),
            };
        }
        frame.truncate(read as usize);
        Ok(Some(frame))
    }

    fn write_frame(pipe: Handle, frame: &[u8]) -> Result<bool, HostError> {
        let mut written = 0;
        let result = unsafe {
            WriteFile(
                pipe,
                frame.as_ptr().cast(),
                frame.len() as u32,
                &mut written,
                ptr::null_mut(),
            )
        };
        if result == 0 {
            return Err(HostError::Unavailable);
        }
        if written == 0 {
            // Insufficient space for a nonblocking message writes zero bytes.
            return Ok(false);
        }
        if written as usize != frame.len() {
            return Err(HostError::Unavailable);
        }
        Ok(true)
    }

    pub(super) struct Server {
        pipe: OwnedHandle,
        connected: bool,
        delivered: bool,
        replied: bool,
        pending_reply: Option<Vec<u8>>,
        client_deadline: Option<Instant>,
    }

    impl Server {
        pub(super) fn bind(config: &HostConfig) -> Result<Self, HostError> {
            let descriptor = current_user_descriptor()?;
            let attributes = attributes(&descriptor);
            let name = pipe_name(config);
            let raw = unsafe {
                CreateNamedPipeW(
                    name.as_ptr(),
                    0x0000_0003 | 0x0008_0000, // DUPLEX | FIRST_PIPE_INSTANCE
                    0x0000_0004 | PIPE_READMODE_MESSAGE | PIPE_NOWAIT | 0x0000_0008, // MESSAGE | REJECT_REMOTE_CLIENTS
                    1,
                    WIRE_LIMIT as u32,
                    WIRE_LIMIT as u32,
                    0,
                    &attributes,
                )
            };
            if raw == INVALID_HANDLE {
                return Err(if unsafe { GetLastError() } == ERROR_ACCESS_DENIED {
                    HostError::Isolation
                } else {
                    HostError::Unavailable
                });
            }
            Ok(Self {
                pipe: OwnedHandle(raw),
                connected: false,
                delivered: false,
                replied: false,
                pending_reply: None,
                client_deadline: None,
            })
        }

        fn reset(&mut self) {
            unsafe {
                DisconnectNamedPipe(self.pipe.0);
            }
            self.connected = false;
            self.delivered = false;
            self.replied = false;
            self.pending_reply = None;
            self.client_deadline = None;
        }

        fn write_pending(&mut self) -> Result<(), HostError> {
            if let Some(frame) = &self.pending_reply {
                if write_frame(self.pipe.0, frame)? {
                    self.pending_reply = None;
                    self.replied = true;
                }
            }
            Ok(())
        }

        pub(super) fn poll(&mut self) -> Result<Option<ControlRequest>, HostError> {
            if !self.connected {
                let result = unsafe { ConnectNamedPipe(self.pipe.0, ptr::null_mut()) };
                if result == 0 {
                    match unsafe { GetLastError() } {
                        ERROR_PIPE_CONNECTED => {}
                        ERROR_PIPE_LISTENING => return Ok(None),
                        ERROR_NO_DATA | ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED => {
                            self.reset();
                            return Ok(None);
                        }
                        _ => {
                            self.reset();
                            return Err(HostError::Unavailable);
                        }
                    }
                }
                self.connected = true;
                self.client_deadline = Some(Instant::now() + CONNECTION_LEASE);
            }
            if self
                .client_deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
            {
                self.reset();
                return Err(HostError::Timeout);
            }
            if let Err(error) = self.write_pending() {
                self.reset();
                return Err(error);
            }
            let frame = match read_frame(self.pipe.0) {
                Ok(Some(frame)) => frame,
                Ok(None) => return Ok(None),
                Err(error) => {
                    self.reset();
                    return Err(error);
                }
            };
            if self.delivered || self.replied {
                self.reset();
                return Err(HostError::InvalidRequest);
            }
            let request: ControlRequest = match decode(&frame) {
                Ok(request) => request,
                Err(error) => {
                    // Let the host send only its fixed invalid-request reply.
                    self.delivered = true;
                    return Err(error);
                }
            };
            self.delivered = true;
            if request.version != 1 {
                return Err(HostError::InvalidRequest);
            }
            Ok(Some(request))
        }

        pub(super) fn respond(&mut self, reply: &serde_json::Value) -> Result<(), HostError> {
            if !self.connected || !self.delivered || self.replied || self.pending_reply.is_some() {
                return Err(HostError::InvalidRequest);
            }
            self.pending_reply = Some(encode(reply)?);
            if let Err(error) = self.write_pending() {
                self.reset();
                return Err(error);
            }
            // DisconnectNamedPipe discards unread output. Retain this slot
            // until the client reads and drops, or its short lease expires.
            // No blocking FlushFileBuffers is used.
            Ok(())
        }

        pub(super) fn finish_stop_reply(&mut self, deadline: Instant) -> Result<(), HostError> {
            if !self.connected || !self.delivered {
                return Err(HostError::InvalidRequest);
            }
            loop {
                if Instant::now() >= deadline {
                    self.reset();
                    return Err(HostError::Timeout);
                }
                if let Err(error) = self.write_pending() {
                    self.reset();
                    return Err(error);
                }
                match read_frame(self.pipe.0) {
                    Ok(None) => {}
                    Err(HostError::Unavailable) if self.replied => {
                        // request() closes only after it has read/validated the
                        // reply. Never use blocking FlushFileBuffers here.
                        self.reset();
                        return Ok(());
                    }
                    Err(error) => {
                        self.reset();
                        return Err(error);
                    }
                    Ok(Some(_)) => {
                        self.reset();
                        return Err(HostError::InvalidRequest);
                    }
                }
                pause(deadline)?;
            }
        }
    }

    impl Drop for Server {
        fn drop(&mut self) {
            self.reset();
        }
    }

    fn pause(deadline: Instant) -> Result<(), HostError> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(HostError::Timeout)?;
        if remaining.is_zero() {
            return Err(HostError::Timeout);
        }
        thread::sleep(remaining.min(Duration::from_millis(5)));
        Ok(())
    }

    pub(super) fn request(
        config: &HostConfig,
        request: &ControlRequest,
        deadline: Instant,
    ) -> Result<serde_json::Value, HostError> {
        let frame = encode(request)?;
        let name = pipe_name(config);
        let pipe = loop {
            if Instant::now() >= deadline {
                return Err(HostError::Timeout);
            }
            let raw = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    0xc000_0000,
                    0,
                    ptr::null(),
                    3,
                    0,
                    ptr::null_mut(),
                )
            };
            if raw != INVALID_HANDLE {
                break OwnedHandle(raw);
            }
            match unsafe { GetLastError() } {
                ERROR_FILE_NOT_FOUND
                | ERROR_PIPE_BUSY
                | ERROR_NO_DATA
                | ERROR_PIPE_NOT_CONNECTED => pause(deadline)?,
                ERROR_ACCESS_DENIED => return Err(HostError::Isolation),
                _ => return Err(HostError::Unavailable),
            }
        };
        let mode = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
        if unsafe { SetNamedPipeHandleState(pipe.0, &mode, ptr::null(), ptr::null()) } == 0 {
            return Err(HostError::Isolation);
        }
        loop {
            if Instant::now() >= deadline {
                return Err(HostError::Timeout);
            }
            if write_frame(pipe.0, &frame)? {
                break;
            }
            pause(deadline)?;
        }
        loop {
            if Instant::now() >= deadline {
                return Err(HostError::Timeout);
            }
            match read_frame(pipe.0)? {
                Some(reply) => {
                    let reply: serde_json::Value = decode(&reply)?;
                    if reply.get("version").and_then(serde_json::Value::as_u64) != Some(1)
                        || reply.get("requestId").and_then(serde_json::Value::as_u64)
                            != Some(request.request_id)
                    {
                        return Err(HostError::InvalidRequest);
                    }
                    return Ok(reply);
                }
                None => pause(deadline)?,
            }
        }
    }
}
