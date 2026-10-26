//! Process-owned synthetic loopback replay; never accepts an external target.
use serde_json::{json, Value};
use std::net::TcpListener;
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::watch,
};
const SCENARIOS: &[(&str, &str, &str, &str)] = &[
    (
        "chat_text_complete",
        "chat_completions",
        "完整文本",
        "合成 Chat SSE、最终 usage、真实 EOF",
    ),
    (
        "chat_reasoning_complete",
        "chat_completions",
        "推理与文本",
        "合成推理后可见文本，流式速率范围不可用",
    ),
    (
        "chat_missing_usage",
        "chat_completions",
        "缺失 usage",
        "终态缺少 token usage，样本失败",
    ),
    (
        "chat_truncated",
        "chat_completions",
        "截断流",
        "没有协议终态，样本失败",
    ),
    (
        "chat_slow",
        "chat_completions",
        "缓慢回放",
        "等待中可取消或中断",
    ),
    (
        "responses_text_complete",
        "responses",
        "完整文本",
        "合成 Responses SSE、最终 usage、真实 EOF",
    ),
    (
        "responses_reasoning_complete",
        "responses",
        "推理与文本",
        "合成推理摘要后可见文本，流式速率范围不可用",
    ),
    (
        "responses_missing_usage",
        "responses",
        "缺失 usage",
        "终态缺少 token usage，样本失败",
    ),
    (
        "responses_truncated",
        "responses",
        "截断流",
        "没有协议终态，样本失败",
    ),
    (
        "responses_slow",
        "responses",
        "缓慢回放",
        "等待中可取消或中断",
    ),
    (
        "responses_failed",
        "responses",
        "失败终态",
        "保留合法 usage，样本失败",
    ),
    (
        "responses_incomplete",
        "responses",
        "未完成终态",
        "保留合法 usage，样本失败",
    ),
];
pub(super) fn catalog() -> Value {
    json!({"offlineOnly":false,"liveExecutionEnabled":true,"protocols":["chat_completions","responses"],"scenarios":SCENARIOS.iter().map(|(id,p,label,desc)|json!({"scenarioId":id,"protocol":p,"label":label,"description":desc})).collect::<Vec<_>>()})
}
pub(super) fn validate(protocol: &str, id: &str) -> Result<(), String> {
    if protocol != "chat_completions" && protocol != "responses" {
        return Err("unsupported_protocol".into());
    }
    if !SCENARIOS
        .iter()
        .any(|(s, p, _, _)| *s == id && *p == protocol)
    {
        return Err("invalid_replay_scenario".into());
    }
    Ok(())
}
pub(super) struct Fixture {
    listener: TcpListener,
    scenario: String,
    protocol: String,
}
impl Fixture {
    pub fn bind(protocol: &str, scenario: &str) -> Result<(Self, url::Url), String> {
        validate(protocol, scenario)?;
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| "fixture_bind_failed")?;
        listener
            .set_nonblocking(true)
            .map_err(|_| "fixture_bind_failed")?;
        let port = listener
            .local_addr()
            .map_err(|_| "fixture_bind_failed")?
            .port();
        let endpoint = super::proxy_route::protocol_endpoint(
            &format!("http://127.0.0.1:{port}/v1"),
            "DIRECT",
            protocol,
        )?;
        Ok((
            Self {
                listener,
                scenario: scenario.into(),
                protocol: protocol.into(),
            },
            endpoint,
        ))
    }
    pub async fn run(self, mut stop: watch::Receiver<bool>) {
        if *stop.borrow() {
            return;
        }
        tokio::select! {biased; _=stop.changed()=>(), _=self.serve()=>()};
    }
    async fn serve(self) -> std::io::Result<()> {
        let listener = tokio::net::TcpListener::from_std(self.listener)?;
        let (mut stream, _) = listener.accept().await?;
        // Read a bounded complete request; no request content is retained or logged.
        let mut request = Vec::new();
        let mut buffer = [0u8; 4096];
        loop {
            let n = stream.read(&mut buffer).await?;
            if n == 0 {
                return Ok(());
            }
            request.extend_from_slice(&buffer[..n]);
            if request.len() > 128 * 1024 {
                return Ok(());
            }
            if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&request[..end]);
                let length = headers
                    .lines()
                    .find_map(|line| {
                        let (k, v) = line.split_once(':')?;
                        if k.eq_ignore_ascii_case("content-length") {
                            v.trim().parse::<usize>().ok()
                        } else {
                            None
                        }
                    })
                    .unwrap_or(0);
                if request.len() >= end + 4 + length {
                    break;
                }
            }
        }
        drop(request);
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            )
            .await?;
        for (delay, frame) in frames(&self.protocol, &self.scenario) {
            tokio::time::sleep(Duration::from_millis(delay)).await;
            stream.write_all(frame.as_bytes()).await?;
        }
        // Deliberate terminal/EOF separation is observed by the production client.
        tokio::time::sleep(Duration::from_millis(40)).await;
        stream.shutdown().await
    }
}
fn frame(value: Value) -> String {
    format!("data: {value}\n\n")
}
fn response_event(seq: u64, kind: &str, mut body: Value) -> String {
    body["type"] = json!(kind);
    body["sequence_number"] = json!(seq);
    format!("event: {kind}\ndata: {body}\n\n")
}
fn frames(protocol: &str, scenario: &str) -> Vec<(u64, String)> {
    let slow = if scenario.ends_with("slow") { 2000 } else { 20 };
    let reasoning = scenario.contains("reasoning");
    let missing = scenario.contains("missing_usage");
    let truncated = scenario.contains("truncated");
    if protocol == "chat_completions" {
        let chunk = |delta: Value, finish: Value| {
            frame(
                json!({"id":"fixture-response","model":"fixture-response-model","object":"chat.completion.chunk","choices":[{"index":0,"delta":delta,"finish_reason":finish}]}),
            )
        };
        let mut result = vec![(
            0,
            chunk(json!({"role":"assistant","content":""}), Value::Null),
        )];
        if reasoning {
            result.push((
                20,
                chunk(
                    json!({"reasoning_content":"synthetic reasoning"}),
                    Value::Null,
                ),
            ));
        }
        result.push((slow, chunk(json!({"content":"synthetic "}), Value::Null)));
        result.push((20, chunk(json!({"content":"text"}), Value::Null)));
        if !truncated {
            result.push((20, chunk(json!({}), json!("stop"))));
            if !missing {
                result.push((20,frame(json!({"id":"fixture-response","model":"fixture-response-model","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":100,"total_tokens":110,"completion_tokens_details":{"reasoning_tokens":if reasoning{20}else{0}}}}))));
            }
            result.push((20, "data: [DONE]\n\n".into()));
        }
        return result;
    }
    let mut seq = 0;
    let mut emit = |kind: &str, body: Value| {
        let v = response_event(seq, kind, body);
        seq += 1;
        v
    };
    let response = |status: &str, usage: Value| json!({"id":"fixture-response","model":"fixture-response-model","status":status,"output":[],"usage":usage});
    let mut result = vec![(
        0,
        emit(
            "response.created",
            json!({"response":response("in_progress",Value::Null)}),
        ),
    )];
    if reasoning {
        result.push((
            0,
            emit(
                "response.output_item.added",
                json!({"output_index":0,"item":{"id":"reason","type":"reasoning","summary":[]}}),
            ),
        ));
        result.push((20,emit("response.reasoning_summary_text.delta",json!({"output_index":0,"item_id":"reason","summary_index":0,"delta":"synthetic reasoning"}))));
    }
    let index = if reasoning { 1 } else { 0 };
    result.push((0,emit("response.output_item.added",json!({"output_index":index,"item":{"id":"message","type":"message","role":"assistant","content":[]}}))));
    for text in ["synthetic ", "text"] {
        result.push((
            slow,
            emit(
                "response.output_text.delta",
                json!({"output_index":index,"item_id":"message","content_index":0,"delta":text}),
            ),
        ));
    }
    if !truncated {
        result.push((20,emit("response.output_text.done",json!({"output_index":index,"item_id":"message","content_index":0,"text":"synthetic text"}))));
        let status = if scenario.ends_with("incomplete") {
            "incomplete"
        } else if scenario.ends_with("failed") {
            "failed"
        } else {
            "completed"
        };
        let usage = if missing {
            Value::Null
        } else {
            json!({"input_tokens":10,"output_tokens":100,"total_tokens":110,"output_tokens_details":{"reasoning_tokens":if reasoning{20}else{0}}})
        };
        result.push((20,emit(&format!("response.{status}"),json!({"response":({let mut r=response(status,usage);let mut output=vec![];if reasoning{output.push(json!({"id":"reason","type":"reasoning","summary":[{"type":"summary_text","text":"synthetic reasoning"}]}));}output.push(json!({"id":"message","type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic text"}]}));r["output"]=json!(output);r})}))));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    // Catches detaching the serving future: after owned completion both the
    // listener and accepted socket must have closed, even during a slow frame.
    #[tokio::test]
    async fn joined_fixture_stop_closes_listener_and_accepted_client() {
        let (fixture, endpoint) = Fixture::bind("responses", "responses_slow").unwrap();
        let address = fixture.listener.local_addr().unwrap();
        let (stop, receiver) = watch::channel(false);
        let task = tokio::spawn(fixture.run(receiver));
        let mut client = tokio::net::TcpStream::connect(address).await.unwrap();
        client
            .write_all(
                format!(
                    "POST {} HTTP/1.1\r\nHost: fixture\r\nContent-Length: 2\r\n\r\n{{}}",
                    endpoint.path()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut bytes = [0; 4096];
        assert!(
            tokio::time::timeout(Duration::from_secs(1), client.read(&mut bytes))
                .await
                .unwrap()
                .unwrap()
                > 0
        );
        stop.send(true).unwrap();
        tokio::time::timeout(Duration::from_millis(500), task)
            .await
            .unwrap()
            .unwrap();
        // Drain any already-buffered synthetic control frames, then observe EOF.
        loop {
            if tokio::time::timeout(Duration::from_secs(1), client.read(&mut bytes))
                .await
                .unwrap()
                .unwrap()
                == 0
            {
                break;
            }
        }
        assert!(
            std::net::TcpStream::connect_timeout(&address, Duration::from_millis(100)).is_err()
        );
    }
}
