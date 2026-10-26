//! Pinned app-server task protocol, shared by production and owned fake children.
use crate::owned_stdio::OwnedStdio;
use serde::{
    de::{self, MapAccess, SeqAccess, Visitor},
    Deserialize, Deserializer,
};
use serde_json::{json, Map, Value};
use std::{
    collections::VecDeque,
    fmt,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("bounded JSON without duplicate keys")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> Result<Unique, E> {
                serde_json::Number::from_f64(v)
                    .map(|v| Unique(Value::Number(v)))
                    .ok_or_else(|| E::custom("number"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_string<E: de::Error>(self, v: String) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_none<E: de::Error>(self) -> Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_unit<E: de::Error>(self) -> Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(Unique(value)) = seq.next_element()? {
                    values.push(value)
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Unique, A::Error> {
                let mut values = Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.keys().any(|prior| prior.eq_ignore_ascii_case(&key)) {
                        return Err(de::Error::custom("duplicate key"));
                    }
                    let Unique(value) = map.next_value()?;
                    values.insert(key, value);
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(V)
    }
}
pub(crate) fn parse(bytes: &[u8]) -> Result<Value, &'static str> {
    let Unique(value) = serde_json::from_slice(bytes).map_err(|_| "protocol_error")?;
    if !value.is_object() {
        return Err("protocol_error");
    }
    Ok(value)
}
pub(crate) fn identifier(value: &Value) -> Result<&str, &'static str> {
    value
        .as_str()
        .filter(|value| {
            !value.is_empty() && value.len() <= 512 && !value.chars().any(char::is_control)
        })
        .ok_or("protocol_error")
}
pub(crate) fn valid_id(value: &Value) -> bool {
    value.as_i64().is_some()
        || value
            .as_str()
            .is_some_and(|id| !id.is_empty() && id.len() <= 512)
}
pub(crate) fn known_notice(method: &str) -> bool {
    matches!(
        method,
        "remoteControl/status/changed"
            | "account/updated"
            | "account/rateLimits/updated"
            | "thread/started"
            | "thread/status/changed"
            | "turn/started"
            | "turn/completed"
            | "item/started"
            | "item/completed"
            | "item/agentMessage/delta"
            | "item/reasoning/textDelta"
            | "item/reasoning/summaryTextDelta"
            | "item/reasoning/summaryPartAdded"
            | "item/commandExecution/outputDelta"
            | "item/fileChange/outputDelta"
            | "thread/tokenUsage/updated"
            | "serverRequest/resolved"
            | "error"
            | "warning"
    )
}
pub(crate) struct Protocol {
    pub child: OwnedStdio,
    next_id: u64,
    deferred: VecDeque<Value>,
    cancel: Arc<AtomicBool>,
    source_cancel: Option<Arc<AtomicBool>>,
    interrupt_id: Option<u64>,
    identity_observed: bool,
}
impl Protocol {
    pub(crate) fn new(
        child: OwnedStdio,
        cancel: Arc<AtomicBool>,
        source_cancel: Option<Arc<AtomicBool>>,
    ) -> Self {
        Self {
            child,
            next_id: 1,
            deferred: VecDeque::new(),
            cancel,
            source_cancel,
            interrupt_id: None,
            identity_observed: false,
        }
    }
    pub(crate) fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
            || self
                .source_cancel
                .as_ref()
                .is_some_and(|cancel| cancel.load(Ordering::SeqCst))
    }
    pub(crate) fn send(&mut self, value: Value) -> Result<(), &'static str> {
        self.child.send(
            serde_json::to_vec(&value).map_err(|_| "protocol_error")?,
            Duration::from_secs(2),
        )
    }
    fn receive_wire(&mut self, budget: Duration) -> Result<Value, &'static str> {
        let frame = parse(&self.child.receive(budget)?)?;
        let object = frame.as_object().ok_or("protocol_error")?;
        if frame.get("method").is_some() {
            if !frame["method"].is_string()
                || !frame["params"].is_object()
                || object
                    .keys()
                    .any(|key| !matches!(key.as_str(), "id" | "method" | "params" | "emittedAtMs"))
            {
                return Err("protocol_error");
            }
            if let Some(id) = frame.get("id") {
                if !valid_id(id) {
                    return Err("protocol_error");
                }
            }
            if let Some(time) = frame.get("emittedAtMs") {
                if !time.is_null() && time.as_i64().is_none() {
                    return Err("protocol_error");
                }
            }
        } else {
            if !valid_id(&frame["id"])
                || object
                    .keys()
                    .any(|key| !matches!(key.as_str(), "id" | "result" | "error"))
                || frame.get("result").is_some() == frame.get("error").is_some()
            {
                return Err("protocol_error");
            }
        }
        Ok(frame)
    }
    pub(crate) fn call(&mut self, method: &str, params: Value) -> Result<Value, &'static str> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({"id":id,"method":method,"params":params}))?;
        let end = Instant::now() + Duration::from_secs(15);
        let mut count = 0;
        loop {
            if self.cancelled() {
                return Err("cancelled");
            }
            if Instant::now() >= end {
                return Err("timeout");
            }
            let frame = match self.receive_wire(Duration::from_millis(50)) {
                Err("timeout") => continue,
                result => result?,
            };
            count += 1;
            if count > 256 {
                return Err("protocol_error");
            }
            if frame.get("method").is_some() {
                if frame.get("id").is_some() {
                    return Err("unsupported_request");
                }
                let method = frame["method"].as_str().ok_or("protocol_error")?;
                if !known_notice(method) {
                    return Err("protocol_error");
                }
                if matches!(
                    method,
                    "remoteControl/status/changed" | "account/rateLimits/updated"
                ) {
                    continue;
                }
                if method == "account/updated" {
                    if self.identity_observed {
                        return Err("identity_changed");
                    }
                    continue;
                }
                if self.deferred.len() >= 64 {
                    return Err("protocol_error");
                }
                self.deferred.push_back(frame);
                continue;
            }
            if frame["id"] != id {
                return Err("protocol_error");
            }
            if let Some(error) = frame.get("error") {
                return Err(match error["code"].as_i64() {
                    Some(401) => "auth_required",
                    Some(-32601) => "unsupported",
                    _ => "protocol_error",
                });
            }
            return frame
                .get("result")
                .filter(|value| value.is_object())
                .cloned()
                .ok_or("protocol_error");
        }
    }
    pub(crate) fn handshake(
        &mut self,
        home: &Path,
        workspace: &Path,
    ) -> Result<Value, &'static str> {
        let init=self.call("initialize",json!({"clientInfo":{"name":"codex_timezone_tasks","version":env!("CARGO_PKG_VERSION")},"capabilities":null}))?;
        let reported = init["codexHome"].as_str().ok_or("isolation_failed")?;
        if std::fs::canonicalize(reported).map_err(|_| "isolation_failed")?
            != std::fs::canonicalize(home).map_err(|_| "isolation_failed")?
        {
            return Err("isolation_failed");
        }
        self.send(json!({"method":"initialized","params":{}}))?;
        let requirements = self.call("configRequirements/read", Value::Null)?;
        if let Some(requirements) = requirements
            .get("requirements")
            .filter(|value| !value.is_null())
        {
            if !requirements.is_object() {
                return Err("policy_mismatch");
            }
            if requirements
                .get("cliAuthCredentialsStore")
                .is_some_and(|store| !store.is_null() && store != "file")
            {
                return Err("isolation_failed");
            }
            if requirements
                .get("allowedApprovalPolicies")
                .is_some_and(|policies| {
                    !policies.is_null()
                        && (!policies.is_array()
                            || !policies
                                .as_array()
                                .unwrap()
                                .iter()
                                .any(|policy| policy == "on-request"))
                })
            {
                return Err("policy_mismatch");
            }
        }
        let config = self.call(
            "config/read",
            json!({"cwd":workspace,"includeLayers":false}),
        )?;
        if config["config"]["cli_auth_credentials_store"] != "file" {
            return Err("isolation_failed");
        }
        let first = self.account()?;
        let second = self.account()?;
        if first != second {
            return Err("identity_changed");
        }
        Ok(first)
    }
    pub(crate) fn account(&mut self) -> Result<Value, &'static str> {
        let result = self.call("account/read", json!({"refreshToken":false}))?;
        if !result["requiresOpenaiAuth"].is_boolean() {
            return Err("protocol_error");
        }
        if result["account"].is_null() {
            return Err("auth_required");
        }
        let account = &result["account"];
        if account["type"] != "chatgpt" {
            return Err("unsupported");
        }
        let email = identifier(&account["email"])?;
        let plan = identifier(&account["planType"])?;
        self.identity_observed = true;
        Ok(json!({"kind":"chatgpt","email":email,"plan":plan}))
    }
    pub(crate) fn next(&mut self) -> Result<Value, &'static str> {
        if let Some(frame) = self.deferred.pop_front() {
            return Ok(frame);
        }
        loop {
            let frame = self.receive_wire(Duration::from_millis(50))?;
            if frame.get("method").is_none() {
                if self.interrupt_id.is_some_and(|id| frame["id"] == id) {
                    self.interrupt_id = None;
                    continue;
                }
                return Err("protocol_error");
            }
            return Ok(frame);
        }
    }
    pub(crate) fn interrupt(&mut self, thread: &str, turn: &str) -> Result<(), &'static str> {
        if self.interrupt_id.is_none() {
            let id = self.next_id;
            self.next_id += 1;
            self.send(json!({"id":id,"method":"turn/interrupt","params":{"threadId":thread,"turnId":turn}}))?;
            self.interrupt_id = Some(id);
        }
        Ok(())
    }
}
