//! Independent API measurement. M2 admission is restricted to local replay.
mod chat;
mod collector;
mod manager;
mod metrics;
mod proxy_route;
mod sse;
mod transport;
mod types;

use serde_json::Value;
use std::sync::LazyLock;

static MANAGER: LazyLock<Result<manager::Manager, String>> = LazyLock::new(manager::Manager::new);

pub fn execute(command: &str, payload: Value) -> Result<Value, String> {
    MANAGER
        .as_ref()
        .map_err(Clone::clone)?
        .execute(command, payload)
}
