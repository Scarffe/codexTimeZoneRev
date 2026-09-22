//! A harmless stand-in for native launcher acceptance tests, never shipped.
use std::{env, fs, thread, time::Duration};
fn main() {
    let root = env::current_exe().unwrap().parent().unwrap().to_path_buf();
    assert!(root.join(".test-client").is_file(), "fixture marker missing");
    let report = format!("TZ={}\nELECTRON_RUN_AS_NODE={}\nCWD={}\n",
        env::var("TZ").unwrap_or_default(),
        env::var("ELECTRON_RUN_AS_NODE").unwrap_or_else(|_| "<unset>".into()),
        env::current_dir().unwrap().display());
    fs::write(root.join("observed.txt"), report).unwrap();
    thread::sleep(Duration::from_secs(3));
}
