//! Explicit benchmark routing; proxy discovery remains outside request timing.
use std::net::IpAddr;
use url::Url;

pub fn replay_endpoint(base: &str, route: &str) -> Result<Url, String> {
    protocol_endpoint(base, route, "chat_completions")
}
pub fn protocol_endpoint(base: &str, route: &str, protocol: &str) -> Result<Url, String> {
    if route != "DIRECT" {
        return Err("invalid_proxy_route".into());
    }
    // Validate the ORIGINAL authority before URL normalization can turn numeric
    // shorthand, octal/hex IPv4 or a DNS-looking string into a loopback address.
    let (scheme, remainder) = base.split_once("://").ok_or("invalid_replay_url")?;
    if scheme != "http" && scheme != "https" {
        return Err("invalid_replay_url".into());
    }
    let authority = remainder
        .split(['/', '?', '#'])
        .next()
        .ok_or("invalid_replay_url")?;
    let host = if authority.starts_with('[') {
        let end = authority.find(']').ok_or("invalid_replay_url")?;
        let suffix = &authority[end + 1..];
        if !suffix.is_empty()
            && (!suffix.starts_with(':')
                || suffix[1..].is_empty()
                || !suffix[1..].bytes().all(|b| b.is_ascii_digit()))
        {
            return Err("invalid_replay_url".into());
        }
        &authority[1..end]
    } else {
        authority.split(':').next().ok_or("invalid_replay_url")?
    };
    let ip: IpAddr = host.parse().map_err(|_| "invalid_replay_url")?;
    if !ip.is_loopback() {
        return Err("invalid_replay_url".into());
    }
    let mut url = Url::parse(base).map_err(|_| "invalid_replay_url")?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("invalid_replay_url".into());
    }
    let path = url.path().trim_end_matches('/');
    if path.ends_with("/chat/completions") || path.ends_with("/responses") {
        return Err("duplicate_endpoint_suffix".into());
    }
    let suffix = match protocol {
        "chat_completions" => "chat/completions",
        "responses" => "responses",
        _ => return Err("unsupported_protocol".into()),
    };
    let path = format!("{path}/{suffix}");
    url.set_path(&path);
    Ok(url)
}

/// Live prefixes require TLS except for the existing original-authority literal
/// loopback policy. No DNS or proxy discovery is performed during admission.
pub(super) fn live_endpoint(base: &str, protocol: &str) -> Result<Url, String> {
    if base.is_empty()
        || base.len() > 8192
        || base
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == '\\')
    {
        return Err("invalid_live_url".into());
    }
    let mut url = Url::parse(base).map_err(|_| "invalid_live_url")?;
    if url.scheme() == "http" {
        return protocol_endpoint(base, "DIRECT", protocol).map_err(|_| "invalid_live_url".into());
    }
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("invalid_live_url".into());
    }
    let path = url.path().trim_end_matches('/');
    if path.ends_with("/chat/completions") || path.ends_with("/responses") {
        return Err("duplicate_endpoint_suffix".into());
    }
    let suffix = match protocol {
        "chat_completions" => "chat/completions",
        "responses" => "responses",
        _ => return Err("unsupported_protocol".into()),
    };
    let path = format!("{path}/{suffix}");
    url.set_path(&path);
    Ok(url)
}

/// Only the one explicitly selected HTTP CONNECT route is admitted. Never a
/// route list, credentials, inherited proxy, SOCKS route or implicit fallback.
pub(super) fn live_proxy(route: &str) -> Result<Option<Url>, String> {
    if route == "DIRECT" {
        return Ok(None);
    }
    let authority = route.strip_prefix("PROXY ").ok_or("invalid_proxy_route")?;
    if authority.is_empty()
        || authority.len() > 2048
        || authority
            .chars()
            .any(|c| c.is_control() || c.is_whitespace())
        || authority.contains(['/', '\\', '?', '#', '@', ';'])
    {
        return Err("invalid_proxy_route".into());
    }
    let (host, port) = authority.rsplit_once(':').ok_or("invalid_proxy_route")?;
    if host.is_empty()
        || port.is_empty()
        || !port.bytes().all(|b| b.is_ascii_digit())
        || port.parse::<u16>().ok().is_none_or(|port| port == 0)
    {
        return Err("invalid_proxy_route".into());
    }
    let url = Url::parse(&format!("http://{authority}")).map_err(|_| "invalid_proxy_route")?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("invalid_proxy_route".into());
    }
    Ok(Some(url))
}
