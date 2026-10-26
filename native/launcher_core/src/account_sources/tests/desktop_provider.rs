use super::*;
use crate::desktop_auth::{ManagedAccountProvider, ProviderError, RefreshMode};

fn desktop_lease(s: &Arc<Service>, id: &str) -> Result<DesktopSourceLease> {
    s.lease_for(id, Purpose::Desktop)
        .map(|inner| DesktopSourceLease { inner })
}

fn provider(
    s: &Arc<Service>,
    id: &str,
) -> std::result::Result<Arc<ManagedAccountProvider>, ProviderError> {
    let result =
        ManagedAccountProvider::from_lease(desktop_lease(s, id).unwrap(), Duration::from_secs(10));
    if result.is_err() {
        let metadata = fs::read_to_string(s.root.join(id).join(".fixture-isolation-receipt"))
            .unwrap_or_default();
        eprintln!(
            "synthetic CLI metadata: {}",
            metadata.chars().take(1000).collect::<String>()
        );
    }
    result
}

fn receipt(home: &Path) -> String {
    fs::read_to_string(home.join(".desktop-rpc-receipt")).unwrap_or_default()
}

#[test]
fn desktop_provider_quota_interrupt_budget_allows_more_than_two_seconds() {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let home = s.root.join(&id);
    fs::write(home.join(".synthetic-quota-delay-ms"), "2200").unwrap();
    let provider = provider(&s, &id).unwrap();
    let started = Instant::now();
    let usage = provider.read_quota_with_budget(false, Duration::from_secs(10));
    let elapsed = started.elapsed();
    provider.close();
    let usage = usage.unwrap();
    assert_eq!(usage["limits"]["rateLimits"]["primary"]["usedPercent"], 20);
    assert!(elapsed >= Duration::from_secs(2));
    assert_eq!(
        receipt(&home)
            .lines()
            .filter(|line| *line == "initialize")
            .count(),
        1
    );
}

fn assert_quota_preemption_by_high_priority_read(credentials: bool) {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let home = s.root.join(&id);
    fs::write(home.join(".synthetic-quota-delay-ms"), "2200").unwrap();
    let provider = provider(&s, &id).unwrap();
    let quota_provider = provider.clone();
    let worker = thread::spawn(move || {
        quota_provider.read_quota_with_budget(false, Duration::from_secs(10))
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while !home.join(".desktop-quota-waiting").exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    assert!(home.join(".desktop-quota-waiting").exists());
    let started = Instant::now();
    let high_priority = if credentials {
        provider.consume_auth_with_budget(
            RefreshMode::Refresh,
            Duration::from_millis(500),
            |_, principal| {
                assert_eq!(principal, "synthetic-account-A");
                Ok(())
            },
        )
    } else {
        provider
            .read_observation_with_budget(Duration::from_millis(500))
            .map(|observation| assert_eq!(observation.email, "synthetic-A@example.invalid"))
    };
    let elapsed = started.elapsed();
    let quota = worker.join().unwrap();
    fs::remove_file(home.join(".synthetic-quota-delay-ms")).unwrap();
    let usable_after_interrupt = provider.read_quota_with_budget(false, Duration::from_secs(10));
    let source_still_owned = s.lease_for(&id, Purpose::Task).err().unwrap().kind;
    provider.close();

    assert!(
        high_priority.is_ok(),
        "high-priority read failed: {:?}",
        high_priority.err()
    );
    assert!(
        elapsed < Duration::from_millis(500),
        "quota retained the RPC lock for {elapsed:?}"
    );
    assert_eq!(quota.err().map(ProviderError::kind), Some("cancelled"));
    assert_eq!(
        usable_after_interrupt.unwrap()["limits"]["rateLimits"]["primary"]["usedPercent"],
        20
    );
    assert_eq!(
        source_still_owned, "busy",
        "quota interruption must not cancel its source"
    );
    assert_eq!(
        receipt(&home)
            .lines()
            .filter(|line| *line == "initialize")
            .count(),
        1
    );
}

#[test]
fn desktop_provider_quota_interrupt_auth_preempts_and_provider_remains_usable() {
    assert_quota_preemption_by_high_priority_read(true);
}

#[test]
fn desktop_provider_quota_interrupt_observation_preempts_and_provider_remains_usable() {
    assert_quota_preemption_by_high_priority_read(false);
}

#[test]
fn desktop_provider_quota_interrupt_before_worker_start_is_not_reset() {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let provider = provider(&s, &id).unwrap();
    let interrupt = provider.prepare_quota();
    provider.interrupt_quota();
    let result = provider.read_quota_interruptible(false, Duration::from_secs(10), interrupt);
    let subsequent = provider.read_quota_with_budget(false, Duration::from_secs(10));
    provider.close();
    assert_eq!(result.err().map(ProviderError::kind), Some("cancelled"));
    assert_eq!(
        subsequent.unwrap()["limits"]["rateLimits"]["primary"]["usedPercent"],
        20
    );
}

#[test]
fn desktop_provider_quota_interrupt_retired_job_cannot_clear_new_registration() {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let provider = provider(&s, &id).unwrap();
    let retired = provider.prepare_quota();
    let current = provider.prepare_quota();
    let retired_result = provider.read_quota_interruptible(false, Duration::from_secs(10), retired);
    provider.interrupt_quota();
    let current_result = provider.read_quota_interruptible(false, Duration::from_secs(10), current);
    let subsequent = provider.read_quota_with_budget(false, Duration::from_secs(10));
    provider.close();
    assert_eq!(
        retired_result.err().map(ProviderError::kind),
        Some("cancelled")
    );
    assert_eq!(
        current_result.err().map(ProviderError::kind),
        Some("cancelled")
    );
    assert_eq!(
        subsequent.unwrap()["limits"]["rateLimits"]["primary"]["usedPercent"],
        20
    );
}

#[test]
fn desktop_provider_uses_distinct_principals_and_profile_homes() {
    let (_root, s) = service("desktop_auth");
    let (a, b) = (create(&s), create(&s));
    fs::write(s.root.join(&a).join(".synthetic-principal"), "A").unwrap();
    fs::write(s.root.join(&b).join(".synthetic-principal"), "B").unwrap();
    let first = provider(&s, &a).unwrap();
    let second = provider(&s, &b).unwrap();
    first
        .consume_auth(RefreshMode::Reuse, |token, principal| {
            assert_eq!(principal, "synthetic-account-A");
            assert!(token.ends_with(".synthetic-signature-A"));
            Ok(())
        })
        .unwrap();
    second
        .consume_auth(RefreshMode::Reuse, |token, principal| {
            assert_eq!(principal, "synthetic-account-B");
            assert!(token.ends_with(".synthetic-signature-B"));
            Ok(())
        })
        .unwrap();
    assert_eq!(s.lease_for(&a, Purpose::Task).err().unwrap().kind, "busy");
    assert_eq!(s.login(&a).unwrap_err().kind, "busy");
    first.close();
    assert!(desktop_lease(&s, &a).is_ok());
    assert_eq!(s.lease_for(&b, Purpose::Task).err().unwrap().kind, "busy");
    second.close();
}

#[test]
fn desktop_provider_refresh_and_monitoring_share_one_initialized_cli() {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let home = s.root.join(&id);
    let provider = provider(&s, &id).unwrap();
    provider
        .consume_auth(RefreshMode::Reuse, |_, id| {
            assert_eq!(id, "synthetic-account-A");
            Ok(())
        })
        .unwrap();
    provider
        .consume_auth(RefreshMode::Refresh, |token, _| {
            assert!(token.ends_with(".synthetic-refreshed-A"));
            Ok(())
        })
        .unwrap();
    let usage = s.usage(&id).unwrap();
    assert_eq!(usage["sourceId"], id);
    assert_eq!(
        usage["usage"]["limits"]["rateLimits"]["primary"]["usedPercent"],
        20
    );
    let observed = receipt(&home);
    assert_eq!(observed.lines().filter(|s| *s == "initialize").count(), 1);
    assert_eq!(observed.lines().filter(|s| *s == "auth:reuse").count(), 1);
    assert_eq!(observed.lines().filter(|s| *s == "auth:refresh").count(), 1);
    assert!(!usage.to_string().contains("synthetic-signature"));
    assert!(!usage.to_string().contains("authToken"));
    provider.close();
}

#[test]
fn desktop_provider_denies_non_chatgpt_missing_and_secret_bearing_failures() {
    for (mode, expected) in [
        ("desktop_api_key", "unsupported"),
        ("desktop_missing_auth", "auth_required"),
        ("desktop_token_null", "auth_required"),
        ("desktop_secret_error", "network"),
        ("desktop_bad_claim", "auth_required"),
        ("desktop_bad_method", "unsupported"),
    ] {
        let (_root, s) = service(mode);
        let id = create(&s);
        let result = match provider(&s, &id) {
            Ok(provider) => {
                let called = AtomicBool::new(false);
                let result = provider.consume_auth(RefreshMode::Reuse, |_, _| {
                    called.store(true, Ordering::SeqCst);
                    Ok(())
                });
                assert!(!called.load(Ordering::SeqCst));
                provider.close();
                result
            }
            Err(error) => Err(error),
        };
        let error = result.unwrap_err();
        assert_eq!(error.kind(), expected, "{mode}");
        assert!(!format!("{error:?}").contains("SYNTHETIC_SECRET"));
        if ["desktop_api_key", "desktop_missing_auth"].contains(&mode) {
            assert!(!receipt(&s.root.join(&id)).contains("auth:"));
        }
        assert!(desktop_lease(&s, &id).is_ok());
    }
}

#[test]
fn desktop_provider_checks_home_and_file_store_before_token_rpc() {
    for mode in [
        "store_keyring",
        "store_auto",
        "store_missing",
        "store_unsupported",
        "home_missing",
        "home_nonstring",
        "home_mismatch",
    ] {
        let (_root, s) = service(mode);
        let id = create(&s);
        assert_eq!(provider(&s, &id).err().unwrap().kind(), "isolation_failed");
        assert!(!s.root.join(".account-rpc-reached").exists());
        assert!(!s.root.join(".home-gate-bypassed").exists());
        assert!(desktop_lease(&s, &id).is_ok());
    }
}

#[test]
fn desktop_provider_cancel_prevents_late_consumer_and_holds_lease_until_cleanup() {
    let (_root, s) = service("desktop_auth_stall");
    let id = create(&s);
    let home = s.root.join(&id);
    let provider = provider(&s, &id).unwrap();
    let other = provider.clone();
    let called = Arc::new(AtomicBool::new(false));
    let observed = called.clone();
    let worker = thread::spawn(move || {
        other.consume_auth(RefreshMode::Reuse, |_, _| {
            observed.store(true, Ordering::SeqCst);
            Ok(())
        })
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while !receipt(&home).contains("auth:reuse") && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    assert!(receipt(&home).contains("auth:reuse"));
    provider.cancel();
    assert_eq!(worker.join().unwrap().unwrap_err().kind(), "cancelled");
    assert!(!called.load(Ordering::SeqCst));
    assert_eq!(s.remove(&id).unwrap_err().kind, "busy");
    assert_eq!(desktop_lease(&s, &id).err().unwrap().kind, "busy");
    let second_service =
        Service::for_test(s.root.clone(), fixture("success"), Duration::from_secs(1));
    assert_eq!(
        desktop_lease(&second_service, &id).err().unwrap().kind,
        "busy"
    );
    let pid = fs::read_to_string(home.join(".desktop-child-pid"))
        .unwrap()
        .parse::<u32>()
        .unwrap();
    provider.close();
    unsafe {
        use windows::Win32::{
            Foundation::CloseHandle,
            System::Threading::{
                GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        };
        if let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            let mut code = 0;
            GetExitCodeProcess(handle, &mut code).unwrap();
            CloseHandle(handle).unwrap();
            assert_ne!(code, 259, "source released while its CLI was still running");
        }
    }
    assert!(desktop_lease(&second_service, &id).is_ok());
}

#[test]
fn desktop_provider_survives_independent_gui_service_shutdown() {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let provider = provider(&s, &id).unwrap();
    let gui_service = Service::for_test(s.root.clone(), fixture("success"), Duration::from_secs(1));
    gui_service.shutdown().unwrap();
    assert_eq!(gui_service.usage(&id).unwrap_err().kind, "shutdown");
    provider
        .consume_auth(RefreshMode::Refresh, |_, principal| {
            assert_eq!(principal, "synthetic-account-A");
            Ok(())
        })
        .unwrap();
    provider.close();
    s.shutdown().unwrap();
}

#[test]
fn desktop_provider_pins_claim_principal_across_refresh_without_treating_email_as_account_id() {
    let (_root, s) = service("desktop_principal_mismatch");
    let id = create(&s);
    let provider = provider(&s, &id).unwrap();
    provider
        .consume_auth(RefreshMode::Reuse, |_, principal| {
            assert_eq!(principal, "synthetic-account-A");
            Ok(())
        })
        .unwrap();
    let called = AtomicBool::new(false);
    let result = provider.consume_auth(RefreshMode::Refresh, |_, _| {
        called.store(true, Ordering::SeqCst);
        Ok(())
    });
    assert_eq!(result.unwrap_err().kind(), "identity_changed");
    assert!(!called.load(Ordering::SeqCst));
    provider.close();
}

#[test]
fn desktop_provider_drop_cleans_owned_cli_before_releasing_foreign_reservation() {
    let (_root, s) = service("desktop_auth");
    let id = create(&s);
    let provider = provider(&s, &id).unwrap();
    let pid = fs::read_to_string(s.root.join(&id).join(".desktop-child-pid"))
        .unwrap()
        .parse::<u32>()
        .unwrap();
    let other = Service::for_test(s.root.clone(), fixture("success"), Duration::from_secs(1));
    assert_eq!(desktop_lease(&other, &id).err().unwrap().kind, "busy");
    drop(provider);
    let _lease = desktop_lease(&other, &id).unwrap();
    unsafe {
        use windows::Win32::{
            Foundation::CloseHandle,
            System::Threading::{
                GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        };
        if let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            let mut code = 0;
            GetExitCodeProcess(handle, &mut code).unwrap();
            CloseHandle(handle).unwrap();
            assert_ne!(
                code, 259,
                "foreign reservation became available while CLI was alive"
            );
        }
    }
}

#[test]
fn desktop_lease_rejects_current_default_unknown_and_changed_fixed_cli() {
    let (_root, s) = service("desktop_auth");
    for id in ["current", "default", "invalid"] {
        assert!(desktop_lease(&s, id).is_err());
    }
    let root = tempfile::tempdir().unwrap();
    let cli = root.path().join("desktop-fixed.exe");
    fs::copy(fixture("desktop_auth"), &cli).unwrap();
    let s = Service::for_test(
        root.path().join("account-profiles"),
        cli.clone(),
        Duration::from_secs(1),
    );
    let id = create(&s);
    let mut changed = OpenOptions::new().append(true).open(&cli).unwrap();
    changed.write_all(b"synthetic changed binding").unwrap();
    drop(changed);
    assert_eq!(desktop_lease(&s, &id).err().unwrap().kind, "unavailable");
}
