//! Public ABI contract; deliberately exercises dispatch instead of a private collector.
use super::*;

#[test]
fn global_monitor_capabilities_are_available_without_scanning_or_auth() {
    let result =
        dispatch(r#"{"version":1,"command":"global_monitor","payload":{"action":"capabilities"}}"#);
    assert!(
        result.is_ok(),
        "global monitor command must be available: {result:?}"
    );
    let value = result.unwrap();
    assert_eq!(value["globalVersion"], 1);
    assert_eq!(value["localReadOnly"], true);
    assert_eq!(value["modelRequests"], false);
    assert_eq!(value["accountQueries"], false);
    assert_eq!(value["queryScans"], false);
}
