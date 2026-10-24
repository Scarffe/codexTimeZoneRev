//! Pure-std synthetic fixture: no CLI, credentials, accounts, network or models.
use std::{
    env, fs,
    io::{self, BufRead, Write},
    process::{Command, Stdio},
    thread,
    time::Duration,
};

fn quote(value: &str) -> String {
    let mut result = String::from("\"");
    for character in value.chars() {
        match character {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            '\t' => result.push_str("\\t"),
            c if c < ' ' => result.push_str(&format!("\\u{:04x}", c as u32)),
            c => result.push(c),
        }
    }
    result.push('"');
    result
}
fn emit(line: &str) {
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{line}").unwrap();
    stdout.flush().unwrap();
}
fn idle() -> ! {
    loop {
        thread::sleep(Duration::from_secs(60));
    }
}
fn main() {
    let arguments: Vec<_> = env::args().collect();
    if arguments.iter().any(|a| a == "--owned-descendant") {
        idle();
    }
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut barrier = String::new();
    // No files, descendants, output or mode-specific behavior before Job attach.
    if input.read_line(&mut barrier).is_err() || barrier != "K31_OWNED_START\n" {
        return;
    }
    let mode = arguments.get(2).map(String::as_str).unwrap_or("normal");
    if mode == "startup-error" {
        std::process::exit(23);
    }
    let home = env::var("CODEX_HOME").unwrap();
    let cwd = fs::canonicalize(env::current_dir().unwrap()).unwrap();
    let provider_keys: Vec<_> = env::vars_os()
        .filter_map(|(key, _)| {
            let key = key.to_string_lossy().into_owned();
            let upper = key.to_uppercase();
            if upper.contains("KEY")
                || upper.contains("TOKEN")
                || upper.contains("PROXY")
                || upper.contains("BASE_URL")
                || upper.contains("CERT")
            {
                Some(quote(&key))
            } else {
                None
            }
        })
        .collect();
    let home_dirs_match = [
        "HOME",
        "USERPROFILE",
        "APPDATA",
        "LOCALAPPDATA",
        "TEMP",
        "TMP",
    ]
    .iter()
    .all(|key| env::var(key).ok().as_ref() == Some(&home));
    let file_store = arguments
        .windows(2)
        .any(|pair| pair[0] == "-c" && pair[1] == "cli_auth_credentials_store=\"file\"");
    fs::write(
        std::path::Path::new(&home).join("fixture-dummy.txt"),
        "synthetic fixture only",
    )
    .unwrap();
    let mut descendant = None;
    if mode == "descendant" {
        let mut command = Command::new(env::current_exe().unwrap());
        command
            .arg("--owned-descendant")
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        descendant = Some(command.spawn().unwrap());
    }
    let descendant_json = descendant
        .as_ref()
        .map(|child| format!(",\"descendant_pid\":{}", child.id()))
        .unwrap_or_default();
    emit(&format!("{{\"method\":\"fixture/ready\",\"home\":{},\"cwd\":{},\"file_store\":{},\"provider_keys\":[{}],\"home_dirs_match\":{}{}}}", quote(&home), quote(&cwd.to_string_lossy()), file_store, provider_keys.join(","), home_dirs_match, descendant_json));
    match mode {
        "crash" => std::process::exit(27),
        "silent" | "block-input" => idle(),
        "malformed" => {
            emit("{not-json}");
            idle();
        }
        "oversized" => {
            emit(&"x".repeat(65_537));
            idle();
        }
        "flood" => {
            thread::sleep(Duration::from_millis(40));
            for i in 0..1000 {
                emit(&format!("{{\"method\":\"flood\",\"n\":{i}}}"));
            }
            idle();
        }
        _ => {}
    }
    let mut line = String::new();
    while input.read_line(&mut line).unwrap_or(0) != 0 {
        // Fixed synthetic approval scenario; arbitrary routing envelopes echo.
        if line.contains("\"method\":\"approval\"") {
            emit("{\"method\":\"fixture/progress\",\"params\":{\"phase\":\"before\"}}");
            emit("{\"id\":\"approval-7\",\"method\":\"fixture/approval\",\"params\":{\"task\":\"synthetic\"}}");
        } else if line.contains("\"id\":\"approval-7\"") {
            emit("{\"method\":\"fixture/progress\",\"params\":{\"phase\":\"after\"}}");
            emit("{\"id\":7,\"result\":{\"approved\":true}}");
        } else {
            emit(line.trim_end_matches(['\r', '\n']));
        }
        line.clear();
    }
}
