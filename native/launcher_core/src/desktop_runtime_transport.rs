//! Private ABI2 bridge adapter. No bearer field crosses application dispatch.
use crate::helper_host::{HostError, TargetIdentity};
use crate::runtime_helper::*;
use serde::Serialize;
use std::{
    ffi::{c_char, c_void},
    mem::size_of,
    os::windows::ffi::OsStrExt,
    path::Path,
    ptr, thread,
    time::{Duration, Instant},
};

const OK: u32 = 1;
const EMPTY: u32 = 2;
const PENDING: u32 = 3;
const BUSY: u32 = 21;
const TARGET_EXITED: u32 = 19;
const COMPLETE: u32 = 4;
const ERROR: u32 = 2;
const INVALID: u32 = 64 | 1024;

#[repr(C)]
#[derive(Default)]
struct DesktopIdentity {
    bytes: u32,
    version: u32,
    owner_pid: u32,
    child_pid: u32,
    owner_creation: u64,
    child_creation: u64,
}
#[repr(C)]
#[derive(Default)]
struct State {
    bytes: u32,
    version: u32,
    owner_pid: u32,
    child_pid: u32,
    owner_creation: u64,
    child_creation: u64,
    attached: u32,
    target_alive: u32,
    write_ready: u32,
    coverage_unknown: u32,
    frames_observed: u32,
    event_drops: u32,
    iat_restored: u32,
    protection_restored: u32,
    writes_completed: u32,
    write_pending: u32,
    api_invariant: u32,
    pending_read_completed: u32,
}
#[repr(C)]
struct TypedId {
    kind: u32,
    length: u32,
    number: i64,
    text: [u8; 64],
}
#[repr(C)]
struct Event {
    kind: u32,
    method: u32,
    direction: u32,
    flags: u32,
    generation: u64,
    sequence: u64,
    observed_at_ms: u64,
    id: TypedId,
    rpc_error_code: i32,
    auth_mode: u32,
    account_type: u32,
    refresh_reason: u32,
    email_bytes: u32,
    plan_bytes: u32,
    account_id_bytes: u32,
    reply_type: u32,
    email: [u8; 320],
    plan: [u8; 64],
    account_id: [u8; 128],
}
#[repr(C)]
struct LiveEvent {
    generation: u64,
    sequence: u64,
    observed_at_ms: u64,
    kind: u32,
    lifecycle: u32,
    attention: u32,
    flags: u32,
    id: TypedId,
    thread_id: [u8; 64],
    turn_id: [u8; 64],
}
#[repr(C)]
#[derive(Default)]
struct LiveState {
    bytes: u32,
    version: u32,
    generation: u64,
    coverage: u32,
    drops: u32,
    published: u32,
    outstanding: u32,
    alive: u32,
    enabled: u32,
}
#[repr(C)]
struct BootstrapEvent {
    generation: u64,
    sequence: u64,
    observed_at_ms: u64,
    kind: u32,
    flags: u32,
    status: u32,
    attention: u32,
    id: TypedId,
    index: u32,
    count: u32,
    value_bytes: u32,
    error_code: i32,
    value: [u8; 64],
}
#[repr(C)]
#[derive(Default)]
struct BootstrapState {
    bytes: u32,
    version: u32,
    generation: u64,
    coverage: u32,
    drops: u32,
    published: u32,
    pages: u32,
    snapshots: u32,
    enabled: u32,
}
const _: () = assert!(size_of::<BootstrapEvent>() == 200 && size_of::<BootstrapState>() == 40);
const _: () = assert!(size_of::<LiveEvent>() == 248 && size_of::<LiveState>() == 40);
const _: () = assert!(
    size_of::<DesktopIdentity>() == 32
        && size_of::<State>() == 80
        && size_of::<TypedId>() == 80
        && size_of::<Event>() == 664
);
type Context = *mut c_void;
type Abi = unsafe extern "system" fn() -> u32;
type Discover = unsafe extern "system" fn(*mut DesktopIdentity) -> u32;
type Attach = unsafe extern "system" fn(*const u16, *mut Context) -> u32;
type ReadState = unsafe extern "system" fn(Context, *mut State) -> u32;
type Poll = unsafe extern "system" fn(Context, *mut Event) -> u32;
type Watermark = unsafe extern "system" fn(Context, *mut u64) -> u32;
type Register = unsafe extern "system" fn(Context, u32, *const TypedId, *mut u64) -> u32;
type Discard = unsafe extern "system" fn(Context, u64) -> u32;
type Write = unsafe extern "system" fn(Context, *const u8, u32) -> u32;
type Operation = unsafe extern "system" fn(Context) -> u32;
type Probe = unsafe extern "system" fn(Context, u32) -> u32;
type PollLive = unsafe extern "system" fn(Context, *mut LiveEvent, *mut LiveState) -> u32;
type PollBootstrap =
    unsafe extern "system" fn(Context, *mut BootstrapEvent, *mut BootstrapState) -> u32;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(path: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    fn FreeLibrary(module: *mut c_void) -> i32;
    fn GetTickCount64() -> u64;
}
#[link(name = "bcrypt")]
unsafe extern "system" {
    fn BCryptGenRandom(algorithm: *mut c_void, bytes: *mut u8, count: u32, flags: u32) -> i32;
}
struct Library(*mut c_void);
impl Drop for Library {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                FreeLibrary(self.0);
            }
        }
    }
}
struct Api {
    library: Library,
    discover: Discover,
    attach: Attach,
    state: ReadState,
    poll: Poll,
    watermark: Watermark,
    register: Register,
    discard: Discard,
    write: Write,
    finish: Operation,
    probe: Probe,
    stop: Operation,
    close: Operation,
    poll_live: PollLive,
    poll_bootstrap: Option<PollBootstrap>,
}
fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}
impl Api {
    fn open(path: &Path) -> Result<Self, HostError> {
        let library = Library(unsafe { LoadLibraryW(wide(path).as_ptr()) });
        if library.0.is_null() {
            return Err(HostError::Unsupported);
        }
        macro_rules! symbol {
            ($name:literal, $ty:ty) => {{
                let pointer =
                    unsafe { GetProcAddress(library.0, concat!($name, "\0").as_ptr().cast()) };
                if pointer.is_null() {
                    return Err(HostError::Unsupported);
                }
                unsafe { std::mem::transmute::<*mut c_void, $ty>(pointer) }
            }};
        }
        let abi = symbol!("CtzBridgeAbiVersion", Abi);
        if unsafe { abi() } != 2 {
            return Err(HostError::Unsupported);
        }
        let discover = symbol!("CtzBridgeDiscoverDesktop", Discover);
        let attach = symbol!("CtzBridgeAttachDesktop", Attach);
        let state = symbol!("CtzBridgeStatus", ReadState);
        let poll = symbol!("CtzBridgePollV2", Poll);
        let watermark = symbol!("CtzBridgeReadWatermark", Watermark);
        let register = symbol!("CtzBridgeRegisterRequest", Register);
        let discard = symbol!("CtzBridgeDiscardRequest", Discard);
        let write = symbol!("CtzBridgeWrite", Write);
        let finish = symbol!("CtzBridgeFinishWrite", Operation);
        let probe = symbol!("CtzBridgeProbeConnection", Probe);
        let stop = symbol!("CtzBridgeStop", Operation);
        let close = symbol!("CtzBridgeClose", Operation);
        let poll_live = symbol!("CtzBridgePollLive", PollLive);
        let bootstrap_pointer =
            unsafe { GetProcAddress(library.0, c"CtzBridgePollBootstrap".as_ptr()) };
        let poll_bootstrap = if bootstrap_pointer.is_null() {
            None
        } else {
            Some(unsafe { std::mem::transmute::<*mut c_void, PollBootstrap>(bootstrap_pointer) })
        };
        Ok(Self {
            library,
            discover,
            attach,
            state,
            poll,
            watermark,
            register,
            discard,
            write,
            finish,
            probe,
            stop,
            close,
            poll_live,
            poll_bootstrap,
        })
    }
}

pub(crate) fn discover() -> Result<TargetIdentity, HostError> {
    let executable = std::env::current_exe().map_err(|_| HostError::Unavailable)?;
    let directory = executable.parent().ok_or(HostError::Unavailable)?;
    let api = Api::open(&directory.join("codex_runtime_bridge.dll"))?;
    let mut identity = DesktopIdentity {
        bytes: 32,
        version: 1,
        ..Default::default()
    };
    if unsafe { (api.discover)(&mut identity) } != OK {
        return Err(HostError::InvalidTarget);
    }
    Ok(TargetIdentity {
        pid: identity.owner_pid,
        creation_file_time: identity.owner_creation,
    })
}

pub(crate) fn connect(target: TargetIdentity) -> Result<Box<dyn RuntimeTransport>, HostError> {
    let executable = std::env::current_exe().map_err(|_| HostError::Unavailable)?;
    let directory = executable.parent().ok_or(HostError::Unavailable)?;
    let api = Api::open(&directory.join("codex_runtime_bridge.dll"))?;
    let mut nonce = 0u64;
    if unsafe { BCryptGenRandom(ptr::null_mut(), (&mut nonce as *mut u64).cast(), 8, 2) } < 0
        || nonce == 0
    {
        return Err(HostError::Unavailable);
    }
    let mut transport = BridgeTransport {
        api,
        context: ptr::null_mut(),
        nonce,
    };
    let result = unsafe {
        (transport.api.attach)(
            wide(&directory.join("codex_desktop_observer.dll")).as_ptr(),
            &mut transport.context,
        )
    };
    if result != OK || transport.context.is_null() {
        return Err(HostError::Unsupported);
    }
    let state = transport.status().map_err(|_| HostError::Unavailable)?;
    if state.owner_pid != target.pid
        || state.owner_creation != target.creation_file_time
        || state.attached == 0
    {
        return Err(HostError::InvalidTarget);
    }
    if state.write_ready == 0 && unsafe { (transport.api.probe)(transport.context, 4000) } != OK {
        return Err(HostError::Unavailable);
    }
    let state = transport.status().map_err(|_| HostError::Unavailable)?;
    if state.write_ready == 0 || state.coverage_unknown != 0 {
        return Err(HostError::Unsupported);
    }
    Ok(Box::new(transport))
}

/// Test-only entry uses the separately built owned-Node export. The production
/// DLL has no such export and release code has no arbitrary-PID constructor.
#[cfg(test)]
pub(crate) fn connect_owned_for_test(
    directory: &Path,
    owner: TargetIdentity,
    child: TargetIdentity,
) -> Result<Box<dyn RuntimeTransport>, HostError> {
    #[repr(C)]
    struct OwnedTarget {
        owner_pid: u32,
        child_pid: u32,
        owner_created: u64,
        child_created: u64,
    }
    type AttachOwned =
        unsafe extern "system" fn(*const OwnedTarget, *const u16, *mut Context) -> u32;
    let api = Api::open(&directory.join("codex_runtime_bridge.dll"))?;
    let pointer = unsafe {
        GetProcAddress(
            api.library.0,
            c"CtzBridgeAttachOwnedProductionGate".as_ptr(),
        )
    };
    if pointer.is_null() {
        return Err(HostError::Unsupported);
    }
    let attach: AttachOwned = unsafe { std::mem::transmute(pointer) };
    let mut nonce = 0u64;
    if unsafe { BCryptGenRandom(ptr::null_mut(), (&mut nonce as *mut u64).cast(), 8, 2) } < 0
        || nonce == 0
    {
        return Err(HostError::Unavailable);
    }
    let mut transport = BridgeTransport {
        api,
        context: ptr::null_mut(),
        nonce,
    };
    let target = OwnedTarget {
        owner_pid: owner.pid,
        child_pid: child.pid,
        owner_created: owner.creation_file_time,
        child_created: child.creation_file_time,
    };
    if unsafe {
        attach(
            &target,
            wide(&directory.join("codex_desktop_observer.dll")).as_ptr(),
            &mut transport.context,
        )
    } != OK
        || transport.context.is_null()
    {
        return Err(HostError::Unsupported);
    }
    if unsafe { (transport.api.probe)(transport.context, 4000) } != OK {
        return Err(HostError::Unavailable);
    }
    let state = transport.status().map_err(|_| HostError::Unavailable)?;
    if state.write_ready == 0 || state.coverage_unknown != 0 {
        return Err(HostError::Unavailable);
    }
    Ok(Box::new(transport))
}

struct BridgeTransport {
    api: Api,
    context: Context,
    nonce: u64,
}
// SAFETY: the sole context/library ownership moves with this adapter. Its calls
// are serialized by RuntimeOwner; the C++ context also serializes its operations.
unsafe impl Send for BridgeTransport {}
impl BridgeTransport {
    fn status(&self) -> Result<State, TransportError> {
        let mut state = State {
            bytes: 80,
            version: 1,
            ..Default::default()
        };
        if self.context.is_null() || unsafe { (self.api.state)(self.context, &mut state) } != OK {
            return Err(TransportError::Unavailable);
        }
        if state.target_alive == 0 {
            return Err(TransportError::TargetExited);
        }
        Ok(state)
    }
    fn wire_id(&self, id: CorrelationId) -> String {
        format!("thread/read:ctz-{:016x}-{:016x}", self.nonce, id.0)
    }
    fn correlation(nonce: u64, id: &TypedId) -> Option<CorrelationId> {
        if id.kind != 2 {
            return None;
        }
        let text = std::str::from_utf8(id.text.get(..id.length as usize)?).ok()?;
        let prefix = format!("thread/read:ctz-{:016x}-", nonce);
        let number = text.strip_prefix(&prefix)?;
        if number.len() != 16 {
            return None;
        }
        u64::from_str_radix(number, 16).ok().map(CorrelationId)
    }
    fn register(&mut self, purpose: u32, id: &str) -> Result<u64, TransportError> {
        if id.len() >= 64 {
            return Err(TransportError::Unsupported);
        }
        let mut raw = TypedId {
            kind: 2,
            length: id.len() as u32,
            number: 0,
            text: [0; 64],
        };
        raw.text[..id.len()].copy_from_slice(id.as_bytes());
        let mut ticket = 0;
        if unsafe { (self.api.register)(self.context, purpose, &raw, &mut ticket) } != OK
            || ticket == 0
        {
            return Err(TransportError::Unavailable);
        }
        Ok(ticket)
    }
    fn frame<T: Serialize>(
        &mut self,
        value: &T,
        ticket: Option<u64>,
        deadline: Instant,
    ) -> Delivery {
        if Instant::now() >= deadline {
            self.discard(ticket);
            return Delivery::NotWritten;
        }
        let mut bytes = match serde_json::to_vec(value) {
            Ok(bytes) => bytes,
            Err(_) => {
                self.discard(ticket);
                return Delivery::NotWritten;
            }
        };
        bytes.push(b'\n');
        let mut result =
            unsafe { (self.api.write)(self.context, bytes.as_ptr(), bytes.len() as u32) };
        // The C++ bridge has copied any admitted frame before returning.
        bytes.fill(0);
        if [4, 10, 11, 12, 13, 14, 15, 16, 17, 20, BUSY].contains(&result) {
            self.discard(ticket);
            return Delivery::NotWritten;
        }
        while result == PENDING && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
            result = unsafe { (self.api.finish)(self.context) };
        }
        if result == OK {
            Delivery::Written
        } else {
            Delivery::Unknown
        }
    }
    fn discard(&mut self, ticket: Option<u64>) {
        if let Some(ticket) = ticket {
            unsafe {
                (self.api.discard)(self.context, ticket);
            }
        }
    }
    fn event(nonce: u64, event: Event) -> Result<Option<RuntimeEvent>, TransportError> {
        let kind = match event.kind {
            1 => return Ok(None),
            2 => {
                if event.flags & INVALID != 0 || event.flags & COMPLETE == 0 {
                    return Err(TransportError::Unsupported);
                }
                let id = match event.id.kind {
                    1 => RefreshRequestId::Number(event.id.number),
                    2 => RefreshRequestId::Text(field(&event.id.text, event.id.length)?),
                    _ => return Err(TransportError::Unsupported),
                };
                RuntimeEventKind::RefreshRequested {
                    id,
                    previous_account_id: optional(
                        &event.account_id,
                        event.account_id_bytes,
                        event.flags,
                        32 | 512,
                    )?,
                }
            }
            3 => {
                if event.flags & INVALID != 0 || event.flags & COMPLETE == 0 {
                    return Err(TransportError::Unsupported);
                }
                RuntimeEventKind::AccountUpdated {
                    auth: match event.auth_mode {
                        1 => AuthFamily::LoggedOut,
                        2 => AuthFamily::ApiKey,
                        3 => AuthFamily::ChatGpt,
                        4 => AuthFamily::ChatGptAuthTokens,
                        _ => return Err(TransportError::Unsupported),
                    },
                }
            }
            4 => {
                let Some(id) = Self::correlation(nonce, &event.id) else {
                    return Ok(None);
                };
                RuntimeEventKind::LoginAcknowledged {
                    id,
                    accepted: event.flags & (1 | COMPLETE) == (1 | COMPLETE)
                        && event.flags & (ERROR | INVALID) == 0
                        && event.reply_type == 1,
                }
            }
            5 => {
                let Some(id) = Self::correlation(nonce, &event.id) else {
                    return Ok(None);
                };
                if event.flags & (ERROR | INVALID) != 0 || event.flags & COMPLETE == 0 {
                    return Err(TransportError::Unsupported);
                }
                let identity = match event.account_type {
                    1 => ObservedIdentity {
                        auth: AuthFamily::LoggedOut,
                        email: None,
                        plan_type: None,
                        account_id: None,
                    },
                    2 => ObservedIdentity {
                        auth: AuthFamily::ChatGpt,
                        email: Some(field(&event.email, event.email_bytes)?),
                        plan_type: optional(&event.plan, event.plan_bytes, event.flags, 16 | 256)?,
                        account_id: optional(
                            &event.account_id,
                            event.account_id_bytes,
                            event.flags,
                            32 | 512,
                        )?,
                    },
                    3 => ObservedIdentity {
                        auth: AuthFamily::ApiKey,
                        email: None,
                        plan_type: None,
                        account_id: None,
                    },
                    _ => return Err(TransportError::Unsupported),
                };
                RuntimeEventKind::AccountRead { id, identity }
            }
            _ => return Err(TransportError::Unsupported),
        };
        Ok(Some(RuntimeEvent {
            sequence: event.sequence,
            kind,
        }))
    }
}
fn field(bytes: &[u8], count: u32) -> Result<String, TransportError> {
    let value = std::str::from_utf8(
        bytes
            .get(..count as usize)
            .ok_or(TransportError::Unsupported)?,
    )
    .map_err(|_| TransportError::Unsupported)?;
    if value.is_empty() || value.chars().any(char::is_control) {
        return Err(TransportError::Unsupported);
    }
    Ok(value.to_owned())
}
fn optional(
    bytes: &[u8],
    count: u32,
    flags: u32,
    absent: u32,
) -> Result<Option<String>, TransportError> {
    if flags & INVALID != 0 {
        return Err(TransportError::Unsupported);
    }
    if flags & absent != 0 {
        return Ok(None);
    }
    field(bytes, count).map(Some)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Credentials<'a> {
    access_token: &'a str,
    chatgpt_account_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    chatgpt_plan_type: Option<&'a str>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Login<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    #[serde(flatten)]
    credentials: Credentials<'a>,
}
#[derive(Serialize)]
struct Request<'a, T> {
    id: &'a str,
    method: &'static str,
    params: T,
}
#[derive(Serialize)]
#[serde(untagged)]
enum ResponseId<'a> {
    Number(i64),
    Text(&'a str),
}
#[derive(Serialize)]
struct Response<'a> {
    id: ResponseId<'a>,
    result: Credentials<'a>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ReadParams {
    refresh_token: bool,
}
#[derive(Serialize)]
struct LoadedParams<'a> {
    cursor: Option<&'a str>,
    limit: u32,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadParams<'a> {
    thread_id: &'a str,
    include_turns: bool,
}
impl RuntimeTransport for BridgeTransport {
    fn metadata_supported(&self) -> bool {
        self.api.poll_bootstrap.is_some()
    }
    fn write_metadata(
        &mut self,
        request: &crate::runtime_bootstrap::MetadataRequest,
        deadline: Instant,
    ) -> Delivery {
        use crate::runtime_bootstrap::MetadataRequest;
        let (id, purpose) = match request {
            MetadataRequest::LoadedList { id, .. } => (*id, 3),
            MetadataRequest::ThreadRead { id, .. } => (*id, 4),
        };
        let wire = self.wire_id(id);
        let Ok(ticket) = self.register(purpose, &wire) else {
            return Delivery::NotWritten;
        };
        match request {
            MetadataRequest::LoadedList { cursor, limit, .. } => self.frame(
                &Request {
                    id: &wire,
                    method: "thread/loaded/list",
                    params: LoadedParams {
                        cursor: cursor.as_deref(),
                        limit: *limit,
                    },
                },
                Some(ticket),
                deadline,
            ),
            MetadataRequest::ThreadRead {
                thread_id,
                include_turns,
                ..
            } => self.frame(
                &Request {
                    id: &wire,
                    method: "thread/read",
                    params: ThreadParams {
                        thread_id,
                        include_turns: *include_turns,
                    },
                },
                Some(ticket),
                deadline,
            ),
        }
    }
    fn poll_metadata(
        &mut self,
    ) -> Result<Option<crate::runtime_bootstrap::MetadataEvent>, TransportError> {
        use crate::runtime_bootstrap::{MetadataEvent, MetadataStamp};
        let Some(poll) = self.api.poll_bootstrap else {
            return Ok(None);
        };
        for _ in 0..16 {
            let mut raw: BootstrapEvent = unsafe { std::mem::zeroed() };
            let mut state = BootstrapState {
                bytes: 40,
                version: 1,
                ..Default::default()
            };
            match unsafe { poll(self.context, &mut raw, &mut state) } {
                EMPTY => return Ok(None),
                TARGET_EXITED => return Err(TransportError::TargetExited),
                OK => {}
                _ => return Err(TransportError::Unavailable),
            }
            let Some(id) = Self::correlation(self.nonce, &raw.id) else {
                continue;
            };
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64;
            let stamp = MetadataStamp {
                generation: raw.generation,
                sequence: raw.sequence,
                observed_at_ms: now
                    .saturating_sub(unsafe { GetTickCount64() }.saturating_sub(raw.observed_at_ms)),
            };
            if raw.kind == 4 || raw.flags & 1 == 0 {
                return Ok(Some(MetadataEvent::RequestError { id, stamp }));
            }
            let event = match raw.kind {
                1 => MetadataEvent::PageItem {
                    id,
                    stamp,
                    index: raw.index,
                    thread_id: field(&raw.value, raw.value_bytes)?,
                },
                2 => {
                    let next_cursor = if raw.flags & 8 != 0 {
                        None
                    } else if raw.flags & 4 != 0 {
                        Some(
                            std::str::from_utf8(
                                raw.value
                                    .get(..raw.value_bytes as usize)
                                    .ok_or(TransportError::Unsupported)?,
                            )
                            .map_err(|_| TransportError::Unsupported)?
                            .to_owned(),
                        )
                    } else {
                        return Ok(Some(MetadataEvent::RequestError { id, stamp }));
                    };
                    MetadataEvent::PageEnd {
                        id,
                        stamp,
                        count: raw.count,
                        next_cursor,
                    }
                }
                3 if (1..=4).contains(&raw.status) => MetadataEvent::ThreadSnapshot {
                    id,
                    stamp,
                    thread_id: field(&raw.value, raw.value_bytes)?,
                    status: raw.status,
                    attention: if raw.status == 4 {
                        raw.attention & 3
                    } else {
                        0
                    },
                },
                _ => MetadataEvent::RequestError { id, stamp },
            };
            return Ok(Some(event));
        }
        Ok(None)
    }
    fn write_login(
        &mut self,
        id: CorrelationId,
        token: &str,
        account_id: &str,
        plan: Option<&str>,
        deadline: Instant,
    ) -> WriteReceipt {
        let mut before = 0;
        if unsafe { (self.api.watermark)(self.context, &mut before) } != OK {
            return WriteReceipt {
                delivery: Delivery::NotWritten,
                observed_through: 0,
            };
        }
        let wire = self.wire_id(id);
        let Ok(ticket) = self.register(1, &wire) else {
            return WriteReceipt {
                delivery: Delivery::NotWritten,
                observed_through: before,
            };
        };
        let frame = Request {
            id: &wire,
            method: "account/login/start",
            params: Login {
                kind: "chatgptAuthTokens",
                credentials: Credentials {
                    access_token: token,
                    chatgpt_account_id: account_id,
                    chatgpt_plan_type: plan,
                },
            },
        };
        WriteReceipt {
            delivery: self.frame(&frame, Some(ticket), deadline),
            observed_through: before,
        }
    }
    fn write_refresh_response(
        &mut self,
        id: &RefreshRequestId,
        token: &str,
        account_id: &str,
        plan: Option<&str>,
        deadline: Instant,
    ) -> Delivery {
        let id = match id {
            RefreshRequestId::Number(number) => ResponseId::Number(*number),
            RefreshRequestId::Text(text) => ResponseId::Text(text),
        };
        self.frame(
            &Response {
                id,
                result: Credentials {
                    access_token: token,
                    chatgpt_account_id: account_id,
                    chatgpt_plan_type: plan,
                },
            },
            None,
            deadline,
        )
    }
    fn request_account_read(
        &mut self,
        id: CorrelationId,
        deadline: Instant,
    ) -> Result<(), TransportError> {
        let wire = self.wire_id(id);
        let ticket = self.register(2, &wire)?;
        match self.frame(
            &Request {
                id: &wire,
                method: "account/read",
                params: ReadParams {
                    refresh_token: false,
                },
            },
            Some(ticket),
            deadline,
        ) {
            Delivery::Written => Ok(()),
            _ => Err(TransportError::Unavailable),
        }
    }
    fn poll_event(&mut self) -> Result<Option<RuntimeEvent>, TransportError> {
        // A deadline can expire before an admitted overlapped write completes.
        // Reap that same write on later ticks; never replay its credential frame.
        match unsafe { (self.api.finish)(self.context) } {
            OK | PENDING => {}
            TARGET_EXITED => return Err(TransportError::TargetExited),
            _ => return Err(TransportError::Unavailable),
        }
        for _ in 0..16 {
            let mut event: Event = unsafe { std::mem::zeroed() };
            match unsafe { (self.api.poll)(self.context, &mut event) } {
                OK => {
                    if let Some(event) = Self::event(self.nonce, event)? {
                        return Ok(Some(event));
                    }
                }
                EMPTY => return Ok(None),
                TARGET_EXITED => return Err(TransportError::TargetExited),
                _ => return Err(TransportError::Unavailable),
            }
        }
        Ok(None)
    }
    fn target_alive(&self) -> bool {
        self.status().is_ok()
    }
    fn poll_live(
        &mut self,
    ) -> Result<(Option<crate::global_live::LiveEvent>, u32), TransportError> {
        let mut event: LiveEvent = unsafe { std::mem::zeroed() };
        let mut state = LiveState {
            bytes: 40,
            version: 1,
            ..Default::default()
        };
        let result = unsafe { (self.api.poll_live)(self.context, &mut event, &mut state) };
        if result == TARGET_EXITED {
            return Err(TransportError::TargetExited);
        }
        if result == EMPTY {
            return Ok((None, state.drops));
        }
        if result != OK || event.flags & 1 == 0 {
            return Err(TransportError::Unavailable);
        }
        let fixed = |bytes: &[u8]| {
            field(
                bytes,
                bytes
                    .iter()
                    .position(|b| *b == 0)
                    .ok_or(TransportError::Unsupported)? as u32,
            )
        };
        let request_key = match event.id.kind {
            0 => None,
            1 => Some(format!("n:{}", event.id.number)),
            2 => Some(format!("s:{}", field(&event.id.text, event.id.length)?)),
            _ => return Err(TransportError::Unsupported),
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let age = unsafe { GetTickCount64() }.saturating_sub(event.observed_at_ms);
        Ok((
            Some(crate::global_live::LiveEvent {
                generation: event.generation,
                sequence: event.sequence,
                observed_at_ms: now.saturating_sub(age),
                kind: event.kind,
                lifecycle: event.lifecycle,
                attention: event.attention,
                flags: event.flags,
                request_key,
                thread_id: fixed(&event.thread_id)?,
                turn_id: if event.flags & 12 != 0 {
                    None
                } else {
                    Some(fixed(&event.turn_id)?)
                },
            }),
            state.drops,
        ))
    }
}
impl Drop for BridgeTransport {
    fn drop(&mut self) {
        if self.context.is_null() {
            return;
        }
        let deadline = Instant::now() + Duration::from_millis(250);
        loop {
            let pending = unsafe { (self.api.finish)(self.context) } == PENDING;
            let stopped = if pending {
                BUSY
            } else {
                unsafe { (self.api.stop)(self.context) }
            };
            if stopped == OK || !self.target_alive() {
                if unsafe { (self.api.close)(self.context) } == OK {
                    return;
                }
            }
            if Instant::now() >= deadline {
                break;
            }
            thread::sleep(Duration::from_millis(2));
        }
        // Keep code/context available for any live remote call or pending IRP.
        // No caller can turn a failed cleanup into token rollback or kill Codex.
        self.api.library.0 = ptr::null_mut();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    static LATE_WRITE: AtomicU32 = AtomicU32::new(0);
    unsafe extern "system" fn test_discover(_: *mut DesktopIdentity) -> u32 {
        10
    }
    unsafe extern "system" fn test_attach(_: *const u16, _: *mut Context) -> u32 {
        10
    }
    unsafe extern "system" fn test_state(_: Context, out: *mut State) -> u32 {
        unsafe { (*out).target_alive = 1 };
        OK
    }
    unsafe extern "system" fn test_poll(_: Context, _: *mut Event) -> u32 {
        EMPTY
    }
    unsafe extern "system" fn test_watermark(_: Context, _: *mut u64) -> u32 {
        OK
    }
    unsafe extern "system" fn test_register(
        _: Context,
        _: u32,
        _: *const TypedId,
        out: *mut u64,
    ) -> u32 {
        unsafe { *out = 1 };
        OK
    }
    unsafe extern "system" fn test_discard(_: Context, _: u64) -> u32 {
        OK
    }
    unsafe extern "system" fn test_write(_: Context, _: *const u8, _: u32) -> u32 {
        match LATE_WRITE.load(Ordering::SeqCst) {
            0 => {
                LATE_WRITE.store(1, Ordering::SeqCst);
                PENDING
            }
            3 => OK,
            _ => BUSY,
        }
    }
    unsafe extern "system" fn test_finish(_: Context) -> u32 {
        match LATE_WRITE.load(Ordering::SeqCst) {
            1 => PENDING,
            2 => {
                LATE_WRITE.store(3, Ordering::SeqCst);
                OK
            }
            _ => OK,
        }
    }
    unsafe extern "system" fn test_operation(_: Context) -> u32 {
        OK
    }
    unsafe extern "system" fn test_probe(_: Context, _: u32) -> u32 {
        OK
    }
    unsafe extern "system" fn test_live(_: Context, _: *mut LiveEvent, _: *mut LiveState) -> u32 {
        EMPTY
    }
    #[test]
    fn native_adapter_idle_tick_reaps_late_write_without_rewriting_original_frame() {
        LATE_WRITE.store(0, Ordering::SeqCst);
        let api = Api {
            library: Library(ptr::null_mut()),
            discover: test_discover,
            attach: test_attach,
            state: test_state,
            poll: test_poll,
            watermark: test_watermark,
            register: test_register,
            discard: test_discard,
            write: test_write,
            finish: test_finish,
            probe: test_probe,
            stop: test_operation,
            close: test_operation,
            poll_live: test_live,
            poll_bootstrap: None,
        };
        let mut transport = BridgeTransport {
            api,
            context: std::ptr::dangling_mut::<u8>().cast(),
            nonce: 1,
        };
        let value = ReadParams {
            refresh_token: false,
        };
        assert_eq!(
            transport.frame(&value, None, Instant::now() + Duration::from_millis(1)),
            Delivery::Unknown
        );
        // The OS has now completed the old write. It is still owned by C++ until
        // FinishWrite observes completion; no credential replay is permitted.
        LATE_WRITE.store(2, Ordering::SeqCst);
        assert!(transport.poll_event().unwrap().is_none());
        assert_eq!(
            transport.frame(&value, None, Instant::now() + Duration::from_secs(1)),
            Delivery::Written
        );
    }
    #[test]
    fn native_adapter_rejects_incomplete_account_updates() {
        for flags in [0, COMPLETE | 1024, COMPLETE | 64] {
            let mut event: Event = unsafe { std::mem::zeroed() };
            event.kind = 3;
            event.auth_mode = 4;
            event.flags = flags;
            assert!(
                matches!(
                    BridgeTransport::event(1, event),
                    Err(TransportError::Unsupported)
                ),
                "an incomplete update cannot confirm an external login"
            );
        }
    }
    #[test]
    fn native_adapter_rejects_incomplete_refresh_requests() {
        let mut event: Event = unsafe { std::mem::zeroed() };
        event.kind = 2;
        event.id.kind = 1;
        event.id.number = 17;
        event.flags = 32;
        assert!(
            matches!(
                BridgeTransport::event(1, event),
                Err(TransportError::Unsupported)
            ),
            "an incomplete callback cannot request credentials"
        );
    }
}
