//! Standalone fake app-server for protocol/error/cleanup tests. Never uses credentials or network.
use std::{io::{self, BufRead}, time::Duration};
fn main() {
    let mode = std::env::current_exe().unwrap().file_stem().unwrap().to_string_lossy().into_owned();
    let mut account_reads = 0;
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let Some(tail) = line.split("\"id\":").nth(1) else { continue; };
        let id: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
        let mut error = None;
        let result = if line.contains("\"method\":\"initialize\"") {
            if mode == "timeout" { std::thread::sleep(Duration::from_secs(120)); }
            "{}"
        } else if line.contains("\"method\":\"account/read\"") {
            account_reads += 1;
            match mode.as_str() {
                "no_login" => r#"{"account":null}"#,
                "api_key" => r#"{"account":{"type":"apiKey"}}"#,
                "switched" if account_reads > 1 => r#"{"account":{"type":"chatgpt","email":"new@example.com","planType":"plus"}}"#,
                _ => r#"{"account":{"type":"chatgpt","email":"tester@example.com","planType":"plus"}}"#,
            }
        } else if line.contains("\"method\":\"account/rateLimits/read\"") {
            if mode == "limits_failure" { error = Some(r#"{"code":-32603,"message":"401 unauthorized Bearer SECRET_DO_NOT_EXPOSE"}"#); }
            if mode == "secret_failure" { error = Some(r#"{"code":-32603,"message":"SECRET_DO_NOT_EXPOSE"}"#); }
            r#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1791981390}}}"#
        } else if line.contains("\"method\":\"account/usage/read\"") {
            if mode == "old" { error = Some(r#"{"code":-32601,"message":"Unsupported method"}"#); }
            if mode == "secret_failure" { error = Some(r#"{"code":-32603,"message":"SECRET_DO_NOT_EXPOSE"}"#); }
            r#"{"summary":{"lifetimeTokens":1234567},"dailyUsageBuckets":[{"startDate":"2026-10-14","tokens":12345}]}"#
        } else { panic!("unexpected method"); };
        println!(r#"{{"method":"account/rateLimits/updated","params":{{}}}}"#);
        if let Some(error) = error {
            println!(r#"{{"id":{id},"error":{error}}}"#);
        } else {
            println!(r#"{{"id":{id},"result":{result}}}"#);
        }
    }
}
