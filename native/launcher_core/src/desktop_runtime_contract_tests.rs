use serde_json::{json, Value};
use std::ffi::{CStr, CString};

fn call(payload: Value) -> Value {
    let request = CString::new(
        json!({"version":1,"command":"desktop_runtime","payload":payload}).to_string(),
    )
    .unwrap();
    let pointer = unsafe { crate::launcher_call(request.as_ptr()) };
    assert!(!pointer.is_null());
    let text = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .unwrap()
        .to_owned();
    unsafe { crate::launcher_free(pointer) };
    serde_json::from_str(&text).unwrap()
}

#[test]
fn desktop_runtime_abi_status_exposes_runtime_boundary_without_connecting() {
    let reply = call(json!({"action":"status"}));
    assert_eq!(reply["ok"], true, "desktop_runtime command must be routed");
    let data = &reply["data"];
    assert_eq!(data["runtimeVersion"], 1);
    assert!(data["supported"].is_boolean() && data["connected"].is_boolean());
    assert!(data["preparing"].is_boolean());
    assert!(data["sourceId"].is_null() || data["sourceId"].is_string());
    assert!(data["errorKind"].is_null() || data["errorKind"].is_string());
    assert!(
        data["activeSourceRetained"].is_boolean() && data["pendingSourceRetained"].is_boolean()
    );
    assert!([
        "disconnected",
        "connecting",
        "unattached",
        "awaiting_confirmation",
        "active",
        "unresolved",
        "target_exited"
    ]
    .contains(&data["phase"].as_str().unwrap()));
    assert_eq!(data["modelAttributionVerified"], false);
    assert_eq!(data["inFlightMayUsePrevious"], true);
    assert_eq!(data.as_object().unwrap().len(), 11);
}

#[test]
fn desktop_runtime_abi_switch_rejects_current_default_before_connect() {
    for source in ["current", "default"] {
        let reply = call(json!({"action":"switch","sourceId":source}));
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["data"]["errorKind"], "invalid_request");
        assert_eq!(reply["data"]["modelAttributionVerified"], false);
    }
}
