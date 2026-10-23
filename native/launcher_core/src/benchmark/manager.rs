use super::{
    collector::Collector,
    transport::{self, Config, Progress},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::{
    runtime::{Handle, Runtime},
    sync::watch,
    task::JoinHandle,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Identity {
    run_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShutdownIdentity {
    run_id: Option<String>,
}

struct View {
    state: &'static str,
    protocol: String,
    execution_mode: String,
    source: Value,
    model: String,
    response_model: Option<String>,
    started: Instant,
    elapsed_ns: Option<u64>,
    facts: Value,
}
impl View {
    fn terminal(&self) -> bool {
        matches!(
            self.state,
            "completed" | "failed" | "cancelled" | "interrupted"
        )
    }
    fn freeze(&mut self, state: &'static str) {
        self.state = state;
        self.elapsed_ns = Some(self.started.elapsed().as_nanos().min(u64::MAX as u128) as u64);
    }
    fn abort(&mut self, state: &'static str, code: &'static str) {
        if self.terminal() {
            return;
        }
        self.facts["successfulSample"] = json!(false);
        if let Some(reasons) = self.facts["reasons"].as_array_mut() {
            if !reasons.iter().any(|v| v == code) {
                reasons.push(json!(code));
            }
        }
        for metric in [
            "streamTokensPerSecond",
            "e2eTokensPerSecond",
            "fullResponseTokensPerSecond",
        ] {
            self.facts["metrics"][metric]["value"] = Value::Null;
            self.facts["metrics"][metric]["quality"] = json!("unavailable");
            if let Some(reasons) = self.facts["metrics"][metric]["reasons"].as_array_mut() {
                if !reasons.iter().any(|v| v == code) {
                    reasons.push(json!(code));
                }
            }
        }
        self.freeze(state);
    }
    fn progress(&mut self, progress: Progress) {
        if self.terminal() {
            return;
        }
        self.facts = progress.snapshot;
        self.response_model = progress.response_model;
        if progress.streaming {
            self.state = "streaming";
        }
    }
    fn snapshot(&self, id: &str, cleaning: bool) -> Value {
        let mut result = self.facts.clone();
        let object = result
            .as_object_mut()
            .expect("collector snapshot is object");
        object.insert("runId".into(), json!(id));
        object.insert("state".into(), json!(self.state));
        object.insert("measurementKind".into(), json!("independent_api"));
        object.insert("protocol".into(), json!(self.protocol));
        object.insert("executionMode".into(), json!(self.execution_mode));
        object.insert("source".into(), self.source.clone());
        if self.execution_mode == "offline_replay" {
            object.insert("engineVersion".into(), json!("m3-rust-v1+aiperf-b1746a84"));
        }
        object.insert("requestedModel".into(), json!(self.model));
        object.insert("responseModel".into(), json!(self.response_model));
        object.insert("cleanupPending".into(), json!(cleaning));
        object.insert(
            "elapsedNs".into(),
            json!(self.elapsed_ns.unwrap_or_else(|| self
                .started
                .elapsed()
                .as_nanos()
                .min(u64::MAX as u128) as u64)),
        );
        result
    }
}
struct OwnedRun {
    id: String,
    view: Arc<Mutex<View>>,
    cancel: watch::Sender<bool>,
    task: Option<JoinHandle<()>>,
    cleanup_pending: bool,
}
struct State {
    accepting: bool,
    run: Option<OwnedRun>,
}

/// One process-owned runtime, with one worker thread and at most one owned job.
/// The task handle remains owned through cancellation and terminal cleanup.
pub(super) struct Manager {
    state: Mutex<State>,
    runtime: Mutex<Option<Runtime>>,
    handle: Handle,
    nonce: String,
    sequence: AtomicU64,
}
impl Manager {
    pub fn new() -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .thread_name("m2-benchmark")
            .build()
            .map_err(|_| "benchmark_runtime_unavailable")?;
        let handle = runtime.handle().clone();
        // OS-seeded standard-library random state plus process/time identity.
        // The nonce is diagnostic identity only; it is never used for timing.
        let mut random = RandomState::new().build_hasher();
        random.write_u32(std::process::id());
        let wall = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        random.write_u128(wall);
        let nonce = format!(
            "{:x}-{:x}-{:016x}",
            std::process::id(),
            wall,
            random.finish()
        );
        Ok(Self {
            state: Mutex::new(State {
                accepting: true,
                run: None,
            }),
            runtime: Mutex::new(Some(runtime)),
            handle,
            nonce,
            sequence: AtomicU64::new(1),
        })
    }
    pub fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        if command == "benchmark_catalog" {
            if payload.as_object().is_none_or(|o| !o.is_empty()) {
                return Err("invalid_benchmark_request".into());
            }
            return Ok(super::replay::catalog());
        }
        if command == "benchmark_start" {
            return self.start(Config::parse(payload)?);
        }
        if command == "benchmark_shutdown" {
            let id: ShutdownIdentity =
                serde_json::from_value(payload).map_err(|_| "invalid_benchmark_request")?;
            return self.shutdown(id.run_id.as_deref());
        }
        let identity: Identity =
            serde_json::from_value(payload).map_err(|_| "invalid_benchmark_request")?;
        match command {
            "benchmark_status" => self.status(&identity.run_id),
            "benchmark_cancel" => self.cancel(&identity.run_id, "cancelled", "cancelled"),
            "benchmark_interrupt" => self.cancel(&identity.run_id, "interrupted", "interrupted"),
            "benchmark_clear" => self.clear(&identity.run_id),
            _ => Err("unknown_benchmark_command".into()),
        }
    }
    fn start(&self, mut config: Config) -> Result<Value, String> {
        self.reap()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "benchmark_state_unavailable")?;
        if !state.accepting {
            return Err("benchmark_shutdown".into());
        }
        if state.run.is_some() {
            return Err("benchmark_busy".into());
        }
        // All schema/scenario checks and admission precede listener allocation.
        let fixture = if let Some(scenario) = config.scenario_id.as_deref() {
            let (fixture, endpoint) = super::replay::Fixture::bind(&config.protocol, scenario)?;
            config.endpoint = endpoint;
            Some(fixture)
        } else {
            None
        };
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed);
        let id = format!("{}-{sequence:x}", self.nonce);
        let view = Arc::new(Mutex::new(View {
            state: "queued",
            protocol: config.protocol.clone(),
            execution_mode: config.execution_mode.clone(),
            source: if let Some(scenario) = config.scenario_id.as_deref() {
                json!({"kind":"offline_fixture","scenarioId":scenario,"networkScope":"literal_loopback_only"})
            } else {
                json!({"kind":"local_replay","scenarioId":null,"networkScope":"literal_loopback_only"})
            },
            model: config.model.clone(),
            response_model: None,
            started: Instant::now(),
            elapsed_ns: None,
            facts: if config.protocol == "responses" {
                Collector::for_responses().snapshot()
            } else {
                Collector::new().snapshot()
            },
        }));
        let initial = view
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .snapshot(&id, true);
        let (cancel, receiver) = watch::channel(false);
        let worker_view = view.clone();
        let task = self.handle.spawn(async move {
            {
                let mut live = worker_view.lock().unwrap_or_else(|e| e.into_inner());
                if !live.terminal() {
                    live.state = "connecting";
                }
            }
            let progress_view = worker_view.clone();
            let (fixture_stop, fixture_rx) = watch::channel(false);
            let client = async {
                let outcome = transport::run(config, receiver, move |progress| {
                    progress_view
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .progress(progress);
                })
                .await;
                let _ = fixture_stop.send(true);
                outcome
            };
            let server = async {
                if let Some(fixture) = fixture {
                    fixture.run(fixture_rx).await;
                }
            };
            // Both futures are owned by this task. Dropping/cancelling the server
            // drops its listener/socket; cleanup is true only after BOTH finish.
            let (outcome, ()) = tokio::join!(client, server);
            let mut live = worker_view.lock().unwrap_or_else(|e| e.into_inner());
            if !live.terminal() {
                live.facts = outcome.snapshot;
                live.response_model = outcome.response_model;
                let terminal = if live.facts["successfulSample"] == true {
                    "completed"
                } else {
                    "failed"
                };
                live.freeze(terminal);
            }
        });
        state.run = Some(OwnedRun {
            id: id.clone(),
            view,
            cancel,
            task: Some(task),
            cleanup_pending: true,
        });
        Ok(initial)
    }
    // Only finished tasks are joined here. The task is removed while the slot
    // remains marked cleaning, so simultaneous clear/start cannot orphan it.
    fn reap(&self) -> Result<(), String> {
        let finished = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "benchmark_state_unavailable")?;
            state.run.as_mut().and_then(|run| {
                if run.task.as_ref().is_some_and(JoinHandle::is_finished) {
                    Some((run.id.clone(), run.view.clone(), run.task.take().unwrap()))
                } else {
                    None
                }
            })
        };
        if let Some((id, view, task)) = finished {
            let joined = self.handle.block_on(task);
            {
                let mut live = view.lock().unwrap_or_else(|e| e.into_inner());
                if joined.is_err() {
                    live.abort("failed", "worker_panic");
                } else if !live.terminal() {
                    live.abort("failed", "worker_exit");
                }
            }
            let mut state = self
                .state
                .lock()
                .map_err(|_| "benchmark_state_unavailable")?;
            if let Some(run) = state.run.as_mut().filter(|run| run.id == id) {
                run.cleanup_pending = false;
            }
        }
        Ok(())
    }
    fn status(&self, id: &str) -> Result<Value, String> {
        self.reap()?;
        let state = self
            .state
            .lock()
            .map_err(|_| "benchmark_state_unavailable")?;
        let run = state
            .run
            .as_ref()
            .filter(|run| run.id == id)
            .ok_or("unknown_benchmark_run")?;
        let live = run.view.lock().unwrap_or_else(|e| e.into_inner());
        Ok(live.snapshot(&run.id, run.cleanup_pending))
    }
    fn cancel(
        &self,
        id: &str,
        terminal: &'static str,
        reason: &'static str,
    ) -> Result<Value, String> {
        self.reap()?;
        let state = self
            .state
            .lock()
            .map_err(|_| "benchmark_state_unavailable")?;
        let run = state
            .run
            .as_ref()
            .filter(|run| run.id == id)
            .ok_or("unknown_benchmark_run")?;
        let mut live = run.view.lock().unwrap_or_else(|e| e.into_inner());
        live.abort(terminal, reason);
        let _ = run.cancel.send(true);
        Ok(live.snapshot(&run.id, run.cleanup_pending))
    }
    fn clear(&self, id: &str) -> Result<Value, String> {
        self.reap()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "benchmark_state_unavailable")?;
        let run = state
            .run
            .as_ref()
            .filter(|run| run.id == id)
            .ok_or("unknown_benchmark_run")?;
        if run.cleanup_pending
            || !run
                .view
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .terminal()
        {
            return Err("benchmark_busy".into());
        }
        state.run = None;
        Ok(json!({"cleared":true,"runId":id}))
    }
    fn shutdown(&self, id: Option<&str>) -> Result<Value, String> {
        let deadline = Instant::now() + Duration::from_millis(500);
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "benchmark_state_unavailable")?;
            if let Some(run) = state.run.as_ref() {
                if id != Some(run.id.as_str()) {
                    return Err("unknown_benchmark_run".into());
                }
                run.view
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .abort("cancelled", "shutdown");
                let _ = run.cancel.send(true);
            } else if id.is_some() {
                return Err("unknown_benchmark_run".into());
            }
            state.accepting = false;
        }
        loop {
            self.reap()?;
            let cleanup_complete = {
                let state = self
                    .state
                    .lock()
                    .map_err(|_| "benchmark_state_unavailable")?;
                state.run.as_ref().is_none_or(|run| !run.cleanup_pending)
            };
            if cleanup_complete {
                let runtime = self
                    .runtime
                    .lock()
                    .map_err(|_| "benchmark_state_unavailable")?
                    .take();
                if let Some(runtime) = runtime {
                    runtime.shutdown_timeout(deadline.saturating_duration_since(Instant::now()));
                }
                return Ok(json!({"accepting":false,"cleanupComplete":true,"runId":id}));
            }
            if Instant::now() >= deadline {
                return Ok(json!({"accepting":false,"cleanupComplete":false,"runId":id}));
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}
impl Drop for Manager {
    fn drop(&mut self) {
        let id = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.run.as_ref().map(|run| run.id.clone()));
        let _ = self.shutdown(id.as_deref());
        // Runtime shutdown is always outside either state/view lock.
        if let Ok(runtime) = self.runtime.get_mut() {
            if let Some(runtime) = runtime.take() {
                runtime.shutdown_timeout(Duration::from_millis(500));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn panicked_owned_task_is_reaped_as_safe_failure() {
        let manager = Manager::new().unwrap();
        let view = Arc::new(Mutex::new(View {
            state: "connecting",
            protocol: "chat_completions".into(),
            execution_mode: "local_replay".into(),
            source: json!({"kind":"local_replay","scenarioId":null,"networkScope":"literal_loopback_only"}),
            model: "fixture".into(),
            response_model: None,
            started: Instant::now(),
            elapsed_ns: None,
            facts: Collector::new().snapshot(),
        }));
        let (cancel, _) = watch::channel(false);
        let task = manager
            .handle
            .spawn(async { panic!("synthetic panic marker") });
        manager.state.lock().unwrap().run = Some(OwnedRun {
            id: "panic-run".into(),
            view,
            cancel,
            task: Some(task),
            cleanup_pending: true,
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let value = manager.status("panic-run").unwrap();
            if value["cleanupPending"] == false {
                assert_eq!(value["state"], "failed");
                assert!(value["reasons"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|v| v == "worker_panic"));
                assert!(!value.to_string().contains("synthetic panic marker"));
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        manager.clear("panic-run").unwrap();
        assert_eq!(manager.shutdown(None).unwrap()["cleanupComplete"], true);
    }
}
