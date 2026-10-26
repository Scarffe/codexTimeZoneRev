//! Public ABI admission/draft tests. These never start official CLI/model work.
use codex_timezone_core::{launcher_call, launcher_free};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};

fn call(command: &str, payload: Value) -> Value {
    let input =
        CString::new(json!({"version":1,"command":command,"payload":payload}).to_string()).unwrap();
    unsafe {
        let output = launcher_call(input.as_ptr());
        assert!(!output.is_null());
        let result = serde_json::from_str(CStr::from_ptr(output).to_str().unwrap()).unwrap();
        launcher_free(output);
        result
    }
}

#[test]
fn task_catalog_is_pure_public_capability_with_honest_identity_evidence() {
    let result = call("task_catalog", json!({}));
    assert_eq!(
        result["ok"], true,
        "missing task_catalog admission: {result}"
    );
    let data = &result["data"];
    assert_eq!(data["adapterAvailable"], true);
    assert_eq!(data["officialExecutionValidated"], false);
    assert_eq!(data["strongPrincipalVerified"], false);
    assert_eq!(data["maxRunning"], 2);
    assert_eq!(data["previewSources"], json!(["preview-a", "preview-b"]));
    assert_eq!(
        call("task_catalog", json!({"executable":"not-allowed"}))["ok"],
        false
    );
}

#[test]
fn task_prepare_creates_immutable_memory_only_draft_through_existing_abi() {
    let workspace = tempfile::tempdir().unwrap();
    let result = call(
        "task_prepare",
        json!({
            "mode":"offline_preview", "sourceId":"preview-a", "workspace":workspace.path(),
            "prompt":"SYNTHETIC_MEMORY_ONLY_PROMPT", "model":"preview-model", "sandbox":"read-only"
        }),
    );
    assert_eq!(
        result["ok"], true,
        "missing task_prepare admission: {result}"
    );
    let data = &result["data"];
    assert_eq!(data["state"], "prepared");
    assert_eq!(data["mode"], "offline_preview");
    assert_eq!(data["sourceId"], "preview-a");
    assert!(data["taskId"].as_str().is_some_and(|id| !id.is_empty()));
    assert!(data["sourceEpoch"].as_u64().is_some_and(|epoch| epoch > 0));
    assert!(data["generation"]
        .as_u64()
        .is_some_and(|generation| generation > 0));
    assert!(data["threadId"].is_null());
    assert!(data["turnId"].is_null());
    assert_eq!(data["cleanupPending"], false);
    assert_eq!(data["output"], "");
    assert_eq!(data["strongPrincipalVerified"], false);
    assert!(!result.to_string().contains("SYNTHETIC_MEMORY_ONLY_PROMPT"));
    assert_eq!(std::fs::read_dir(workspace.path()).unwrap().count(), 0);
    let identity = json!({"taskId":data["taskId"],"sourceEpoch":data["sourceEpoch"],"generation":data["generation"]});
    assert_eq!(
        call("task_status", identity.clone())["data"]["state"],
        "prepared"
    );
    let mut changed = identity.clone();
    changed["prompt"] = json!("must not modify immutable draft");
    assert_eq!(call("task_start", changed)["ok"], false);
    assert_eq!(call("task_clear", identity)["ok"], true);
}
