use std::ffi::{CStr, CString};

#[test]
fn desktop_auth_capabilities_public_abi_reports_private_provider_with_explicit_runtime_switch() {
    let request =
        CString::new(r#"{"version":1,"command":"desktop_auth_capabilities","payload":{}}"#)
            .unwrap();
    let response = unsafe { crate::launcher_call(request.as_ptr()) };
    assert!(!response.is_null());
    let text = unsafe { CStr::from_ptr(response) }
        .to_str()
        .unwrap()
        .to_owned();
    unsafe { crate::launcher_free(response) };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["ok"], true, "capability command must be supported");
    assert_eq!(value["data"]["privateSourceAuthSupported"], true);
    assert_eq!(value["data"]["actualSwitchEnabled"], cfg!(windows));
    assert_eq!(value["data"]["desktopAttachmentImplemented"], cfg!(windows));
    assert_eq!(value["data"].as_object().unwrap().len(), 3);
}
