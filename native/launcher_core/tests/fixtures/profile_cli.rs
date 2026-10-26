//! Synthetic CLI. Uses no credentials or network; checks explicit profile isolation.
use std::{
    io::{self, BufRead, Write},
    path::Path,
    time::Duration,
};
fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
// Fixture-only JWT encoding. Every value is synthetic; this process has no network.
fn base64url(bytes: &[u8]) -> String {
    const ABC: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let word = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for n in 0..chunk.len() + 1 {
            out.push(ABC[((word >> (18 - n * 6)) & 63) as usize] as char);
        }
    }
    out
}
fn main() {
    let mode = std::env::current_exe()
        .unwrap()
        .file_stem()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let home = std::env::var_os("CODEX_HOME").expect("explicit home required");
    // Synthetic fixture diagnostics only. No paths, parameters, credentials or
    // payloads are recorded; this also identifies pre-protocol fixture exits.
    let cwd = std::env::current_dir().unwrap();
    std::fs::write(
        Path::new(&home).join(".fixture-isolation-receipt"),
        format!(
            "cwd_raw_equal={}\ncwd_canonical_equal={}\n",
            cwd == Path::new(&home),
            std::fs::canonicalize(&cwd).ok() == std::fs::canonicalize(&home).ok(),
        ),
    )
    .unwrap();
    assert_eq!(
        std::fs::canonicalize(&cwd).unwrap(),
        std::fs::canonicalize(&home).unwrap()
    );
    let av = std::env::args().skip(1).collect::<Vec<_>>();
    let args = av.join(" ");
    assert!(args.contains("cli_auth_credentials_store=\"file\""));
    if mode == "startup_args" {
        let receipt = if args.contains("generate-json-schema") {
            ".schema-args.json"
        } else {
            ".stdio-args.json"
        };
        std::fs::write(
            Path::new(&home).parent().unwrap().join(receipt),
            format!(
                "[{}]",
                av.iter()
                    .map(|arg| json_string(arg))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
        )
        .unwrap();
    }
    for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_AUTH_TOKEN"] {
        assert!(std::env::var_os(key).is_none());
    }
    if let Some(expected) = std::env::var_os("CTZ_EXPECT_CA_CERTIFICATE") {
        assert_eq!(std::env::var_os("CODEX_CA_CERTIFICATE"), Some(expected));
    }
    if args.contains("generate-json-schema") {
        if mode == "revalidate_timeout" {
            std::fs::write(
                Path::new(&home).parent().unwrap().join(".probe-started"),
                "synthetic",
            )
            .unwrap();
            std::thread::sleep(Duration::from_secs(120));
        }
        if mode == "probe_timeout" {
            std::thread::sleep(Duration::from_secs(120));
        }
        let av = std::env::args().collect::<Vec<_>>();
        let out = Path::new(&av[av.iter().position(|s| s == "--out").unwrap() + 1]);
        std::fs::create_dir(out).unwrap();
        let methods = if mode == "missing_protocol" {
            r#"["account/read"]"#
        } else {
            r#"["config/read","account/login/start","account/login/cancel","account/read","account/rateLimits/read"]"#
        };
        std::fs::write(out.join("ClientRequest.json"), methods).unwrap();
        std::fs::write(
            out.join("ServerNotification.json"),
            r#"["account/login/completed"]"#,
        )
        .unwrap();
        return;
    }
    let mut reads = 0;
    let mut auth_reads = 0;
    let mut refresh_failure_reported = false;
    let desktop = mode.starts_with("desktop_");
    if desktop {
        std::fs::write(
            Path::new(&home).join(".desktop-child-pid"),
            std::process::id().to_string(),
        )
        .unwrap();
    }
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        for method in [
            "initialize",
            "config/read",
            "account/read",
            "getAuthStatus",
            "account/rateLimits/read",
        ] {
            if line.contains(&format!("\"method\":\"{method}\"")) {
                let mut receipt = std::fs::OpenOptions::new()
                    .append(true)
                    .open(Path::new(&home).join(".fixture-isolation-receipt"))
                    .unwrap();
                writeln!(receipt, "method:{method}").unwrap();
            }
        }
        let capability = Path::new(&home)
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with(".capability-");
        let bad_store = [
            "store_keyring",
            "store_auto",
            "store_missing",
            "store_unsupported",
        ]
        .contains(&mode.as_str())
            || (mode == "profile_keyring" && !capability);
        if bad_store
            && [
                "account/read",
                "account/rateLimits/read",
                "account/login/start",
                "getAuthStatus",
            ]
            .iter()
            .any(|m| line.contains(&format!("\"method\":\"{m}\"")))
        {
            std::fs::write(
                Path::new(&home)
                    .parent()
                    .unwrap()
                    .join(".account-rpc-reached"),
                "synthetic",
            )
            .unwrap();
            panic!("account RPC before storage isolation gate");
        }
        let Some(tail) = line.split("\"id\":").nth(1) else {
            continue;
        };
        let id: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
        if mode.starts_with("home_")
            && (line.contains("\"method\":\"config/read\"")
                || line.contains("\"method\":\"account/")
                || line.contains("\"method\":\"getAuthStatus\""))
        {
            std::fs::write(
                Path::new(&home)
                    .parent()
                    .unwrap()
                    .join(".home-gate-bypassed"),
                "synthetic",
            )
            .unwrap();
        }
        let result = if line.contains("\"method\":\"initialize\"") {
            if desktop {
                let mut receipt = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(Path::new(&home).join(".desktop-rpc-receipt"))
                    .unwrap();
                writeln!(receipt, "initialize").unwrap();
            }
            if mode == "home_missing" {
                println!(r#"{{"id":{id},"result":{{}}}}"#);
            } else if mode == "home_nonstring" {
                println!(r#"{{"id":{id},"result":{{"codexHome":true}}}}"#);
            } else {
                let reported = if mode == "home_mismatch" {
                    Path::new(&home).parent().unwrap().to_path_buf()
                } else {
                    Path::new(&home).join(".")
                };
                println!(
                    r#"{{"id":{id},"result":{{"codexHome":{}}}}}"#,
                    json_string(&reported.to_string_lossy())
                );
            }
            continue;
        } else if line.contains("\"method\":\"config/read\"") {
            assert!(line.contains("\"includeLayers\":false"));
            if mode == "store_unsupported" {
                println!(r#"{{"id":{id},"error":{{"code":-32601,"message":"SECRET"}}}}"#);
                continue;
            }
            let capability = Path::new(&home)
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".capability-");
            let store = match mode.as_str() {
                "store_keyring" => "keyring",
                "store_auto" => "auto",
                "store_missing" => "",
                "profile_keyring" if !capability => "keyring",
                _ => "file",
            };
            println!(
                r#"{{"id":{id},"result":{{"config":{{"cli_auth_credentials_store":"{store}","unrelated":"SECRET"}},"origins":{{}}}}}}"#
            );
            continue;
        } else if line.contains("\"method\":\"getAuthStatus\"") {
            auth_reads += 1;
            assert!(line.contains("\"includeToken\":true"));
            let refresh = line.contains("\"refreshToken\":true");
            if mode == "desktop_refresh_once_fail" && refresh && !refresh_failure_reported {
                refresh_failure_reported = true;
                println!(
                    r#"{{"id":{id},"error":{{"code":429,"message":"SYNTHETIC_TRANSIENT_REFRESH"}}}}"#
                );
                continue;
            }
            let mut receipt = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(Path::new(&home).join(".desktop-rpc-receipt"))
                .unwrap();
            writeln!(
                receipt,
                "auth:{}",
                if refresh { "refresh" } else { "reuse" }
            )
            .unwrap();
            drop(receipt);
            if mode == "desktop_auth_stall" {
                std::thread::sleep(Duration::from_secs(120));
            }
            if mode == "desktop_secret_error" {
                println!(
                    r#"{{"id":{id},"error":{{"code":-32000,"message":"SYNTHETIC_SECRET Bearer 401 authToken"}}}}"#
                );
                continue;
            }
            if mode == "desktop_token_null" {
                println!(r#"{{"id":{id},"result":{{"authMethod":"chatgpt","authToken":null}}}}"#);
                continue;
            }
            let principal = std::fs::read_to_string(Path::new(&home).join(".synthetic-principal"))
                .unwrap_or("A".into());
            assert!(["A", "B"].contains(&principal.as_str()));
            let claim = if mode == "desktop_principal_mismatch" && auth_reads > 1 {
                "WRONG"
            } else {
                principal.as_str()
            };
            let payload = if mode == "desktop_bad_claim" {
                "{}".into()
            } else {
                format!(
                    r#"{{"https://api.openai.com/auth":{{"chatgpt_account_id":"synthetic-account-{claim}"}},"email":"synthetic-{principal}@example.invalid"}}"#
                )
            };
            let token = format!(
                "e30.{}.synthetic-{}-{principal}",
                base64url(payload.as_bytes()),
                if refresh { "refreshed" } else { "signature" }
            );
            let method = if mode == "desktop_bad_method" {
                "apiKey"
            } else {
                "chatgpt"
            };
            println!(
                r#"{{"id":{id},"result":{{"authMethod":"{method}","authToken":{}}}}}"#,
                json_string(&token)
            );
            continue;
        } else if line.contains("\"method\":\"account/login/start\"") {
            if mode != "failure" && mode != "timeout" {
                std::fs::write(Path::new(&home).join("auth.json"), "{\"synthetic\":true}").unwrap();
            }
            if mode == "early" {
                println!(
                    r#"{{"method":"account/login/completed","params":{{"loginId":"fixture","success":true}}}}"#
                );
            }
            println!(
                r#"{{"id":{id},"result":{{"type":"chatgpt","loginId":"fixture","authUrl":"https://auth.openai.com/authorize?SECRET"}}}}"#
            );
            if mode == "timeout" {
                std::thread::sleep(Duration::from_secs(120));
            }
            println!(
                r#"{{"method":"account/login/completed","params":{{"loginId":"fixture","success":{},"error":"SECRET"}}}}"#,
                mode != "failure"
            );
            continue;
        } else if line.contains("\"method\":\"account/read\"") {
            reads += 1;
            if desktop {
                assert!(line.contains("\"refreshToken\":false"));
                let principal =
                    std::fs::read_to_string(Path::new(&home).join(".synthetic-principal"))
                        .unwrap_or("A".into());
                assert!(["A", "B"].contains(&principal.as_str()));
                let account = match mode.as_str() {
                    "desktop_missing_auth" => "null".into(),
                    "desktop_api_key" => r#"{"type":"apiKey"}"#.into(),
                    _ => format!(
                        r#"{{"type":"chatgpt","email":"synthetic-{principal}@example.invalid","planType":"plus"}}"#
                    ),
                };
                println!(r#"{{"id":{id},"result":{{"account":{account}}}}}"#);
                continue;
            }
            if Path::new(&home)
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".capability-")
                && mode != "probe_leak"
            {
                println!(r#"{{"id":{id},"result":{{"account":null}}}}"#);
                continue;
            }
            match mode.as_str() {
                "auth" => r#"{"account":null}"#,
                "switched" if reads > 1 => {
                    r#"{"account":{"type":"chatgpt","email":"other@example.com","planType":"plus"}}"#
                }
                _ => {
                    r#"{"account":{"type":"chatgpt","email":"same@example.com","planType":"plus"}}"#
                }
            }
        } else if line.contains("\"method\":\"account/rateLimits/read\"") {
            if desktop {
                if let Ok(delay) =
                    std::fs::read_to_string(Path::new(&home).join(".synthetic-quota-delay-ms"))
                {
                    let delay = delay.trim().parse::<u64>().unwrap();
                    std::fs::write(Path::new(&home).join(".desktop-quota-waiting"), "synthetic")
                        .unwrap();
                    // An official RPC can await its network response while
                    // serving a later identity/auth request on the same stream.
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(delay));
                        println!(
                            r#"{{"id":{id},"result":{{"rateLimits":{{"primary":{{"usedPercent":20}}}},"rateLimitsByLimitId":null}}}}"#
                        );
                    });
                    continue;
                }
            }
            if mode == "query_timeout" {
                std::thread::sleep(Duration::from_secs(120));
            }
            if mode == "limits_failure" {
                println!(
                    r#"{{"id":{id},"error":{{"code":429,"message":"SECRET Bearer authUrl"}}}}"#
                );
                continue;
            }
            if mode == "partial" {
                r#"{"rateLimits":null,"rateLimitsByLimitId":{"fixture":{"primary":{"usedPercent":30}}}}"#
            } else {
                r#"{"rateLimits":{"primary":{"usedPercent":20}},"rateLimitsByLimitId":null}"#
            }
        } else {
            panic!("forbidden protocol method")
        };
        println!(r#"{{"id":{id},"result":{result}}}"#);
    }
}
