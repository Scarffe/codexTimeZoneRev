//! Resolve the current Windows user's proxy settings without changing them.
//! WinHTTP evaluates PAC/WPAD; Dart owns the actual cancellable HTTP request.
use std::ffi::c_void;
use url::Url;
use windows::{
    core::{w, PCWSTR, PWSTR},
    Win32::{
        Foundation::{GlobalFree, HGLOBAL},
        Networking::WinHttp::*,
    },
};

struct Session(*mut c_void);
impl Drop for Session {
    fn drop(&mut self) {
        unsafe {
            let _ = WinHttpCloseHandle(self.0);
        }
    }
}

unsafe fn free_string(value: PWSTR) {
    if !value.is_null() {
        let _ = GlobalFree(Some(HGLOBAL(value.0.cast())));
    }
}
struct UserConfig(WINHTTP_CURRENT_USER_IE_PROXY_CONFIG);
impl Drop for UserConfig {
    fn drop(&mut self) {
        unsafe {
            free_string(self.0.lpszAutoConfigUrl);
            free_string(self.0.lpszProxy);
            free_string(self.0.lpszProxyBypass);
        }
    }
}
struct ProxyInfo(WINHTTP_PROXY_INFO);
impl Drop for ProxyInfo {
    fn drop(&mut self) {
        unsafe {
            free_string(self.0.lpszProxy);
            free_string(self.0.lpszProxyBypass);
        }
    }
}
fn string(value: PWSTR) -> Result<String, String> {
    if value.is_null() {
        Ok(String::new())
    } else {
        unsafe { value.to_string() }.map_err(|e| format!("系统代理编码无效：{e}"))
    }
}

pub fn resolve(raw: &str) -> Result<String, String> {
    let url = Url::parse(raw).map_err(|_| "代理查询 URL 无效。")?;
    if !["http", "https"].contains(&url.scheme())
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("代理查询仅支持不含认证信息的 HTTP(S) URL。".into());
    }
    let mut config = UserConfig(WINHTTP_CURRENT_USER_IE_PROXY_CONFIG::default());
    unsafe { WinHttpGetIEProxyConfigForCurrentUser(&mut config.0) }
        .map_err(|e| format!("无法读取系统代理设置：{e}"))?;
    let pac = string(config.0.lpszAutoConfigUrl)?;
    if !pac.is_empty() {
        // Explicit PAC failure is an error; never silently bypass a configured proxy.
        return resolve_auto(&url, Some(&pac), false);
    }
    if config.0.fAutoDetect.as_bool() {
        if let Ok(proxy) = resolve_auto(&url, None, true) {
            return Ok(proxy);
        }
        // WPAD commonly finds no configuration. Use the user's static settings.
    }
    static_proxy(
        &url,
        &string(config.0.lpszProxy)?,
        &string(config.0.lpszProxyBypass)?,
    )
}

fn resolve_auto(url: &Url, pac: Option<&str>, detect: bool) -> Result<String, String> {
    let session = Session(unsafe {
        WinHttpOpen(
            w!("CodexTimeZone/0.2"),
            WINHTTP_ACCESS_TYPE_NO_PROXY,
            PCWSTR::null(),
            PCWSTR::null(),
            0,
        )
    });
    if session.0.is_null() {
        return Err("无法初始化 Windows 代理解析服务。".into());
    }
    unsafe { WinHttpSetTimeouts(session.0, 8000, 8000, 8000, 8000) }
        .map_err(|e| format!("无法配置代理超时：{e}"))?;
    let pac_wide: Vec<u16> = pac
        .unwrap_or_default()
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let url_wide: Vec<u16> = url.as_str().encode_utf16().chain(Some(0)).collect();
    let mut options = WINHTTP_AUTOPROXY_OPTIONS {
        dwFlags: if detect {
            WINHTTP_AUTOPROXY_AUTO_DETECT
        } else {
            WINHTTP_AUTOPROXY_CONFIG_URL
        },
        dwAutoDetectFlags: if detect {
            WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A
        } else {
            0
        },
        lpszAutoConfigUrl: if pac.is_some() {
            PCWSTR(pac_wide.as_ptr())
        } else {
            PCWSTR::null()
        },
        // Do not transmit Windows credentials while retrieving a PAC file.
        fAutoLogonIfChallenged: false.into(),
        ..Default::default()
    };
    let mut info = ProxyInfo(WINHTTP_PROXY_INFO::default());
    unsafe {
        WinHttpGetProxyForUrl(
            session.0,
            PCWSTR(url_wide.as_ptr()),
            &mut options,
            &mut info.0,
        )
    }
    .map_err(|e| format!("系统 PAC/WPAD 解析失败：{e}"))?;
    if info.0.dwAccessType == WINHTTP_ACCESS_TYPE_NO_PROXY {
        return Ok("DIRECT".into());
    }
    static_proxy(
        url,
        &string(info.0.lpszProxy)?,
        &string(info.0.lpszProxyBypass)?,
    )
}

fn wildcard(pattern: &str, value: &str) -> bool {
    let pattern = pattern.as_bytes();
    let value = value.as_bytes();
    let (mut p, mut v, mut star, mut retry) = (0, 0, None, 0);
    while v < value.len() {
        if p < pattern.len() && (pattern[p] == b'?' || pattern[p] == value[v]) {
            p += 1;
            v += 1;
        } else if p < pattern.len() && pattern[p] == b'*' {
            star = Some(p);
            p += 1;
            retry = v;
        } else if let Some(index) = star {
            retry += 1;
            v = retry;
            p = index + 1;
        } else {
            return false;
        }
    }
    while p < pattern.len() && pattern[p] == b'*' {
        p += 1;
    }
    p == pattern.len()
}

fn bypassed(url: &Url, bypass: &str) -> bool {
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    // Match Windows/Chromium's ordinary loopback bypass without DNS resolution.
    if host == "localhost"
        || host == "[::1]"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
    {
        return true;
    }
    let authority = format!("{host}:{}", url.port_or_known_default().unwrap_or(80));
    bypass
        .split([';', ' ', ','])
        .filter(|s| !s.is_empty())
        .any(|entry| {
            let entry = entry.to_ascii_lowercase();
            if entry == "<local>" {
                return !host.contains('.') && !host.contains(':');
            }
            let pattern = if let Some((scheme, pattern)) = entry.split_once("://") {
                if scheme != url.scheme() {
                    return false;
                }
                pattern
            } else {
                &entry
            };
            wildcard(pattern, &host) || wildcard(pattern, &authority)
        })
}

fn static_proxy(url: &Url, proxy: &str, bypass: &str) -> Result<String, String> {
    if bypassed(url, bypass) || proxy.trim().is_empty() {
        return Ok("DIRECT".into());
    }
    let mut routes = Vec::new();
    let mut unsupported = false;
    for entry in proxy.split([';', ' ']).filter(|s| !s.is_empty()) {
        let endpoint = if let Some((scheme, endpoint)) = entry.split_once('=') {
            if scheme.eq_ignore_ascii_case("socks") {
                unsupported = true;
            }
            if !scheme.eq_ignore_ascii_case(url.scheme()) {
                continue;
            }
            endpoint
        } else {
            entry
        };
        if endpoint.eq_ignore_ascii_case("DIRECT") {
            routes.push("DIRECT".into());
            continue;
        }
        // Windows named proxies describe HTTP CONNECT endpoints, even for HTTPS destinations.
        let endpoint = endpoint.strip_prefix("http://").unwrap_or(endpoint);
        if endpoint.contains("://") {
            return Err("系统代理使用了暂不支持的协议。".into());
        }
        let parsed = Url::parse(&format!("http://{endpoint}")).map_err(|_| "系统代理地址无效。")?;
        if parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.path() != "/"
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            return Err("系统代理地址格式不受支持。".into());
        }
        routes.push(format!(
            "PROXY {}:{}",
            parsed.host_str().unwrap(),
            parsed.port_or_known_default().unwrap()
        ));
    }
    if routes.is_empty() && unsupported {
        return Err("系统配置了 SOCKS 代理，当前 HTTP 通道不支持此代理类型。".into());
    }
    Ok(if routes.is_empty() {
        "DIRECT".into()
    } else {
        routes.join("; ")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn static_scheme_selection_and_bypass() {
        let url = Url::parse("https://api.example.com/path").unwrap();
        assert_eq!(
            static_proxy(&url, "http=plain:8080;https=secure:8443", "").unwrap(),
            "PROXY secure:8443"
        );
        assert_eq!(
            static_proxy(&url, "proxy:8080", "*.example.com").unwrap(),
            "DIRECT"
        );
        assert_eq!(
            static_proxy(&url, "proxy:8080", "api.example.com:443").unwrap(),
            "DIRECT"
        );
        assert_eq!(
            static_proxy(&url, "proxy:8080", "http://*.example.com").unwrap(),
            "PROXY proxy:8080"
        );
        assert_eq!(
            static_proxy(
                &Url::parse("http://intranet").unwrap(),
                "proxy:80",
                "<local>"
            )
            .unwrap(),
            "DIRECT"
        );
        assert_eq!(
            static_proxy(
                &Url::parse("http://127.0.0.1:9000").unwrap(),
                "proxy:80",
                ""
            )
            .unwrap(),
            "DIRECT"
        );
        assert_eq!(
            static_proxy(&url, "first:80;second:8080", "").unwrap(),
            "PROXY first:80; PROXY second:8080"
        );
        assert!(static_proxy(&url, "socks=localhost:1080", "").is_err());
    }

    #[test]
    fn invalid_proxy_urls_are_rejected_without_os_calls() {
        for url in [
            "file:///settings",
            "not a URL",
            "https://user:password@example.com",
        ] {
            assert!(resolve(url).is_err());
        }
    }

    // Exercises real Windows PAC execution using a local server, without editing
    // the user's proxy configuration or contacting the test target.
    #[test]
    fn windows_evaluates_pac_from_local_server() {
        use std::{
            io::{Read, Write},
            net::TcpListener,
            sync::{
                atomic::{AtomicBool, Ordering},
                Arc,
            },
            time::{Duration, Instant},
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(20);
            while !stopped.load(Ordering::Relaxed) && Instant::now() < deadline {
                if let Ok((mut stream, _)) = listener.accept() {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut request = Vec::new();
                    let mut byte = [0];
                    while request.len() < 8192 && !request.ends_with(b"\r\n\r\n") {
                        if stream.read_exact(&mut byte).is_err() {
                            break;
                        }
                        request.push(byte[0]);
                    }
                    let pac = "function FindProxyForURL(url, host) { return host == 'direct.invalid' ? 'DIRECT' : 'PROXY pac.example:8123'; }";
                    let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", pac.len(), pac);
                } else {
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        });
        let pac = format!("http://{address}/proxy.pac");
        let proxied = resolve_auto(
            &Url::parse("https://proxy.invalid/").unwrap(),
            Some(&pac),
            false,
        );
        let direct = resolve_auto(
            &Url::parse("https://direct.invalid/").unwrap(),
            Some(&pac),
            false,
        );
        stop.store(true, Ordering::Relaxed);
        server.join().unwrap();
        assert_eq!(proxied.unwrap(), "PROXY pac.example:8123");
        assert_eq!(direct.unwrap(), "DIRECT");
    }
}
