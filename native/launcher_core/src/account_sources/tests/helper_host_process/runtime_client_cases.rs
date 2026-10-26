//! Include as a child module of account_sources::tests::helper_host_process.
use super::*;
use crate::desktop_runtime_client::{Locator, RuntimeClient};

fn locator_file(path: &Path, helper: &OwnedChild, config: &HostConfig) -> Vec<u8> {
    let (_, creation, image) = process_info(helper.0.id()).unwrap();
    let locator = Locator {
        version: 1,
        helper_pid: helper.0.id(),
        helper_creation_file_time: creation,
        helper_exe: image,
        config: config.clone(),
    };
    let bytes = serde_json::to_vec(&locator).unwrap();
    fs::write(path, &bytes).unwrap();
    bytes
}

#[test]
fn desktop_runtime_client_owned_live_starting_record_is_preserved_without_new_candidate() {
    let root = tempfile::tempdir().unwrap();
    let ready = root.path().join("starting-ready");
    let stop = root.path().join("starting-stop");
    // A live process before its control server is ready. No production discovery
    // may occur merely because this registered owner has no ready pipe yet.
    let mut starting = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_target_entry")
            .env("CTZ_OWNED_TARGET_READY", &ready)
            .env("CTZ_OWNED_TARGET_STOP", &stop)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(ready.exists());
    let (_, created, _) = process_info(starting.0.id()).unwrap();
    let config = HostConfig {
        target: TargetIdentity {
            pid: starting.0.id(),
            creation_file_time: created,
        },
        control_label: "434c49454e545354415254494e47".into(),
    };
    let path = root.path().join("locator.json");
    let bytes = locator_file(&path, &starting, &config);
    let client = RuntimeClient::at(path.clone(), root.path().join("missing-other-candidate"));
    let observed = client.status();
    assert_eq!(
        observed["supported"], true,
        "a live owner must take precedence over missing local bundle files"
    );
    assert_eq!(observed["connected"], false);
    assert!(["connecting", "unresolved"].contains(&observed["phase"].as_str().unwrap()));
    let reused = client.connect();
    assert_eq!(reused["supported"], true);
    assert_eq!(reused["connected"], false);
    assert_eq!(
        fs::read(&path).unwrap(),
        bytes,
        "a transient pipe failure must not replace or erase a live locator"
    );
    assert!(starting.0.try_wait().unwrap().is_none());
    drop(client);
    assert!(starting.0.try_wait().unwrap().is_none());
    fs::write(stop, b"synthetic exit").unwrap();
    assert!(starting.0.wait().unwrap().success());
}

#[test]
fn desktop_runtime_client_owned_adopts_foreign_candidate_and_routes_only_matching_quota() {
    let (root, service) = service("desktop_auth");
    let source = create(&service);
    let ready = root.path().join("client-target-ready");
    let stop = root.path().join("client-target-stop");
    let mut target = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_target_entry")
            .env("CTZ_OWNED_TARGET_READY", &ready)
            .env("CTZ_OWNED_TARGET_STOP", &stop)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(ready.exists());
    let (_, created, _) = process_info(target.0.id()).unwrap();
    let config = HostConfig {
        target: TargetIdentity {
            pid: target.0.id(),
            creation_file_time: created,
        },
        control_label: source.trim_start_matches("profile-").into(),
    };
    let mut helper = OwnedChild(
        entry("account_sources::tests::helper_host_process::owned_helper_entry")
            .env(
                "CTZ_OWNED_HELPER_CONFIG",
                serde_json::to_string(&config).unwrap(),
            )
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut available = false;
    while Instant::now() < deadline {
        if control(&config, 1, ControlAction::Status).is_ok() {
            available = true;
            break;
        }
        if helper.0.try_wait().unwrap().is_some() {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(available);
    assert_eq!(
        control(
            &config,
            2,
            ControlAction::Switch {
                source_id: source.clone(),
                profiles_root: service.root.clone()
            }
        )
        .unwrap()["ok"],
        true
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut active = false;
    while Instant::now() < deadline {
        if control(&config, 3, ControlAction::Status).unwrap()["data"]["phase"] == "active" {
            active = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(active);
    let path = root.path().join("locator.json");
    let bytes = locator_file(&path, &helper, &config);
    let client = RuntimeClient::at(
        path.clone(),
        root.path().join("another-candidate-without-binaries"),
    );
    let observed = client.status();
    assert_eq!(observed["connected"], true);
    assert_eq!(observed["phase"], "active");
    assert_eq!(observed["sourceId"], source);
    let reused = client.connect();
    assert_eq!(reused["connected"], true);
    assert_eq!(reused["phase"], "active");
    assert_eq!(fs::read(&path).unwrap(), bytes);
    assert!(client
        .quota_for_source(&service.root, "profile-0000000000000000")
        .is_none());
    assert!(client
        .quota_for_source(&root.path().join("other-root"), &source)
        .is_none());
    let quota = client
        .quota_for_source(&service.root, &source)
        .expect("matching active source must use its helper")
        .unwrap();
    assert_eq!(quota["limits"]["rateLimits"]["primary"]["usedPercent"], 20);
    drop(client);
    assert!(helper.0.try_wait().unwrap().is_none());
    assert_eq!(
        service
            .lease_for(&source, Purpose::Task)
            .err()
            .unwrap()
            .kind,
        "busy"
    );
    fs::write(stop, b"synthetic exit").unwrap();
    assert!(target.0.wait().unwrap().success());
    let deadline = Instant::now() + Duration::from_secs(15);
    while helper.0.try_wait().unwrap().is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(helper.0.try_wait().unwrap().is_some());
    assert!(service.lease_for(&source, Purpose::Task).is_ok());
}
