//! Standalone fake app-server for protocol/error/cleanup tests. Never uses credentials or network.
use std::{
    io::{self, BufRead},
    time::Duration,
};
fn main() {
    let mode = std::env::current_exe()
        .unwrap()
        .file_stem()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    if mode == "current_args" {
        assert_eq!(
            std::env::args().skip(1).collect::<Vec<_>>(),
            ["app-server", "--listen", "stdio://"]
        );
    }
    let mut account_reads = 0;
    let mut requests = 0;
    let mut held_id = None;
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let Some(tail) = line.split("\"id\":").nth(1) else {
            continue;
        };
        let id: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
        requests += 1;
        if mode == "rpc_receipt" {
            println!(r#"{{"id":{id},"result":{{"requests":{requests}}}}}"#);
            continue;
        }
        if mode == "rpc_late_id" {
            if requests == 1 {
                // Hold the first response until the renewed call arrives.
                // This exercises a late ID without a timing-dependent sleep.
                held_id = Some(id);
                continue;
            }
            if let Some(late_id) = held_id.take() {
                println!(r#"{{"id":{late_id},"result":{{"marker":"late"}}}}"#);
            }
            println!(r#"{{"id":{id},"result":{{"marker":"current","requests":{requests}}}}}"#);
            continue;
        }
        let mut error = None;
        let result = if line.contains("\"method\":\"initialize\"") {
            if mode == "timeout" {
                std::thread::sleep(Duration::from_secs(120));
            }
            "{}"
        } else if line.contains("\"method\":\"account/read\"") {
            account_reads += 1;
            match mode.as_str() {
                "no_login" => r#"{"account":null}"#,
                "api_key" => r#"{"account":{"type":"apiKey"}}"#,
                "switched" if account_reads > 1 => {
                    r#"{"account":{"type":"chatgpt","email":"new@example.com","planType":"plus"}}"#
                }
                _ => {
                    r#"{"account":{"type":"chatgpt","email":"tester@example.com","planType":"plus"}}"#
                }
            }
        } else if line.contains("\"method\":\"account/rateLimits/read\"") {
            if mode == "rate_limited" {
                error = Some(r#"{"code":-32603,"message":"429 rate limit SECRET_DO_NOT_EXPOSE"}"#);
            }
            if mode == "limits_failure" {
                error = Some(
                    r#"{"code":-32603,"message":"401 unauthorized Bearer SECRET_DO_NOT_EXPOSE"}"#,
                );
            }
            if mode == "secret_failure" {
                error = Some(r#"{"code":-32603,"message":"SECRET_DO_NOT_EXPOSE"}"#);
            }
            r#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1791981390}}}"#
        } else if line.contains("\"method\":\"account/usage/read\"") {
            if mode == "limits_only" {
                panic!("light query must never ask for tokens");
            }
            if mode == "old" {
                error = Some(r#"{"code":-32601,"message":"Unsupported method"}"#);
            }
            if mode == "secret_failure" {
                error = Some(r#"{"code":-32603,"message":"SECRET_DO_NOT_EXPOSE"}"#);
            }
            r#"{"summary":{"lifetimeTokens":1234567},"dailyUsageBuckets":[{"startDate":"2026-10-14","tokens":12345}]}"#
        } else {
            panic!("unexpected method");
        };
        println!(r#"{{"method":"account/rateLimits/updated","params":{{}}}}"#);
        if let Some(error) = error {
            println!(r#"{{"id":{id},"error":{error}}}"#);
        } else {
            println!(r#"{{"id":{id},"result":{result}}}"#);
        }
    }
}
