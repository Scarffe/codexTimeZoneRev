//! M2 routing seam. Future proxy preparation belongs outside request timing.
use std::net::IpAddr;
use url::Url;

pub fn replay_endpoint(base: &str, route: &str) -> Result<Url, String> {
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
    if path.ends_with("/chat/completions") {
        return Err("duplicate_endpoint_suffix".into());
    }
    let path = format!("{path}/chat/completions");
    url.set_path(&path);
    Ok(url)
}
