use super::types::{SseMessage, StreamEvent};
use super::{chat::ChatAdapter, collector::Collector, sse::SseDecoder, types::StreamError};
use super::{replay, responses::ResponsesAdapter};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tokio::time::{timeout_at, Instant as Deadline};
use url::Url;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartRequest {
    mode: String,
    protocol: String,
    base_url: String,
    model: String,
    prompt: String,
    resolved_proxy: String,
    #[serde(default = "default_tokens")]
    max_output_tokens: u32,
    #[serde(default = "default_timeout")]
    timeout_ms: u64,
    #[serde(default = "default_idle")]
    idle_timeout_ms: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OfflineRequest {
    mode: String,
    protocol: String,
    scenario_id: String,
}
fn default_tokens() -> u32 {
    256
}
fn default_timeout() -> u64 {
    30_000
}
fn default_idle() -> u64 {
    5_000
}

// Intentionally no Debug/Serialize: prompt and URL never enter diagnostics.
pub(super) struct Config {
    pub endpoint: Url,
    pub protocol: String,
    pub execution_mode: String,
    pub scenario_id: Option<String>,
    pub model: String,
    prompt: String,
    max_output_tokens: u32,
    timeout: Duration,
    idle: Duration,
}
impl Config {
    pub fn parse(payload: Value) -> Result<Self, String> {
        if payload.get("mode").and_then(Value::as_str) == Some("live") {
            return Err("live_execution_disabled".into());
        }
        if payload.get("mode").and_then(Value::as_str) == Some("offline_replay") {
            let request: OfflineRequest =
                serde_json::from_value(payload).map_err(|_| "invalid_benchmark_request")?;
            replay::validate(&request.protocol, &request.scenario_id)?;
            return Ok(Self {
                endpoint: Url::parse("http://127.0.0.1:1").expect("literal URL"),
                protocol: request.protocol,
                execution_mode: request.mode,
                scenario_id: Some(request.scenario_id),
                model: "fixture-model".into(),
                prompt: "Synthetic offline measurement".into(),
                max_output_tokens: 256,
                timeout: Duration::from_secs(10),
                idle: Duration::from_secs(5),
            });
        }
        let request: StartRequest =
            serde_json::from_value(payload).map_err(|_| "invalid_benchmark_request")?;
        if request.mode != "local_replay" {
            return Err("unsupported_execution_mode".into());
        }
        if request.protocol != "chat_completions" && request.protocol != "responses" {
            return Err("unsupported_protocol".into());
        }
        if request.model.is_empty()
            || request.model.len() > 256
            || request.model.chars().any(char::is_control)
            || request.prompt.is_empty()
            || request.prompt.len() > 65_536
            || !(1..=8192).contains(&request.max_output_tokens)
            || !(100..=120_000).contains(&request.timeout_ms)
            || !(50..=30_000).contains(&request.idle_timeout_ms)
            || request.idle_timeout_ms > request.timeout_ms
        {
            return Err("invalid_benchmark_limits".into());
        }
        Ok(Self {
            endpoint: if request.protocol == "chat_completions" {
                super::proxy_route::replay_endpoint(&request.base_url, &request.resolved_proxy)?
            } else {
                super::proxy_route::protocol_endpoint(
                    &request.base_url,
                    &request.resolved_proxy,
                    &request.protocol,
                )?
            },
            protocol: request.protocol,
            execution_mode: request.mode,
            scenario_id: None,
            model: request.model,
            prompt: request.prompt,
            max_output_tokens: request.max_output_tokens,
            timeout: Duration::from_millis(request.timeout_ms),
            idle: Duration::from_millis(request.idle_timeout_ms),
        })
    }
}
enum Adapter {
    Chat(ChatAdapter),
    Responses(ResponsesAdapter),
}
impl Adapter {
    fn accept(&mut self, message: SseMessage) -> Result<Vec<StreamEvent>, StreamError> {
        match self {
            Self::Chat(a) => a.accept(message),
            Self::Responses(a) => a.accept(message),
        }
    }
    fn response_model(&self) -> Option<&str> {
        match self {
            Self::Chat(a) => a.response_model(),
            Self::Responses(a) => a.response_model(),
        }
    }
}

pub(super) struct Progress {
    pub snapshot: Value,
    pub response_model: Option<String>,
    pub streaming: bool,
}
pub(super) struct Outcome {
    pub snapshot: Value,
    pub response_model: Option<String>,
}
fn elapsed(start: Instant) -> u64 {
    start.elapsed().as_nanos().min(u64::MAX as u128) as u64
}

pub(super) async fn run(
    config: Config,
    mut cancel: watch::Receiver<bool>,
    mut publish: impl FnMut(Progress),
) -> Outcome {
    let mut collector = if config.protocol == "responses" {
        Collector::for_responses()
    } else {
        Collector::new()
    };
    let mut adapter = if config.protocol == "responses" {
        Adapter::Responses(ResponsesAdapter::new())
    } else {
        Adapter::Chat(ChatAdapter::new())
    };
    let outcome = drive(
        &config,
        &mut cancel,
        &mut collector,
        &mut adapter,
        &mut publish,
    )
    .await;
    if let Err(error) = outcome {
        collector.fail(&error.code);
    }
    Outcome {
        snapshot: collector.snapshot(),
        response_model: adapter.response_model().map(str::to_owned),
    }
}

async fn drive(
    config: &Config,
    cancel: &mut watch::Receiver<bool>,
    collector: &mut Collector,
    adapter: &mut Adapter,
    publish: &mut impl FnMut(Progress),
) -> Result<(), StreamError> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .connect_timeout(Duration::from_secs(3).min(config.timeout))
        .read_timeout(config.idle)
        .pool_max_idle_per_host(0)
        .build()
        .map_err(|_| StreamError::new("transport_setup"))?;
    let body = if config.protocol == "responses" {
        json!({"model":config.model,"input":config.prompt,"max_output_tokens":config.max_output_tokens,"stream":true,"store":false})
    } else {
        json!({"model":config.model,"messages":[{"role":"user","content":config.prompt}],
        "max_completion_tokens":config.max_output_tokens,"n":1,"stream":true,"stream_options":{"include_usage":true},"store":false})
    };
    let request = client
        .post(config.endpoint.clone())
        .header(reqwest::header::ACCEPT, "text/event-stream")
        .header(reqwest::header::CONNECTION, "close")
        .json(&body)
        .build()
        .map_err(|_| StreamError::new("transport_setup"))?;
    let start = Instant::now();
    let deadline = Deadline::now() + config.timeout;
    let header_deadline = deadline.min(Deadline::now() + config.idle);
    if *cancel.borrow() {
        return Err(StreamError::new("cancelled"));
    }
    let mut response = tokio::select! {
        biased;
        _ = cancel.changed() => return Err(StreamError::new("cancelled")),
        result = timeout_at(header_deadline, client.execute(request)) => {
            result.map_err(|_| StreamError::new(if Deadline::now() >= deadline { "request_timeout" } else { "header_timeout" }))?
                .map_err(|error| StreamError::new(if error.is_timeout() { "header_timeout" } else { "transport_error" }))?
        }
    };
    if !response.status().is_success() {
        return Err(StreamError::new("http_status"));
    }
    let media_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim();
    if !media_type.eq_ignore_ascii_case("text/event-stream") {
        return Err(StreamError::new("invalid_content_type"));
    }
    publish(Progress {
        snapshot: collector.snapshot(),
        response_model: None,
        streaming: true,
    });
    let mut decoder = SseDecoder::new();
    let mut received = 0usize;
    loop {
        let idle_deadline = deadline.min(Deadline::now() + config.idle);
        let next = tokio::select! {
            biased;
            _ = cancel.changed() => return Err(StreamError::new("cancelled")),
            result = timeout_at(idle_deadline, response.chunk()) => {
                result.map_err(|_| StreamError::new(if Deadline::now() >= deadline { "request_timeout" } else { "body_idle_timeout" }))?
                    .map_err(|error| StreamError::new(if error.is_timeout() { "body_idle_timeout" } else { "transport_error" }))?
            }
        };
        let Some(chunk) = next else {
            decoder.finish()?;
            collector.http_end(elapsed(start))?;
            return Ok(());
        };
        received = received
            .checked_add(chunk.len())
            .ok_or_else(|| StreamError::new("body_too_large"))?;
        if received > 8 * 1024 * 1024 {
            return Err(StreamError::new("body_too_large"));
        }
        let at = elapsed(start);
        for message in decoder.push(&chunk)? {
            for event in adapter.accept(message)? {
                collector.observe(at, event)?;
            }
        }
        publish(Progress {
            snapshot: collector.snapshot(),
            response_model: adapter.response_model().map(str::to_owned),
            streaming: true,
        });
    }
}
