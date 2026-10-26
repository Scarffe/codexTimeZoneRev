//! Independent new-task production owner. Public preview is entirely in memory.
use crate::{
    account_sources::{self, TaskSourceLease},
    owned_stdio::OwnedStdio,
    task_protocol::{self, Protocol},
};
use serde::Deserialize;
use serde_json::{json, Value};
#[cfg(test)]
use std::path::PathBuf;
use std::{
    collections::{HashMap, HashSet},
    fs::File,
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, Sender},
        Arc, LazyLock, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
const HISTORY_LIMIT: usize = 32;
const OUTPUT_LIMIT: usize = 131_072;
const REQUEST_LIMIT: usize = 32;
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Draft {
    mode: String,
    source_id: String,
    workspace: String,
    prompt: String,
    model: String,
    sandbox: String,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Identity {
    task_id: String,
    source_epoch: u64,
    generation: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ApprovalAction {
    task_id: String,
    source_epoch: u64,
    generation: u64,
    approval_id: String,
    decision: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InputAction {
    task_id: String,
    source_epoch: u64,
    generation: u64,
    request_id: String,
    answers: Value,
}
enum Action {
    Approval(String, String),
    Input(String, Value),
}
struct Retained {
    child: OwnedStdio,
    _lease: Option<TaskSourceLease>,
}
struct Task {
    id: Identity,
    draft: Draft,
    state: &'static str,
    thread: Option<String>,
    turn: Option<String>,
    output: String,
    truncated: bool,
    approvals: Vec<Value>,
    inputs: Vec<Value>,
    usage: Value,
    error: Option<String>,
    observed: Value,
    cleaning: bool,
    cancel: Arc<AtomicBool>,
    actions: Option<Sender<Action>>,
    worker: Option<JoinHandle<()>>,
    retained: Option<Retained>,
    workspace_handle: Option<File>,
    runtime_workspace: Option<String>,
}
impl Task {
    fn snapshot(&self) -> Value {
        json!({"taskId":self.id.task_id,"mode":self.draft.mode,"sourceId":self.draft.source_id,"sourceEpoch":self.id.source_epoch,"generation":self.id.generation,"workspace":self.draft.workspace,"model":self.draft.model,"sandbox":self.draft.sandbox,"state":self.state,"threadId":self.thread,"turnId":self.turn,"output":self.output,"outputTruncated":self.truncated,"approvals":self.approvals,"inputRequests":self.inputs,"usage":self.usage,"cleanupPending":self.cleaning,"errorKind":self.error,"observedIdentity":self.observed,"strongPrincipalVerified":false})
    }
    fn terminal(&self) -> bool {
        matches!(
            self.state,
            "completed" | "cancelled" | "failed" | "interrupted"
        )
    }
    fn active(&self) -> bool {
        self.cleaning || (!self.terminal() && self.state != "prepared")
    }
}
struct State {
    accepting: bool,
    tasks: HashMap<String, Task>,
}
pub(crate) struct Manager {
    state: Mutex<State>,
    next: AtomicU64,
    nonce: u64,
    #[cfg(test)]
    source_factory: Option<Arc<dyn Fn(&str) -> Result<TaskSourceLease, String> + Send + Sync>>,
}
impl Manager {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State {
                accepting: true,
                tasks: HashMap::new(),
            }),
            next: AtomicU64::new(1),
            nonce: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_micros()
                .min(u64::MAX as u128) as u64,
            #[cfg(test)]
            source_factory: None,
        })
    }
    fn task<'a>(state: &'a mut State, id: &Identity) -> Result<&'a mut Task, String> {
        state
            .tasks
            .get_mut(&id.task_id)
            .filter(|task| {
                task.id.source_epoch == id.source_epoch && task.id.generation == id.generation
            })
            .ok_or_else(|| "invalid_request".into())
    }
    fn update(&self, id: &Identity, operation: impl FnOnce(&mut Task)) {
        let mut state = self.state.lock().unwrap();
        if let Ok(task) = Self::task(&mut state, id) {
            operation(task)
        }
    }
    fn empty(payload: &Value) -> Result<(), String> {
        if payload.as_object().is_some_and(|value| value.is_empty()) {
            Ok(())
        } else {
            Err("invalid_request".into())
        }
    }
    pub(crate) fn execute(
        self: &Arc<Self>,
        command: &str,
        payload: Value,
    ) -> Result<Value, String> {
        match command {
            "task_catalog" => {
                Self::empty(&payload)?;
                Ok(
                    json!({"adapterAvailable":true,"officialExecutionValidated":false,"strongPrincipalVerified":false,"maxRunning":2,"previewSources":["preview-a","preview-b"],"modes":["offline_preview","official"],"sandboxes":["read-only","workspace-write"]}),
                )
            }
            "task_prepare" => {
                self.prepare(serde_json::from_value(payload).map_err(|_| "invalid_request")?)
            }
            "task_start" => {
                self.start(serde_json::from_value(payload).map_err(|_| "invalid_request")?)
            }
            "task_status" => {
                let id = serde_json::from_value(payload).map_err(|_| "invalid_request")?;
                let mut state = self.state.lock().unwrap();
                let task = Self::task(&mut state, &id)?;
                Self::reap(task);
                Ok(task.snapshot())
            }
            "task_list" => {
                Self::empty(&payload)?;
                let mut state = self.state.lock().unwrap();
                for task in state.tasks.values_mut() {
                    Self::reap(task)
                }
                let mut tasks = state.tasks.values().collect::<Vec<_>>();
                tasks.sort_by_key(|task| task.id.generation);
                Ok(json!({"tasks":tasks.into_iter().map(Task::snapshot).collect::<Vec<_>>()}))
            }
            "task_cancel" => {
                self.cancel(serde_json::from_value(payload).map_err(|_| "invalid_request")?)
            }
            "task_clear" => {
                let id: Identity =
                    serde_json::from_value(payload).map_err(|_| "invalid_request")?;
                let mut state = self.state.lock().unwrap();
                let task = Self::task(&mut state, &id)?;
                Self::reap(task);
                if task.active() {
                    return Err("invalid_request".into());
                }
                state.tasks.remove(&id.task_id);
                Ok(json!({"taskId":id.task_id,"cleared":true}))
            }
            "task_approval" => {
                let action: ApprovalAction =
                    serde_json::from_value(payload).map_err(|_| "invalid_request")?;
                if !matches!(action.decision.as_str(), "accept" | "decline" | "cancel") {
                    return Err("invalid_request".into());
                }
                let id = Identity {
                    task_id: action.task_id,
                    source_epoch: action.source_epoch,
                    generation: action.generation,
                };
                let mut state = self.state.lock().unwrap();
                let task = Self::task(&mut state, &id)?;
                if !matches!(task.state, "awaiting_approval" | "awaiting_input")
                    || task.cancel.load(Ordering::SeqCst)
                {
                    return Err("invalid_request".into());
                }
                let index = task
                    .approvals
                    .iter()
                    .position(|request| request["approvalId"] == action.approval_id)
                    .ok_or("invalid_request")?;
                if !task.approvals[index]["decisions"]
                    .as_array()
                    .is_some_and(|decisions| {
                        decisions
                            .iter()
                            .any(|decision| decision == &action.decision)
                    })
                {
                    return Err("invalid_request".into());
                }
                task.actions
                    .as_ref()
                    .ok_or("disconnected")?
                    .send(Action::Approval(action.approval_id, action.decision))
                    .map_err(|_| "disconnected")?;
                task.approvals.remove(index);
                Self::waiting_state(task);
                Ok(task.snapshot())
            }
            "task_input" => {
                let action: InputAction =
                    serde_json::from_value(payload).map_err(|_| "invalid_request")?;
                let id = Identity {
                    task_id: action.task_id,
                    source_epoch: action.source_epoch,
                    generation: action.generation,
                };
                let mut state = self.state.lock().unwrap();
                let task = Self::task(&mut state, &id)?;
                if task.cancel.load(Ordering::SeqCst)
                    || !matches!(task.state, "awaiting_input" | "awaiting_approval")
                {
                    return Err("invalid_request".into());
                }
                let index = task
                    .inputs
                    .iter()
                    .position(|request| request["requestId"] == action.request_id)
                    .ok_or("invalid_request")?;
                validate_answers(&task.inputs[index]["questions"], &action.answers)?;
                task.actions
                    .as_ref()
                    .ok_or("disconnected")?
                    .send(Action::Input(action.request_id, action.answers))
                    .map_err(|_| "disconnected")?;
                task.inputs.remove(index);
                Self::waiting_state(task);
                Ok(task.snapshot())
            }
            "task_shutdown" => {
                Self::empty(&payload)?;
                self.shutdown()
            }
            _ => Err("invalid_request".into()),
        }
    }
    fn waiting_state(task: &mut Task) {
        task.state = if !task.approvals.is_empty() {
            "awaiting_approval"
        } else if !task.inputs.is_empty() {
            "awaiting_input"
        } else {
            "running"
        };
    }
    fn reap(task: &mut Task) {
        if task
            .retained
            .as_mut()
            .is_some_and(|runtime| runtime.child.cleanup(Duration::from_millis(25)))
        {
            task.retained.take();
            task.workspace_handle.take();
            task.cleaning = false;
        }
        if task.worker.as_ref().is_some_and(JoinHandle::is_finished) {
            let _ = task.worker.take().unwrap().join();
        }
    }
    fn prepare(&self, draft: Draft) -> Result<Value, String> {
        if !matches!(draft.mode.as_str(), "offline_preview" | "official")
            || !matches!(draft.sandbox.as_str(), "read-only" | "workspace-write")
            || !bounded(&draft.prompt, 1, 32768)
            || !bounded(&draft.workspace, 1, 32768)
            || !bounded(&draft.model, 1, 160)
            || draft.model.chars().any(char::is_control)
        {
            return Err("invalid_request".into());
        }
        if draft.mode == "offline_preview" {
            if !matches!(draft.source_id.as_str(), "preview-a" | "preview-b") {
                return Err("source_invalid".into());
            }
        } else {
            account_sources::validate_task_source(&draft.source_id)?;
            if !Path::new(&draft.workspace).is_absolute() {
                return Err("invalid_request".into());
            }
        }
        let mut state = self.state.lock().unwrap();
        if !state.accepting {
            return Err("shutdown".into());
        }
        if state.tasks.len() >= HISTORY_LIMIT {
            return Err("invalid_request".into());
        }
        let sequence = self.next.fetch_add(1, Ordering::SeqCst);
        let id = Identity {
            task_id: format!("task-{}-{}", self.nonce, sequence),
            source_epoch: sequence,
            generation: sequence,
        };
        let task = Task {
            id: id.clone(),
            draft,
            state: "prepared",
            thread: None,
            turn: None,
            output: String::new(),
            truncated: false,
            approvals: Vec::new(),
            inputs: Vec::new(),
            usage: Value::Null,
            error: None,
            observed: Value::Null,
            cleaning: false,
            cancel: Arc::new(AtomicBool::new(false)),
            actions: None,
            worker: None,
            retained: None,
            workspace_handle: None,
            runtime_workspace: None,
        };
        let snapshot = task.snapshot();
        state.tasks.insert(id.task_id, task);
        Ok(snapshot)
    }
    fn start(self: &Arc<Self>, id: Identity) -> Result<Value, String> {
        let mut state = self.state.lock().unwrap();
        if !state.accepting {
            return Err("shutdown".into());
        }
        let task = Self::task(&mut state, &id)?;
        if task.state != "prepared" {
            return Err("invalid_request".into());
        }
        let mut draft = task.draft.clone();
        let mut handle = None;
        if draft.mode == "official" {
            let workspace =
                std::fs::canonicalize(&draft.workspace).map_err(|_| "invalid_request")?;
            if !workspace.is_dir() {
                return Err("invalid_request".into());
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::OpenOptionsExt;
                handle = Some(
                    std::fs::OpenOptions::new()
                        .read(true)
                        .share_mode(3)
                        .custom_flags(0x02000000)
                        .open(&workspace)
                        .map_err(|_| "invalid_request")?,
                );
            }
            #[cfg(not(windows))]
            {
                handle = Some(File::open(&workspace).map_err(|_| "invalid_request")?);
            }
            draft.workspace = workspace.to_string_lossy().into_owned();
        }
        if state.tasks.values().filter(|task| task.active()).count() >= 2 {
            return Err("source_busy".into());
        }
        for other in state.tasks.values().filter(|task| task.active()) {
            if other.draft.source_id == draft.source_id {
                return Err("source_busy".into());
            }
            if (draft.sandbox == "workspace-write" || other.draft.sandbox == "workspace-write")
                && overlaps(
                    &draft.workspace,
                    other
                        .runtime_workspace
                        .as_deref()
                        .unwrap_or(&other.draft.workspace),
                )
            {
                return Err("workspace_busy".into());
            }
        }
        let task = Self::task(&mut state, &id)?;
        task.runtime_workspace = Some(draft.workspace.clone());
        task.workspace_handle = handle;
        task.state = "starting";
        task.cleaning = true;
        let (tx, rx) = mpsc::channel();
        task.actions = Some(tx);
        let cancel = task.cancel.clone();
        let manager = self.clone();
        let worker_id = id.clone();
        match thread::Builder::new()
            .name("independent-task".into())
            .spawn(move || {
                if draft.mode == "offline_preview" {
                    manager.preview(worker_id, draft, cancel)
                } else {
                    manager.official(worker_id, draft, cancel, rx)
                }
            }) {
            Ok(worker) => task.worker = Some(worker),
            Err(_) => {
                task.state = "failed";
                task.error = Some("startup_failed".into());
                task.cleaning = false;
                task.actions.take();
                task.workspace_handle.take();
                task.draft.prompt.clear();
            }
        }
        Ok(task.snapshot())
    }
    fn cancel(&self, id: Identity) -> Result<Value, String> {
        let mut state = self.state.lock().unwrap();
        let task = Self::task(&mut state, &id)?;
        if task.terminal() {
            Self::reap(task);
            return Ok(task.snapshot());
        }
        task.cancel.store(true, Ordering::SeqCst);
        task.approvals.clear();
        task.inputs.clear();
        if task.state == "prepared" {
            task.state = "cancelled";
            task.error = Some("cancelled".into());
            task.draft.prompt.clear();
        } else {
            task.state = "cancelling"
        }
        Ok(task.snapshot())
    }
    fn shutdown(&self) -> Result<Value, String> {
        {
            let mut state = self.state.lock().unwrap();
            state.accepting = false;
            for task in state.tasks.values_mut() {
                task.cancel.store(true, Ordering::SeqCst);
                if task.state == "prepared" {
                    task.state = "cancelled";
                    task.draft.prompt.clear();
                } else if !task.terminal() {
                    task.state = "cancelling";
                }
            }
        }
        let end = Instant::now() + Duration::from_secs(6);
        loop {
            let complete = {
                let mut state = self.state.lock().unwrap();
                for task in state.tasks.values_mut() {
                    Self::reap(task)
                }
                state.tasks.values().all(|task| !task.cleaning)
            };
            if complete || Instant::now() >= end {
                return Ok(json!({"accepting":false,"cleanupComplete":complete}));
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
    fn finish(
        &self,
        id: &Identity,
        state: &'static str,
        error: Option<&str>,
        retained: Option<Retained>,
    ) {
        self.update(id, |task| {
            task.state = state;
            task.error = error.map(str::to_owned);
            task.actions.take();
            task.approvals.clear();
            task.inputs.clear();
            task.draft.prompt.clear();
            task.cleaning = retained.is_some();
            task.retained = retained;
            if !task.cleaning {
                task.workspace_handle.take();
            }
        })
    }
    fn preview(&self, id: Identity, draft: Draft, cancel: Arc<AtomicBool>) {
        self.update(&id, |task| task.state = "running");
        for _ in 0..20 {
            if cancel.load(Ordering::SeqCst) {
                self.finish(&id, "cancelled", Some("cancelled"), None);
                return;
            }
            thread::sleep(Duration::from_millis(5));
        }
        self.update(&id, |task| {
            task.thread = Some(format!("synthetic-{}", id.task_id));
            task.turn = Some("synthetic-turn".into());
            set_output(
                task,
                format!(
                    "Synthetic preview only ({})\n{}",
                    draft.source_id, draft.prompt
                ),
            );
        });
        self.finish(&id, "completed", None, None);
    }
    fn official(
        &self,
        id: Identity,
        draft: Draft,
        cancel: Arc<AtomicBool>,
        actions: Receiver<Action>,
    ) {
        #[cfg(test)]
        let acquired = if let Some(factory) = &self.source_factory {
            factory(&draft.source_id)
        } else {
            account_sources::acquire_task_source(&draft.source_id)
        };
        #[cfg(not(test))]
        let acquired = account_sources::acquire_task_source(&draft.source_id);
        let mut lease = match acquired {
            Ok(lease) => Some(lease),
            Err(error) => {
                self.finish(&id, "failed", Some(&error), None);
                return;
            }
        };
        let launched = lease.as_ref().unwrap().launch(Path::new(&draft.workspace));
        let child = match launched {
            Ok(child) => child,
            Err(error) => {
                let retained = error.retained.map(|child| Retained {
                    child,
                    _lease: lease.take(),
                });
                if retained.is_none() {
                    drop(lease.take());
                }
                self.finish(&id, "failed", Some(error.kind), retained);
                return;
            }
        };
        let home = lease.as_ref().unwrap().home().to_owned();
        let source_cancel = lease.as_ref().map(TaskSourceLease::cancel_signal);
        let mut protocol = Protocol::new(child, cancel, source_cancel);
        let outcome = self.run_protocol(&id, &draft, &home, &mut protocol, actions);
        let cleaned = protocol.child.cleanup(Duration::from_secs(3));
        let retained = if cleaned {
            drop(lease.take());
            None
        } else {
            Some(Retained {
                child: protocol.child,
                _lease: lease.take(),
            })
        };
        match outcome {
            Ok(state) => self.finish(
                &id,
                state,
                if cleaned {
                    None
                } else {
                    Some("cleanup_failed")
                },
                retained,
            ),
            Err(error) => self.finish(
                &id,
                if error == "cancelled" {
                    "cancelled"
                } else if error == "disconnected" {
                    "interrupted"
                } else {
                    "failed"
                },
                Some(if cleaned { error } else { "cleanup_failed" }),
                retained,
            ),
        }
    }
    fn run_protocol(
        &self,
        id: &Identity,
        draft: &Draft,
        home: &Path,
        protocol: &mut Protocol,
        actions: Receiver<Action>,
    ) -> Result<&'static str, &'static str> {
        let workspace = Path::new(&draft.workspace);
        let observed = protocol.handshake(home, workspace)?;
        self.update(id, |task| task.observed = observed.clone());
        if protocol.cancelled() {
            return Err("cancelled");
        }
        let started=protocol.call("thread/start",json!({"cwd":workspace,"model":draft.model,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":draft.sandbox,"ephemeral":true}))?;
        let thread = task_protocol::identifier(&started["thread"]["id"])?.to_owned();
        if std::fs::canonicalize(started["cwd"].as_str().ok_or("policy_mismatch")?)
            .map_err(|_| "policy_mismatch")?
            != workspace
            || started["approvalPolicy"] != "on-request"
            || started["approvalsReviewer"] != "user"
            || started["model"] != draft.model
            || started["modelProvider"] != "openai"
        {
            return Err("policy_mismatch");
        }
        let sandbox = if draft.sandbox == "read-only" {
            "readOnly"
        } else {
            "workspaceWrite"
        };
        if started["sandbox"]["type"] != sandbox
            || started["sandbox"]
                .get("networkAccess")
                .is_some_and(|value| value != false)
        {
            return Err("policy_mismatch");
        }
        if let Some(roots) = started["sandbox"].get("writableRoots") {
            if !roots.is_array()
                || roots.as_array().unwrap().iter().any(|root| {
                    root.as_str()
                        .and_then(|root| std::fs::canonicalize(root).ok())
                        .is_none_or(|root| root != workspace)
                })
            {
                return Err("policy_mismatch");
            }
        }
        self.update(id, |task| task.thread = Some(thread.clone()));
        if protocol.account()? != observed {
            return Err("identity_changed");
        }
        let started=protocol.call("turn/start",json!({"threadId":thread,"input":[{"type":"text","text":draft.prompt}],"cwd":workspace,"model":draft.model,"approvalPolicy":"on-request","approvalsReviewer":"user"}))?;
        let turn = task_protocol::identifier(&started["turn"]["id"])?.to_owned();
        self.update(id, |task| {
            task.turn = Some(turn.clone());
            task.state = "running";
        });
        let mut pending = HashMap::<String, Pending>::new();
        let mut seen = HashSet::new();
        let mut sequence = 0u64;
        let mut cancel_at = None;
        let deadline = Instant::now() + Duration::from_secs(600);
        let mut item_order = Vec::new();
        let mut texts = HashMap::<String, String>::new();
        let mut contexts = HashMap::<String, ItemContext>::new();
        loop {
            if protocol.cancelled() && cancel_at.is_none() {
                protocol.interrupt(&thread, &turn)?;
                cancel_at = Some(Instant::now());
                pending.clear();
                self.update(id, |task| {
                    task.state = "cancelling";
                    task.approvals.clear();
                    task.inputs.clear();
                });
            }
            if cancel_at.is_some_and(|at: Instant| at.elapsed() > Duration::from_secs(2)) {
                return Err("cancelled");
            }
            if Instant::now() >= deadline {
                return Err("timeout");
            }
            while let Ok(action) = actions.try_recv() {
                if cancel_at.is_some() {
                    continue;
                }
                match action {
                    Action::Approval(handle, decision) => {
                        let request = pending.get(&handle).ok_or("protocol_error")?;
                        if request.kind == "input"
                            || !request.decisions.iter().any(|allowed| allowed == &decision)
                        {
                            return Err("protocol_error");
                        }
                        let request = pending.remove(&handle).ok_or("protocol_error")?;
                        protocol
                            .send(json!({"id":request.rpc_id,"result":{"decision":decision}}))?;
                    }
                    Action::Input(handle, answers) => {
                        let request = pending.remove(&handle).ok_or("protocol_error")?;
                        if request.kind != "input" {
                            return Err("protocol_error");
                        }
                        protocol.send(json!({"id":request.rpc_id,"result":{"answers":answers}}))?;
                    }
                }
            }
            let frame = match protocol.next() {
                Err("timeout") => continue,
                result => result?,
            };
            let method = frame["method"].as_str().ok_or("protocol_error")?;
            let params = &frame["params"];
            if method == "remoteControl/status/changed" || method == "account/rateLimits/updated" {
                continue;
            }
            if method == "account/updated" {
                return Err("identity_changed");
            }
            if let Some(reported) = params.get("threadId") {
                if reported != &thread {
                    return Err("protocol_error");
                }
            }
            if let Some(reported) = params.get("turnId") {
                if reported != &turn {
                    return Err("protocol_error");
                }
            }
            if frame.get("id").is_some() {
                if cancel_at.is_some() {
                    return Err("cancelled");
                }
                if params["threadId"] != thread
                    || params["turnId"] != turn
                    || !params["itemId"].is_string()
                {
                    return Err("protocol_error");
                }
                if seen.len() >= 2048
                    || !seen.insert(frame["id"].to_string())
                    || pending.len() >= REQUEST_LIMIT
                {
                    return Err("protocol_error");
                }
                sequence += 1;
                let handle = format!("request-{}-{}", id.generation, sequence);
                let rpc_id = frame["id"].clone();
                match method {
                    "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                        let kind = if method.contains("commandExecution") {
                            "command"
                        } else {
                            "file"
                        };
                        let decisions = match supported_decisions(params, kind) {
                            Ok(decisions) => decisions,
                            Err(error) => {
                                let _=protocol.send(json!({"id":rpc_id,"error":{"code":-32601,"message":"unsupported approval choices"}}));
                                return Err(error);
                            }
                        };
                        let item_id = task_protocol::identifier(&params["itemId"])?;
                        let context = contexts.get(item_id);
                        if kind == "file"
                            && (params.get("grantRoot").is_some_and(|root| !root.is_null())
                                || context.is_none_or(|context| context.files.is_empty()))
                        {
                            let _=protocol.send(json!({"id":rpc_id,"error":{"code":-32601,"message":"unsupported file approval context"}}));
                            return Err("unsupported_request");
                        }
                        let command = optional_text(&params["command"], 8192)
                            .or_else(|| context.and_then(|context| context.command.clone()));
                        if kind == "command" && command.is_none() {
                            return Err("unsupported_request");
                        }
                        let cwd = optional_text(&params["cwd"], 32768)
                            .or_else(|| context.and_then(|context| context.cwd.clone()))
                            .or_else(|| Some(draft.workspace.clone()));
                        let mut summary =
                            optional_text(&params["reason"], 4096).unwrap_or_else(|| {
                                if kind == "command" {
                                    "Command execution".into()
                                } else {
                                    "File changes".into()
                                }
                            });
                        let files = context
                            .map(|context| context.files.clone())
                            .unwrap_or_default();
                        if kind == "file" {
                            if let Some(context) = context {
                                append_bounded(&mut summary, "\n", 4096);
                                append_bounded(&mut summary, &context.diff, 4096);
                                if summary.len() == 4096 {
                                    summary.push_str("\n[diff truncated]");
                                }
                            }
                        }
                        let request = json!({"approvalId":handle,"kind":kind,"summary":summary,"command":command,"cwd":cwd,"files":files,"decisions":decisions});
                        pending.insert(
                            handle,
                            Pending {
                                rpc_id,
                                kind,
                                decisions,
                            },
                        );
                        self.update(id, |task| {
                            task.approvals.push(request);
                            Self::waiting_state(task);
                        });
                    }
                    "item/tool/requestUserInput" => {
                        let questions = questions(&params["questions"])?;
                        let request = json!({"requestId":handle,"questions":questions});
                        pending.insert(
                            handle,
                            Pending {
                                rpc_id,
                                kind: "input",
                                decisions: Vec::new(),
                            },
                        );
                        self.update(id, |task| {
                            task.inputs.push(request);
                            Self::waiting_state(task);
                        });
                    }
                    _ => {
                        let _=protocol.send(json!({"id":rpc_id,"error":{"code":-32601,"message":"unsupported task request"}}));
                        return Err("unsupported_request");
                    }
                }
                continue;
            }
            if !task_protocol::known_notice(method) {
                return Err("protocol_error");
            }
            match method {
                "item/started" => {
                    require_route(params, &thread, &turn)?;
                    let item = &params["item"];
                    if matches!(
                        item["type"].as_str(),
                        Some("fileChange" | "commandExecution")
                    ) {
                        let item_id = task_protocol::identifier(&item["id"])?.to_owned();
                        if contexts.len() >= 256 && !contexts.contains_key(&item_id) {
                            return Err("protocol_error");
                        }
                        contexts.insert(item_id, item_context(item)?);
                    }
                }
                "thread/started" => {
                    if params["thread"]["id"] != thread {
                        return Err("protocol_error");
                    }
                }
                "turn/started" => {
                    if params["threadId"] != thread || params["turn"]["id"] != turn {
                        return Err("protocol_error");
                    }
                }
                "item/agentMessage/delta" => {
                    require_route(params, &thread, &turn)?;
                    let item = task_protocol::identifier(&params["itemId"])?.to_owned();
                    let delta = params["delta"].as_str().ok_or("protocol_error")?;
                    if !texts.contains_key(&item) {
                        if item_order.len() >= 256 {
                            return Err("protocol_error");
                        }
                        item_order.push(item.clone());
                        texts.insert(item.clone(), String::new());
                    }
                    let text = texts.get_mut(&item).unwrap();
                    if text.len().saturating_add(delta.len()) > OUTPUT_LIMIT {
                        self.update(id, |task| task.truncated = true);
                    }
                    if text.len() < OUTPUT_LIMIT {
                        append_bounded(text, delta, OUTPUT_LIMIT);
                    }
                    self.publish_output(id, &item_order, &texts);
                }
                "item/completed" => {
                    require_route(params, &thread, &turn)?;
                    if params["item"]["type"] == "agentMessage" {
                        let item = task_protocol::identifier(&params["item"]["id"])?.to_owned();
                        let text = params["item"]["text"].as_str().ok_or("protocol_error")?;
                        if !texts.contains_key(&item) {
                            if item_order.len() >= 256 {
                                return Err("protocol_error");
                            }
                            item_order.push(item.clone());
                        }
                        if text.len() > OUTPUT_LIMIT {
                            self.update(id, |task| task.truncated = true);
                        }
                        let mut bounded = String::new();
                        append_bounded(&mut bounded, text, OUTPUT_LIMIT);
                        texts.insert(item, bounded);
                        self.publish_output(id, &item_order, &texts);
                    }
                }
                "thread/tokenUsage/updated" => {
                    require_route(params, &thread, &turn)?;
                    let total = &params["tokenUsage"]["total"];
                    let count = |name: &str| {
                        total[name]
                            .as_u64()
                            .filter(|value| *value <= i64::MAX as u64)
                    };
                    self.update(id,|task|task.usage=json!({"scope":"thread_total","inputTokens":count("inputTokens"),"outputTokens":count("outputTokens"),"reasoningTokens":count("reasoningOutputTokens")}));
                }
                "serverRequest/resolved" => {
                    if params["threadId"] != thread
                        || !task_protocol::valid_id(&params["requestId"])
                    {
                        return Err("protocol_error");
                    }
                    let handle = pending
                        .iter()
                        .find(|(_, request)| request.rpc_id == params["requestId"])
                        .map(|(handle, _)| handle.clone());
                    if let Some(handle) = handle {
                        pending.remove(&handle);
                        self.update(id, |task| {
                            task.approvals
                                .retain(|request| request["approvalId"] != handle);
                            task.inputs.retain(|request| request["requestId"] != handle);
                            Self::waiting_state(task);
                        });
                    }
                }
                "turn/completed" => {
                    if params["threadId"] != thread || params["turn"]["id"] != turn {
                        return Err("protocol_error");
                    }
                    return match params["turn"]["status"].as_str() {
                        Some("completed") => Ok("completed"),
                        Some("interrupted") => Ok(if cancel_at.is_some() {
                            "cancelled"
                        } else {
                            "interrupted"
                        }),
                        Some("failed") => Err("protocol_error"),
                        _ => Err("protocol_error"),
                    };
                }
                "error" => {
                    if params["willRetry"] != true {
                        return Err("protocol_error");
                    }
                }
                _ => {}
            }
        }
    }
    fn publish_output(&self, id: &Identity, order: &[String], texts: &HashMap<String, String>) {
        let mut output = String::new();
        for item in order {
            if !output.is_empty() {
                append_bounded(&mut output, "\n", OUTPUT_LIMIT);
            }
            append_bounded(&mut output, &texts[item], OUTPUT_LIMIT);
        }
        self.update(id, |task| set_output(task, output));
    }
}
struct Pending {
    rpc_id: Value,
    kind: &'static str,
    decisions: Vec<String>,
}
fn supported_decisions(params: &Value, kind: &str) -> Result<Vec<String>, &'static str> {
    let legacy = || {
        vec![
            "accept".to_owned(),
            "decline".to_owned(),
            "cancel".to_owned(),
        ]
    };
    if kind == "file" {
        return Ok(legacy());
    }
    // The pinned kind default is command. writeStdin has different content
    // semantics and is deliberately not represented as a shell approval.
    if params.get("kind").is_some_and(|kind| kind != "command") {
        return Err("unsupported_request");
    }
    let Some(choices) = params
        .get("availableDecisions")
        .filter(|choices| !choices.is_null())
    else {
        // Compatibility behavior for older/absent optional lists; this does
        // not infer capabilities from a present restricted list.
        return Ok(legacy());
    };
    let choices = choices
        .as_array()
        .filter(|choices| !choices.is_empty() && choices.len() <= 32)
        .ok_or("unsupported_request")?;
    let mut supported = Vec::new();
    for choice in choices {
        match choice {
            Value::String(choice) if matches!(choice.as_str(), "accept" | "decline" | "cancel") => {
                if !supported.contains(choice) {
                    supported.push(choice.clone());
                }
            }
            Value::String(_) | Value::Object(_) => {}
            _ => return Err("protocol_error"),
        }
    }
    if supported.is_empty() {
        Err("unsupported_request")
    } else {
        Ok(supported)
    }
}
struct ItemContext {
    files: Vec<String>,
    diff: String,
    command: Option<String>,
    cwd: Option<String>,
}
fn item_context(item: &Value) -> Result<ItemContext, &'static str> {
    let mut context = ItemContext {
        files: Vec::new(),
        diff: String::new(),
        command: optional_text(&item["command"], 8192),
        cwd: optional_text(&item["cwd"], 32768),
    };
    if item["type"] == "fileChange" {
        for change in item["changes"]
            .as_array()
            .filter(|changes| changes.len() <= 64)
            .ok_or("protocol_error")?
        {
            let path = change["path"]
                .as_str()
                .filter(|path| bounded(path, 1, 32768))
                .ok_or("protocol_error")?;
            context.files.push(path.into());
            append_bounded(&mut context.diff, path, 4096);
            append_bounded(&mut context.diff, "\n", 4096);
            if let Some(diff) = change["diff"].as_str() {
                append_bounded(&mut context.diff, diff, 4096);
                append_bounded(&mut context.diff, "\n", 4096);
            }
        }
    }
    Ok(context)
}
fn bounded(value: &str, min: usize, max: usize) -> bool {
    value.len() >= min && value.len() <= max && !value.contains('\0') && !value.trim().is_empty()
}
fn optional_text(value: &Value, max: usize) -> Option<String> {
    value
        .as_str()
        .filter(|value| value.len() <= max && !value.contains('\0'))
        .map(str::to_owned)
}
fn append_bounded(target: &mut String, text: &str, max: usize) {
    let mut length = text.len().min(max.saturating_sub(target.len()));
    while !text.is_char_boundary(length) {
        length -= 1
    }
    target.push_str(&text[..length]);
}
fn set_output(task: &mut Task, text: String) {
    task.truncated |= text.len() >= OUTPUT_LIMIT;
    task.output = text;
}
fn overlaps(left: &str, right: &str) -> bool {
    let normalize = |value: &str| {
        value
            .replace('/', "\\")
            .trim_end_matches('\\')
            .to_lowercase()
    };
    let left = normalize(left);
    let right = normalize(right);
    left == right || left.starts_with(&(right.clone() + "\\")) || right.starts_with(&(left + "\\"))
}
fn require_route(params: &Value, thread: &str, turn: &str) -> Result<(), &'static str> {
    if params["threadId"] == thread && params["turnId"] == turn {
        Ok(())
    } else {
        Err("protocol_error")
    }
}
fn questions(value: &Value) -> Result<Vec<Value>, &'static str> {
    let source = value
        .as_array()
        .filter(|questions| !questions.is_empty() && questions.len() <= 16)
        .ok_or("protocol_error")?;
    let mut ids = HashSet::new();
    source.iter().map(|question|{let id=task_protocol::identifier(&question["id"])?;if !ids.insert(id.to_owned()){return Err("protocol_error")}let header=question["header"].as_str().filter(|text|text.len()<=512).ok_or("protocol_error")?;let text=question["question"].as_str().filter(|text|text.len()<=8192).ok_or("protocol_error")?;let mut options=Vec::new();if let Some(source)=question.get("options").filter(|value|!value.is_null()){for option in source.as_array().filter(|options|options.len()<=32).ok_or("protocol_error")?{options.push(json!({"label":option["label"].as_str().filter(|text|text.len()<=512).ok_or("protocol_error")?,"description":option["description"].as_str().filter(|text|text.len()<=4096).ok_or("protocol_error")?}));}}Ok(json!({"id":id,"header":header,"question":text,"isOther":question["isOther"].as_bool().unwrap_or(false),"isSecret":question["isSecret"].as_bool().unwrap_or(false),"options":options}))}).collect()
}
fn validate_answers(questions: &Value, answers: &Value) -> Result<(), String> {
    let answers = answers
        .as_object()
        .filter(|answers| answers.len() <= 16)
        .ok_or("invalid_request")?;
    let questions = questions.as_array().ok_or("invalid_request")?;
    if answers.len() != questions.len() {
        return Err("invalid_request".into());
    }
    for question in questions {
        let id = question["id"].as_str().ok_or("invalid_request")?;
        let answer = answers
            .get(id)
            .and_then(Value::as_object)
            .filter(|answer| answer.len() == 1)
            .and_then(|answer| answer.get("answers"))
            .and_then(Value::as_array)
            .filter(|answer| !answer.is_empty() && answer.len() <= 16)
            .ok_or("invalid_request")?;
        if answer
            .iter()
            .any(|value| value.as_str().is_none_or(|text| !bounded(text, 1, 8192)))
        {
            return Err("invalid_request".into());
        }
    }
    Ok(())
}
static MANAGER: LazyLock<Arc<Manager>> = LazyLock::new(Manager::new);
pub(crate) fn execute(command: &str, payload: Value) -> Result<Value, String> {
    MANAGER.execute(command, payload)
}

#[cfg(test)]
mod tests;
