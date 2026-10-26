//! Pure-std local app-server protocol substitute. No auth, network or model use.
use std::{
    env, fs,
    io::{self, BufRead, Write},
    process::{Command, Stdio},
    thread,
    time::Duration,
};
fn quote(text: &str) -> String {
    let mut value = String::from("\"");
    for ch in text.chars() {
        match ch {
            '"' => value.push_str("\\\""),
            '\\' => value.push_str("\\\\"),
            '\n' => value.push_str("\\n"),
            '\r' => value.push_str("\\r"),
            '\t' => value.push_str("\\t"),
            ch if ch < ' ' => value.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => value.push(ch),
        }
    }
    value.push('"');
    value
}
fn emit(frame: &str) {
    let mut out = io::stdout().lock();
    writeln!(out, "{frame}").unwrap();
    out.flush().unwrap();
}
fn idle() -> ! {
    loop {
        thread::sleep(Duration::from_secs(60));
    }
}
fn id(frame: &str) -> &str {
    let value = frame.split("\"id\":").nth(1).unwrap().trim_start();
    let end = value.find([',', '}']).unwrap();
    value[..end].trim()
}
fn result(request: &str, body: &str) {
    emit(&format!("{{\"id\":{},\"result\":{body}}}", id(request)));
}
fn finished(status: &str) {
    emit(&format!("{{\"method\":\"turn/completed\",\"params\":{{\"threadId\":\"owned-thread\",\"turn\":{{\"id\":\"owned-turn\",\"items\":[],\"status\":\"{status}\"}}}}}}"));
}
fn main() {
    if env::args().any(|arg| arg == "--descendant") {
        idle();
    }
    let mode = env::var("CTZ_TASK_FIXTURE_MODE").unwrap_or_else(|_| {
        env::current_exe()
            .unwrap()
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .into_owned()
    });
    let home = env::var("CODEX_HOME").expect("explicit owned CODEX_HOME");
    let cwd = fs::canonicalize(env::current_dir().unwrap()).unwrap();
    let cwd = cwd.to_string_lossy();
    let args: Vec<_> = env::args().skip(1).collect();
    assert!(args.windows(2).any(|part| part == ["--listen", "stdio://"]));
    assert!(args.iter().any(|arg| arg == "--no-daemon"));
    assert!(args.iter().any(|arg| arg == "--strict-config"));
    assert!(args
        .windows(2)
        .any(|part| part == ["-c", "cli_auth_credentials_store=\"file\""]));
    assert!(env::var_os("OPENAI_API_KEY").is_none());
    assert_eq!(
        std::path::Path::new(&env::var("TEMP").unwrap()),
        std::path::Path::new(&home).join("tmp")
    );
    if mode == "block_input" {
        idle();
    }
    if mode == "oversized" {
        let mut out = io::stdout().lock();
        out.write_all(&vec![b'x'; 1_048_580]).unwrap();
        out.write_all(b"\n").unwrap();
        out.flush().unwrap();
        idle();
    }
    if mode == "invalid_utf8" {
        let mut out = io::stdout().lock();
        out.write_all(&[255, 10]).unwrap();
        out.flush().unwrap();
        idle();
    }
    if mode == "flood" {
        for _ in 0..10_000 {
            emit("{\"method\":\"remoteControl/status/changed\",\"params\":{}}");
        }
        idle();
    }
    if mode == "descendant" {
        let child = Command::new(env::current_exe().unwrap())
            .arg("--descendant")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        fs::write(
            std::path::Path::new(&home).join("descendant.pid"),
            child.id().to_string(),
        )
        .unwrap();
    }
    let mut approval_replies = 0;
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        if line.contains("\"method\":\"turn/start\"") {
            use std::io::Write;
            let mut log = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(std::path::Path::new(&home).join("turn-start-count.txt"))
                .unwrap();
            writeln!(log, "turn/start").unwrap();
        }
        if line.contains("\"method\":\"initialize\"") {
            if mode == "malformed" {
                emit("{not-json");
                idle();
            }
            let reported = if mode == "wrong_home" {
                cwd.as_ref()
            } else {
                &home
            };
            result(&line,&format!("{{\"codexHome\":{},\"platformFamily\":\"windows\",\"platformOs\":\"windows\",\"userAgent\":\"local-fake\"}}",quote(reported)));
            emit(
                "{\"method\":\"remoteControl/status/changed\",\"params\":{},\"emittedAtMs\":null}",
            );
        } else if line.contains("\"method\":\"initialized\"") {
        } else if line.contains("\"method\":\"configRequirements/read\"") {
            result(&line, "{\"requirements\":null}");
        } else if line.contains("\"method\":\"config/read\"") {
            let store = if mode == "missing_store" {
                "{}"
            } else {
                "{\"cli_auth_credentials_store\":\"file\"}"
            };
            result(&line, &format!("{{\"config\":{store},\"origins\":{{}}}}"));
        } else if line.contains("\"method\":\"account/read\"") {
            let account = if mode == "logged_out" {
                "null"
            } else {
                "{\"type\":\"chatgpt\",\"email\":\"synthetic@example.invalid\",\"planType\":\"plus\"}"
            };
            result(
                &line,
                &format!("{{\"account\":{account},\"requiresOpenaiAuth\":true}}"),
            );
        } else if line.contains("\"method\":\"thread/start\"") {
            let sandbox = if line.contains("workspace-write") {
                "workspaceWrite"
            } else {
                "readOnly"
            };
            result(&line,&format!("{{\"thread\":{{\"id\":\"owned-thread\"}},\"cwd\":{},\"model\":\"fixture-model\",\"modelProvider\":\"openai\",\"approvalPolicy\":\"on-request\",\"approvalsReviewer\":\"user\",\"sandbox\":{{\"type\":\"{sandbox}\",\"networkAccess\":false}}}}",quote(&cwd)));
        } else if line.contains("\"method\":\"turn/start\"") {
            if mode == "lost_start" {
                idle();
            }
            result(
                &line,
                "{\"turn\":{\"id\":\"owned-turn\",\"items\":[],\"status\":\"inProgress\"}}",
            );
            if mode == "crash" {
                std::process::exit(21);
            }
            if mode == "silent" {
                idle();
            }
            if mode == "cancel" || mode == "descendant" {
                continue;
            }
            if mode == "restricted_decisions" || mode == "write_stdin" {
                let kind = if mode == "write_stdin" {
                    "writeStdin"
                } else {
                    "command"
                };
                emit(&format!("{{\"id\":\"restricted\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{{\"threadId\":\"owned-thread\",\"turnId\":\"owned-turn\",\"itemId\":\"restricted-command\",\"startedAtMs\":1,\"command\":\"echo synthetic\",\"kind\":\"{kind}\",\"availableDecisions\":[\"decline\",\"cancel\"]}}}}"));
                continue;
            }
            if mode == "approval" || mode == "duplicate_approval" {
                emit("{\"id\":1,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"owned-thread\",\"turnId\":\"owned-turn\",\"itemId\":\"command\",\"startedAtMs\":1,\"command\":\"echo synthetic\",\"cwd\":\"synthetic\",\"reason\":\"local fixture\"}}");
                emit("{\"method\":\"item/started\",\"params\":{\"threadId\":\"owned-thread\",\"turnId\":\"owned-turn\",\"item\":{\"id\":\"patch\",\"type\":\"fileChange\",\"status\":\"inProgress\",\"changes\":[{\"path\":\"synthetic.txt\",\"kind\":{\"type\":\"update\",\"move_path\":null},\"diff\":\"-old synthetic\\n+new synthetic\"}]}}}");
                let request_id = if mode == "duplicate_approval" {
                    "1"
                } else {
                    "\"1\""
                };
                emit(&format!("{{\"id\":{request_id},\"method\":\"item/fileChange/requestApproval\",\"params\":{{\"threadId\":\"owned-thread\",\"turnId\":\"owned-turn\",\"itemId\":\"patch\",\"startedAtMs\":1,\"reason\":\"local fixture\"}}}}"));
                continue;
            }
            if mode == "input" {
                emit("{\"id\":\"question\",\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"owned-thread\",\"turnId\":\"owned-turn\",\"itemId\":\"input\",\"questions\":[{\"id\":\"choice\",\"header\":\"Choice\",\"question\":\"Choose\",\"options\":[{\"label\":\"A\",\"description\":\"Synthetic\"}]}],\"isBlocking\":true}}");
                continue;
            }
            if mode != "final_only" {
                let thread_id = if mode == "foreign_route" {
                    "foreign-thread"
                } else {
                    "owned-thread"
                };
                emit(&format!("{{\"method\":\"item/agentMessage/delta\",\"params\":{{\"threadId\":\"{thread_id}\",\"turnId\":\"owned-turn\",\"itemId\":\"answer\",\"delta\":\"Synthetic output\"}}}}"));
            }
            emit("{\"method\":\"item/completed\",\"params\":{\"threadId\":\"owned-thread\",\"turnId\":\"owned-turn\",\"item\":{\"id\":\"answer\",\"type\":\"agentMessage\",\"phase\":\"final_answer\",\"text\":\"Synthetic output\"}}}");
            finished("completed");
        } else if line.contains("\"method\":\"turn/interrupt\"") {
            result(&line, "{}");
            finished("interrupted");
        } else if line.contains("\"result\"")
            && (mode == "approval" || mode == "duplicate_approval")
        {
            approval_replies += 1;
            if approval_replies == 2 {
                finished("completed");
            }
        } else if line.contains("\"result\"") && mode == "input" {
            finished("completed");
        } else if line.contains("\"result\"") && mode == "restricted_decisions" {
            finished("completed");
        }
    }
}
