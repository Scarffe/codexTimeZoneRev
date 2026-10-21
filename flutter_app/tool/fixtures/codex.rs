//! A harmless stand-in for native launcher acceptance tests, never shipped.
use std::{env, fs, thread, time::{Duration, Instant}};
fn main() {
    let root = env::current_exe().unwrap().parent().unwrap().to_path_buf();
    assert!(root.join(".test-client").is_file(), "fixture marker missing");
    let report = format!("TZ={}\nELECTRON_RUN_AS_NODE={}\nCWD={}\n",
        env::var("TZ").unwrap_or_default(),
        env::var("ELECTRON_RUN_AS_NODE").unwrap_or_else(|_| "<unset>".into()),
        env::current_dir().unwrap().display());
    fs::write(root.join("observed.txt"), report).unwrap();
    // Stay alive until the runner has actually tested duplicate rejection.
    // A bounded fallback prevents orphan fixtures after a failed runner.
    let pid=std::process::id();
    let release=root.join(format!("release-{pid}"));
    let deadline=Instant::now()+Duration::from_secs(30);
    while !release.exists() && Instant::now()<deadline { thread::sleep(Duration::from_millis(20)); }
    fs::write(root.join(format!("exited-{pid}")), b"done").unwrap();
}
