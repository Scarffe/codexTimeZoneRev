use super::*;
use std::io::Write;

static FIXTURE_LOCK: Mutex<()> = Mutex::new(());
struct FixtureGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
}
fn guarded() -> FixtureGuard {
    FixtureGuard {
        _lock: FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner()),
    }
}
impl Drop for FixtureGuard {
    fn drop(&mut self) {
        ADMISSION
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |t| {
                Some((t | 1).wrapping_add(1))
            })
            .unwrap();
        CANCELLED.store(0, Ordering::SeqCst);
    }
}

fn record(file: &mut std::fs::File, value: Value) {
    writeln!(file, "{value}").unwrap();
    file.flush().unwrap();
}
fn fixture(home: &Path, id: &str, transport: &str, child: bool) -> PathBuf {
    let directory = home.join("sessions").join("2026").join("10").join("26");
    fs::create_dir_all(&directory).unwrap();
    let path = directory.join(format!("rollout-{id}.jsonl"));
    let mut file = File::create(&path).unwrap();
    record(
        &mut file,
        json!({"type":"session_meta","payload":{"id":id,"session_id":transport,"cwd":"C:/synthetic/project","source":if child {json!({"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}})} else {json!("vscode")},"parent_thread_id":if child {json!("parent")} else {Value::Null}}}),
    );
    path
}
fn usage(thread: &str, turn: &str, response: &str, output: u64) -> Value {
    json!({"type":"token_usage_record","timestamp":"2026-10-26T00:00:10Z","payload":{"thread_id":thread,"session_id":"transport","turn_id":turn,"response_id":response,"usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":output,"reasoning_output_tokens":5,"total_tokens":100+output},"turn_token_usage":{"input_tokens":100,"output_tokens":output},"thread_token_usage":{"input_tokens":100,"output_tokens":output}}})
}
fn finish(file: &mut std::fs::File, turn: &str, error: Value) {
    record(
        file,
        json!({"type":"event_msg","timestamp":"2026-10-26T00:00:12Z","payload":{"type":"task_complete","turn_id":turn,"started_at":1792972800u64,"completed_at":1792972812u64,"duration_ms":12000,"error":error}}),
    );
}
fn catch_up(kernel: &mut Kernel, home: &Path) {
    for _ in 0..100 {
        kernel
            .scan(&json!({"action":"scan","generation":1,"roots":[home],"nowMs":1792972820000u64}))
            .unwrap();
        let value = kernel.query(&json!({"action":"query"})).unwrap();
        if value["phase"] == "ready" || value["phase"] == "partial" {
            return;
        }
    }
    panic!("bounded scans did not catch up");
}
#[test]
fn session_titles_refresh_without_rollout_growth_and_survive_cache_restore() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut rollout = fs::OpenOptions::new().append(true).open(&path).unwrap();
    record(&mut rollout, usage("thread", "turn", "response", 20));
    let mut index = File::create(home.join("session_index.jsonl")).unwrap();
    record(
        &mut index,
        json!({"id":"thread","thread_name":"Initial name","updated_at":"2026-11-03T00:00:00Z"}),
    );
    let cache = temp.path().join("cache.json");
    let mut kernel = Kernel::new(cache.clone());
    catch_up(&mut kernel, &home);
    let before = kernel.query(&json!({})).unwrap();
    assert_eq!(before["sessions"][0]["title"], "Initial name");
    let length = fs::metadata(&path).unwrap().len();
    record(
        &mut index,
        json!({"id":"thread","thread_name":"Renamed conversation","updated_at":"2026-11-04T00:00:00Z"}),
    );
    // Query remains I/O-free and uses the last scanned metadata snapshot.
    assert_eq!(
        kernel.query(&json!({"search":"Renamed"})).unwrap()["filteredCount"],
        0
    );
    catch_up(&mut kernel, &home);
    let after = kernel
        .query(&json!({"search":"RENAMED conversation"}))
        .unwrap();
    assert_eq!(after["filteredCount"], 1);
    assert_eq!(after["sessions"][0]["title"], "Renamed conversation");
    assert_eq!(after["sessions"][0]["threadId"], "thread");
    assert_eq!(after["sessions"][0]["sessionId"], "transport");
    assert_eq!(after["sessions"][0]["path"], before["sessions"][0]["path"]);
    assert_eq!(after["totals"]["tokens"], before["totals"]["tokens"]);
    assert_eq!(fs::metadata(&path).unwrap().len(), length);
    let restored = Kernel::new(cache);
    assert_eq!(
        restored.query(&json!({})).unwrap()["sessions"][0]["title"],
        "Renamed conversation"
    );
}

#[test]
fn session_titles_keep_same_name_identities_and_scope_indexes_to_each_root() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let one = temp.path().join("one");
    let two = temp.path().join("two");
    fixture(&one, "first", "transport-one", false);
    let second = fixture(&two, "second", "transport-two", false);
    let archive = two.join("archived_sessions");
    fs::create_dir_all(&archive).unwrap();
    fs::rename(second, archive.join("rollout-second.jsonl")).unwrap();
    let mut first_names = File::create(one.join("session_index.jsonl")).unwrap();
    record(
        &mut first_names,
        json!({"id":"first","thread_name":"Shared name"}),
    );
    record(
        &mut first_names,
        json!({"id":"second","thread_name":"Wrong root"}),
    );
    let mut second_names = File::create(two.join("session_index.jsonl")).unwrap();
    record(
        &mut second_names,
        json!({"id":"second","thread_name":"Shared name"}),
    );
    record(
        &mut second_names,
        json!({"id":"first","thread_name":"Wrong root"}),
    );
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    for _ in 0..3 {
        kernel
            .scan(&json!({"generation":1,"roots":[one.join("sessions"),archive]}))
            .unwrap();
    }
    let page = kernel.query(&json!({"search":"Shared name"})).unwrap();
    assert_eq!(page["filteredCount"], 2);
    assert_eq!(page["sessions"][0]["threadId"], "first");
    assert_eq!(page["sessions"][1]["threadId"], "second");
    assert_ne!(page["sessions"][0]["path"], page["sessions"][1]["path"]);
    assert_eq!(
        kernel.query(&json!({"search":"Wrong root"})).unwrap()["filteredCount"],
        0
    );
}

#[test]
fn session_titles_fall_back_to_metadata_and_accept_pre_title_caches() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "named", "transport", false);
    let mut rollout = File::create(path).unwrap();
    record(
        &mut rollout,
        json!({"type":"session_meta","payload":{"id":"named","title":"Metadata title","source":"vscode"}}),
    );
    fixture(&home, "unnamed", "transport-two", false);
    let index_path = home.join("session_index.jsonl");
    fs::write(&index_path, "not json\n{\"id\":\"named\",\"thread_name\":42}\n{\"id\":\"named\",\"thread_name\":\"   \"}\n").unwrap();
    let cache = temp.path().join("cache.json");
    let mut kernel = Kernel::new(cache.clone());
    catch_up(&mut kernel, &home);
    let page = kernel.query(&json!({})).unwrap();
    assert_eq!(page["sessions"][0]["title"], "Metadata title");
    assert!(page["sessions"][1]["title"].is_null());
    let mut disk: Value = serde_json::from_reader(File::open(&cache).unwrap()).unwrap();
    for source in disk["sources"].as_object_mut().unwrap().values_mut() {
        source.as_object_mut().unwrap().remove("title");
        source.as_object_mut().unwrap().remove("metadata_title");
        source
            .as_object_mut()
            .unwrap()
            .remove("metadata_title_read");
    }
    fs::write(&cache, serde_json::to_vec(&disk).unwrap()).unwrap();
    let mut restored = Kernel::new(cache);
    assert_eq!(restored.query(&json!({})).unwrap()["restored"], true);
    catch_up(&mut restored, &home);
    assert_eq!(
        restored.query(&json!({"search":"Metadata title"})).unwrap()["filteredCount"],
        1
    );
    fs::write(
        index_path,
        "{\"id\":\"named\",\"thread_name\":\"Current name\"}\n",
    )
    .unwrap();
    catch_up(&mut restored, &home);
    assert_eq!(
        restored.query(&json!({"search":"Current name"})).unwrap()["filteredCount"],
        1
    );
}

#[test]
fn session_titles_do_not_borrow_names_from_another_home_with_the_same_id() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let one = temp.path().join("one");
    let two = temp.path().join("two");
    fixture(&one, "same-id", "transport-one", false);
    let selected = fixture(&two, "same-id", "transport-two", false);
    let mut rollout = fs::OpenOptions::new().append(true).open(&selected).unwrap();
    record(&mut rollout, usage("same-id", "turn", "response", 20));
    fs::write(
        one.join("session_index.jsonl"),
        "{\"id\":\"same-id\",\"thread_name\":\"Other home name\"}\n",
    )
    .unwrap();
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    for _ in 0..3 {
        kernel
            .scan(&json!({"generation":1,"roots":[one,two]}))
            .unwrap();
    }
    let page = kernel.query(&json!({})).unwrap();
    assert_eq!(
        page["sessions"][0]["path"],
        json!(selected.canonicalize().unwrap())
    );
    assert_eq!(page["sessions"][0]["sessionId"], "transport-two");
    assert!(page["sessions"][0]["title"].is_null());
    assert_eq!(
        kernel.query(&json!({"search":"Other home name"})).unwrap()["filteredCount"],
        0
    );
}

#[test]
fn global_monitor_indexes_more_than_old_limits_and_does_not_scan_on_query() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    for index in 0..121 {
        fixture(&home, &format!("thread-{index:03}"), "transport", false);
    }
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    assert_eq!(kernel.query(&json!({})).unwrap()["totals"]["sessions"], 0);
    catch_up(&mut kernel, &home);
    let page = kernel.query(&json!({"limit":100})).unwrap();
    assert_eq!(page["filteredCount"], 121);
    assert_eq!(page["hasMore"], true);
    assert_eq!(
        kernel.query(&json!({"offset":100,"limit":100})).unwrap()["sessions"]
            .as_array()
            .unwrap()
            .len(),
        21
    );
}
#[test]
fn global_monitor_keeps_child_identity_and_counts_identified_usage_once() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "child", "transport", true);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    record(
        &mut file,
        json!({"type":"turn_context","payload":{"turn_id":"t","model":"model-a","cwd":"C:/synthetic/project"}}),
    );
    record(
        &mut file,
        json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}),
    );
    let own = usage("child", "t", "r1", 20);
    record(&mut file, own.clone());
    record(&mut file, own);
    record(&mut file, usage("parent", "old", "inherited", 999));
    record(
        &mut file,
        json!({"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}),
    );
    finish(&mut file, "t", Value::Null);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["totals"]["tokens"]["outputTokens"], 20);
    assert_eq!(value["models"][0]["key"], "model-a");
    assert_eq!(value["sessions"][0]["threadId"], "child");
    assert_eq!(value["sessions"][0]["sessionId"], "transport");
    assert_eq!(value["sessions"][0]["canOpenDetail"], false);
    assert_eq!(value["totals"]["attention"]["approval"], Value::Null);
}
#[test]
fn global_monitor_append_partial_truncate_archive_and_restore_do_not_double_count() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    record(&mut file, usage("thread", "t", "r1", 20));
    finish(&mut file, "t", json!({"code":"synthetic_failure"}));
    let cache = temp.path().join("cache.json");
    let mut kernel = Kernel::new(cache.clone());
    catch_up(&mut kernel, &home);
    let revision = kernel.query(&json!({})).unwrap()["revision"].clone();
    assert_eq!(
        kernel
            .query(&json!({"expectedRevision":revision.as_u64().unwrap()+1}))
            .unwrap()["changed"],
        true
    );
    let partial = usage("thread", "u", "r2", 30).to_string();
    file.write_all(partial.as_bytes()).unwrap();
    file.flush().unwrap();
    kernel
        .scan(&json!({"generation":1,"nowMs":1792972821000u64}))
        .unwrap();
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["tokens"]["outputTokens"],
        20
    );
    file.write_all(b"\n").unwrap();
    file.flush().unwrap();
    catch_up(&mut kernel, &home);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["tokens"]["outputTokens"],
        50
    );
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["states"]["failed"],
        1
    );
    drop(file);
    let archive = home.join("archived_sessions");
    fs::create_dir_all(&archive).unwrap();
    fs::copy(&path, archive.join("rollout-copy.jsonl")).unwrap();
    kernel
        .scan(&json!({"generation":1,"nowMs":1792972850000u64}))
        .unwrap();
    catch_up(&mut kernel, &home);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["tokens"]["outputTokens"],
        50
    );
    let restored = Kernel::new(cache);
    let value = restored.query(&json!({})).unwrap();
    assert_eq!(value["restored"], true);
    assert_eq!(value["totals"]["tokens"]["outputTokens"], 50);
    assert_eq!(value["totals"]["sessions"], 1);
}

fn legacy(input: u64, output: u64) -> Value {
    json!({"type":"event_msg","timestamp":"2026-10-26T00:00:10Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":input,"output_tokens":output,"total_tokens":input+output},"last_token_usage":{"input_tokens":input,"output_tokens":output,"total_tokens":input+output}}}})
}
#[test]
fn global_monitor_legacy_baselines_replays_resets_and_child_inheritance_are_explicit() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let root = fixture(&home, "root", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(root).unwrap();
    for value in [
        legacy(100, 20),
        legacy(120, 30),
        legacy(120, 30),
        legacy(5, 2),
        legacy(10, 7),
    ] {
        record(&mut file, value);
    }
    let child = fixture(&home, "child", "transport", true);
    let mut file = fs::OpenOptions::new().append(true).open(child).unwrap();
    for value in [legacy(1000, 500), legacy(1020, 510)] {
        record(&mut file, value);
    }
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["totals"]["tokens"]["outputTokens"], 35);
    assert_eq!(value["totals"]["quality"], "partial");
    let child = value["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["threadId"] == "child")
        .unwrap();
    assert_eq!(child["basis"], "none");
    assert!(child["reasons"]
        .as_array()
        .unwrap()
        .contains(&json!("ambiguous_legacy_fork")));
}
#[test]
fn global_monitor_replaces_truncated_file_and_invalidates_changed_roots() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    record(&mut file, usage("thread", "t", "r1", 50));
    drop(file);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let previous_epoch = kernel.index_epoch;
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    record(&mut file, usage("thread", "u", "r2", 10));
    drop(file);
    catch_up(&mut kernel, &home);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["tokens"]["outputTokens"],
        10
    );
    let other = temp.path().join("other");
    fixture(&other, "other-thread", "transport", false);
    catch_up(&mut kernel, &other);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["totals"]["sessions"], 1);
    assert_eq!(value["sessions"][0]["threadId"], "other-thread");
    assert!(kernel.index_epoch > previous_epoch);
}
#[test]
fn global_monitor_late_context_changes_attribution_without_recount_and_missing_stays_stale() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    record(&mut file, usage("thread", "t", "r1", 20));
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["models"][0]["key"],
        "unknown"
    );
    record(
        &mut file,
        json!({"type":"turn_context","payload":{"turn_id":"t","model":"model-after","cwd":"C:/synthetic/project"}}),
    );
    drop(file);
    catch_up(&mut kernel, &home);
    let time = reduce::timestamp(&json!("2026-10-26T00:00:10Z")).unwrap();
    let value = kernel
        .query(&json!({"dayEdgesMs":[time-1000,time+1000],"model":"model-after"}))
        .unwrap();
    assert_eq!(value["daily"][0]["tokens"]["outputTokens"], 20);
    assert_eq!(value["models"][0]["key"], "model-after");
    fs::remove_file(path).unwrap();
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["sessions"][0]["freshness"], "missing");
    assert_eq!(value["totals"]["tokens"]["outputTokens"], 20);
    assert_eq!(value["coverage"]["missing"], 1);
}
#[test]
fn global_monitor_corrupt_cache_is_not_overwritten_and_no_conversation_text_is_cached() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    record(
        &mut file,
        json!({"type":"response_item","payload":{"content":"PRIVATE_SENTINEL","arguments":"PRIVATE_SENTINEL"}}),
    );
    record(&mut file, usage("thread", "t", "r1", 20));
    let cache = temp.path().join("cache.json");
    let mut kernel = Kernel::new(cache.clone());
    catch_up(&mut kernel, &home);
    assert!(!fs::read_to_string(&cache)
        .unwrap()
        .contains("PRIVATE_SENTINEL"));
    fs::write(&cache, b"{broken cache").unwrap();
    let mut broken = Kernel::new(cache.clone());
    catch_up(&mut broken, &home);
    assert_eq!(fs::read_to_string(cache).unwrap(), "{broken cache");
    assert!(broken.query(&json!({})).unwrap()["warnings"]
        .as_array()
        .unwrap()
        .contains(&json!("cache_invalid")));
}
#[test]
fn global_monitor_old_unclosed_task_is_unknown_and_not_counted_as_active() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    record(
        &mut file,
        json!({"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"task_started","turn_id":"old"}}),
    );
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["sessions"][0]["lifecycleState"], "unknown");
    assert_eq!(value["totals"]["states"]["running"], 0);
    assert_eq!(value["totals"]["staleRunning"], 1);
    assert!(value["sessions"][0]["reasons"]
        .as_array()
        .unwrap()
        .contains(&json!("unclosed_task_stale")));
}
#[test]
fn global_monitor_replayed_response_timestamp_does_not_conflict_or_move_usage_later() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    let first = usage("thread", "t", "r1", 20);
    let mut replay = first.clone();
    replay["timestamp"] = json!("2026-10-27T00:00:10Z");
    record(&mut file, replay.clone());
    record(&mut file, first);
    drop(file);
    let archive = home.join("archived_sessions");
    fs::create_dir_all(&archive).unwrap();
    let copy = archive.join("rollout-copy.jsonl");
    fs::copy(path, &copy).unwrap();
    let mut file = fs::OpenOptions::new().append(true).open(copy).unwrap();
    replay["timestamp"] = json!("2026-10-28T00:00:10Z");
    record(&mut file, replay);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let a = reduce::timestamp(&json!("2026-10-26T00:00:00Z")).unwrap();
    let value = kernel
        .query(&json!({"dayEdgesMs":[a,a+86400000,a+172800000,a+259200000]}))
        .unwrap();
    assert_eq!(value["totals"]["tokens"]["outputTokens"], 20);
    assert_eq!(value["totals"]["excludedConflicts"], 0);
    assert_eq!(value["daily"][0]["tokens"]["outputTokens"], 20);
    assert_eq!(value["models"][0]["quality"], "reported");
}
#[test]
fn global_monitor_all_dates_provides_bounded_utc_buckets() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    record(&mut file, usage("thread", "t", "r1", 20));
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["dailyBasis"], "utc");
    let daily = value["daily"].as_array().unwrap();
    assert!(!daily.is_empty() && daily.len() <= 90);
    assert_eq!(
        daily
            .iter()
            .filter_map(|v| v["tokens"]["outputTokens"].as_u64())
            .sum::<u64>(),
        20
    );
}
#[test]
fn global_monitor_scan_queued_before_shutdown_drain_cannot_clear_barrier() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fixture(&home, "thread", "transport", false);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    let old_ticket = ADMISSION.load(Ordering::SeqCst);
    let stopping_ticket = begin_shutdown();
    let value = kernel
        .scan(&json!({"generation":1,"roots":[home]}))
        .unwrap();
    assert_eq!(
        value["cancelled"], true,
        "a queued old scan must not clear the shutdown barrier"
    );
    assert_eq!(ADMISSION.load(Ordering::SeqCst) & 1, 1);
    assert!(kernel.sources.is_empty());
    assert!(kernel.finish_shutdown(stopping_ticket));
    let old = kernel
        .scan_at(&json!({"generation":1,"roots":[home]}), old_ticket)
        .unwrap();
    assert_eq!(
        old["cancelled"], true,
        "a request captured before shutdown cannot resume after drain"
    );
    assert!(kernel.after_shutdown);
    let value = kernel
        .scan(&json!({"generation":1,"roots":[home]}))
        .unwrap();
    assert_ne!(
        value["cancelled"], true,
        "a new explicit scan after drained shutdown may resume"
    );
}
#[test]
fn global_monitor_inherited_response_cannot_refresh_child_heartbeat() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "child", "transport", true);
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    record(
        &mut file,
        json!({"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"task_started","turn_id":"old"}}),
    );
    record(
        &mut file,
        usage("parent", "parent-turn", "inherited-response", 999),
    );
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(
        value["sessions"][0]["lastEventMs"],
        reduce::timestamp(&json!("2026-01-01T00:00:00Z")).unwrap()
    );
    assert_eq!(value["totals"]["states"]["running"], 0);
    assert_eq!(value["totals"]["staleRunning"], 1);
    assert_eq!(value["totals"]["tokens"]["outputTokens"], Value::Null);
}
#[test]
fn global_monitor_scan_returns_skinny_status_without_aggregating_history() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fixture(&home, "thread", "transport", false);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    let value = kernel
        .scan(&json!({"generation":1,"roots":[home]}))
        .unwrap();
    assert!(value.get("totals").is_none());
    assert!(value.get("daily").is_none());
    assert!(value["coverage"].is_object());
    assert!(value["revision"].is_u64());
}
#[test]
fn global_monitor_noop_observation_does_not_rewrite_persistent_history() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fixture(&home, "thread", "transport", false);
    let cache = temp.path().join("cache.json");
    let mut kernel = Kernel::new(cache.clone());
    catch_up(&mut kernel, &home);
    let before = fs::read_to_string(&cache).unwrap();
    kernel
        .scan(&json!({"generation":1,"nowMs":1792972821000u64}))
        .unwrap();
    assert_eq!(fs::read_to_string(cache).unwrap(), before);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["observedAtMs"],
        1792972821000u64
    );
}
#[test]
fn global_monitor_explicit_fork_metadata_uses_inherited_counter_baseline() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "fork", "transport", false);
    let mut file = File::create(path).unwrap();
    record(
        &mut file,
        json!({"type":"session_meta","payload":{"id":"fork","session_id":"transport","source":"cli","forked_from_id":"parent","cwd":"C:/synthetic/project"}}),
    );
    record(&mut file, legacy(1000, 500));
    record(&mut file, legacy(1020, 510));
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["totals"]["tokens"]["outputTokens"], Value::Null);
    assert!(value["sessions"][0]["reasons"]
        .as_array()
        .unwrap()
        .contains(&json!("ambiguous_legacy_fork")));
    record(&mut file, usage("fork", "own-turn", "own-response", 20));
    catch_up(&mut kernel, &home);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["tokens"]["outputTokens"],
        20
    );
}

#[test]
fn global_monitor_legacy_same_millisecond_equal_deltas_survive_copy_and_restore() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    record(&mut file, legacy(100, 10));
    record(&mut file, legacy(200, 20));
    drop(file);
    let archive = home.join("archived_sessions");
    fs::create_dir_all(&archive).unwrap();
    fs::copy(path, archive.join("rollout-copy.jsonl")).unwrap();
    let cache = temp.path().join("cache.json");
    let mut kernel = Kernel::new(cache.clone());
    catch_up(&mut kernel, &home);
    assert_eq!(
        kernel.query(&json!({})).unwrap()["totals"]["tokens"]["totalTokens"],
        220
    );
    let restored = Kernel::new(cache);
    assert_eq!(
        restored.query(&json!({})).unwrap()["totals"]["tokens"]["totalTokens"],
        220
    );
}
#[test]
fn global_monitor_request_captured_while_shutdown_waits_cannot_resume_after_drain() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    fixture(&home, "thread", "transport", false);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    let first_shutdown = begin_shutdown();
    // This request arrived after shutdown published its epoch, while it waited for the lock.
    let captured_during_stopping = ADMISSION.load(Ordering::SeqCst);
    let second_shutdown = begin_shutdown();
    assert!(!kernel.finish_shutdown(first_shutdown));
    assert!(!kernel.after_shutdown);
    assert!(kernel.finish_shutdown(second_shutdown));
    let value = kernel
        .scan_at(
            &json!({"generation":1,"roots":[home]}),
            captured_during_stopping,
        )
        .unwrap();
    assert_eq!(value["cancelled"], true);
    assert!(kernel.sources.is_empty());
    let fresh_ticket = ADMISSION.load(Ordering::SeqCst);
    assert_ne!(
        kernel
            .scan_at(&json!({"generation":1,"roots":[home]}), fresh_ticket)
            .unwrap()["cancelled"],
        true
    );
    assert!(!kernel.finish_shutdown(first_shutdown));
    assert!(!kernel.after_shutdown);
    assert!(
        !cancelled(1, fresh_ticket),
        "an obsolete shutdown must not cancel the resumed generation"
    );
}
#[test]
fn global_monitor_cross_file_usage_conflict_marks_snapshot_and_every_chart_partial() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let path = fixture(&home, "thread", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    record(&mut file, usage("thread", "t", "conflict", 20));
    record(&mut file, usage("thread", "u", "known", 5));
    drop(file);
    let archive = home.join("archived_sessions");
    fs::create_dir_all(&archive).unwrap();
    let copy = archive.join("rollout-copy.jsonl");
    fs::copy(&path, &copy).unwrap();
    let mut file = File::create(copy).unwrap();
    record(
        &mut file,
        json!({"type":"session_meta","payload":{"id":"thread","session_id":"transport","source":"cli","cwd":"C:/synthetic/project"}}),
    );
    record(&mut file, usage("thread", "t", "conflict", 40));
    drop(file);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    catch_up(&mut kernel, &home);
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["totals"]["tokens"]["outputTokens"], 5);
    assert_eq!(value["phase"], "partial");
    assert_eq!(value["quality"], "partial");
    assert_eq!(value["conflicts"], 1);
    assert!(value["warnings"]
        .as_array()
        .unwrap()
        .contains(&json!("conflicting_usage")));
    for group in ["daily", "projects", "models"] {
        assert!(value[group]
            .as_array()
            .unwrap()
            .iter()
            .all(|b| b["quality"] == "partial"));
    }
}
struct EnvRestore {
    key: &'static str,
    value: Option<std::ffi::OsString>,
}
impl EnvRestore {
    fn set(key: &'static str, value: &Path) -> Self {
        let previous = std::env::var_os(key);
        std::env::set_var(key, value);
        Self {
            key,
            value: previous,
        }
    }
}
impl Drop for EnvRestore {
    fn drop(&mut self) {
        match &self.value {
            Some(v) => std::env::set_var(self.key, v),
            None => std::env::remove_var(self.key),
        }
    }
}
#[test]
fn global_monitor_default_home_changes_after_restore_but_explicit_selection_survives() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let a = temp.path().join("a");
    let b = temp.path().join("b");
    fixture(&a, "thread-a", "transport", false);
    fixture(&b, "thread-b", "transport", false);
    let _profile = EnvRestore::set("USERPROFILE", &temp.path().join("profile"));
    let _home = EnvRestore::set("CODEX_HOME", &a);
    let cache = temp.path().join("defaults.json");
    let mut kernel = Kernel::new(cache.clone());
    kernel.scan(&json!({"generation":1})).unwrap();
    assert_eq!(
        kernel.query(&json!({})).unwrap()["sessions"][0]["threadId"],
        "thread-a"
    );
    let explicit_cache = temp.path().join("explicit.json");
    let mut explicit = Kernel::new(explicit_cache.clone());
    catch_up(&mut explicit, &a);
    std::env::set_var("CODEX_HOME", &b);
    let mut restored = Kernel::new(cache);
    let old_epoch = restored.index_epoch;
    restored.scan(&json!({"generation":1})).unwrap();
    assert_eq!(
        restored.query(&json!({})).unwrap()["sessions"][0]["threadId"],
        "thread-b"
    );
    assert!(restored.index_epoch > old_epoch);
    let mut restored_explicit = Kernel::new(explicit_cache);
    restored_explicit.scan(&json!({"generation":1})).unwrap();
    let value = restored_explicit.query(&json!({})).unwrap();
    assert_eq!(value["sessions"][0]["threadId"], "thread-a");
    assert_eq!(value["sessions"][0]["canOpenDetail"], false);
}

fn fixture_modified(path: &Path, seconds: u64) {
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .set_times(
            fs::FileTimes::new().set_modified(UNIX_EPOCH + std::time::Duration::from_secs(seconds)),
        )
        .unwrap();
}

#[test]
fn global_monitor_first_bounded_scan_reads_latest_small_live_session() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    for index in 0..80 {
        let path = fixture(&home, &format!("old-{index:03}"), "transport", false);
        fixture_modified(&path, 100 + index);
    }
    let live = fixture(&home, "z-live", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&live).unwrap();
    record(
        &mut file,
        json!({"type":"event_msg","timestamp":"2026-10-26T00:00:10Z","payload":{"type":"task_started","turn_id":"live-turn"}}),
    );
    drop(file);
    fixture_modified(&live, 10_000);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    kernel
        .scan(&json!({"generation":1,"roots":[home],"nowMs":1792972820000u64}))
        .unwrap();
    let value = kernel.query(&json!({"limit":200})).unwrap();
    let live = value["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["threadId"] == "z-live");
    assert!(
        live.is_some(),
        "newest small rollout must be visible on the first bounded scan"
    );
    assert_eq!(live.unwrap()["lifecycleState"], "running");
}

#[test]
fn global_monitor_compressed_entries_do_not_consume_supported_read_slots() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let archive = home.join("archived_sessions");
    fs::create_dir_all(&archive).unwrap();
    for index in 0..40 {
        fs::write(
            archive.join(format!("rollout-old-{index:03}.jsonl.zst")),
            b"synthetic compressed placeholder",
        )
        .unwrap();
        fixture(&home, &format!("thread-{index:03}"), "transport", false);
    }
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    let first = kernel
        .scan(&json!({"generation":1,"roots":[home],"nowMs":1792972820000u64}))
        .unwrap();
    assert_eq!(first["coverage"]["indexed"], 32);
    assert_eq!(first["coverage"]["unsupported"], 40);
    kernel
        .scan(&json!({"generation":1,"nowMs":1792972821000u64}))
        .unwrap();
    assert_eq!(
        kernel.query(&json!({"limit":200})).unwrap()["filteredCount"],
        40
    );
}

#[test]
fn global_monitor_hot_priority_keeps_backlog_fair_and_bounds_one_large_file() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let large = fixture(&home, "old-000-large", "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&large).unwrap();
    let ignored =
        json!({"type":"response_item","payload":{"content":"x".repeat(2048)}}).to_string();
    for _ in 0..1536 {
        writeln!(file, "{ignored}").unwrap();
    }
    file.flush().unwrap();
    drop(file);
    fixture_modified(&large, 50);
    for index in 0..80 {
        let path = fixture(&home, &format!("old-{index:03}"), "transport", false);
        fixture_modified(&path, 100 + index);
    }
    let live = fixture(&home, "z-live", "transport", false);
    fixture_modified(&live, 10_000);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    kernel
        .scan(&json!({"generation":1,"roots":[home],"nowMs":1792972820000u64}))
        .unwrap();
    let large_key = large.canonicalize().unwrap();
    let first_offset = kernel.sources[&large_key].offset;
    assert!(
        first_offset > 0 && first_offset <= 1024 * 1024,
        "a large file must not own the whole scan byte budget"
    );
    assert!(first_offset < kernel.sources[&large_key].length);
    for index in 0..8 {
        let mut file = fs::OpenOptions::new().append(true).open(&live).unwrap();
        record(
            &mut file,
            usage("z-live", "live-turn", &format!("live-{index}"), 5),
        );
        drop(file);
        fixture_modified(&live, 10_001 + index);
        kernel
            .scan(&json!({"generation":1,"nowMs":1792972821000u64+index*1000}))
            .unwrap();
    }
    assert!(
        kernel.sources[&large_key].offset > first_offset,
        "round-robin backlog must continue despite a repeatedly hot source"
    );
    assert!(kernel.coverage()["indexed"].as_u64().unwrap() >= 80);
}

fn backlog_fixture(home: &Path, id: &str) -> (PathBuf, File) {
    let path = fixture(home, id, "transport", false);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    finish(&mut file, "old-turn", Value::Null);
    let ignored =
        json!({"type":"response_item","payload":{"content":"x".repeat(2048)}}).to_string();
    for _ in 0..1536 {
        writeln!(file, "{ignored}").unwrap();
    }
    (path, file)
}

#[test]
fn global_monitor_unindexed_tail_observes_current_lifecycle_without_counting_tail_usage() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let (_, mut file) = backlog_fixture(&home, "tail-live");
    record(
        &mut file,
        json!({"type":"event_msg","timestamp":"2026-10-26T00:00:19Z","payload":{"type":"task_started","turn_id":"new-turn"}}),
    );
    record(
        &mut file,
        usage("tail-live", "new-turn", "not-indexed-yet", 999),
    );
    drop(file);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    kernel
        .scan(&json!({"generation":1,"roots":[home],"nowMs":1792972820000u64}))
        .unwrap();
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(value["phase"], "scanning");
    assert_eq!(value["sessions"][0]["lifecycleState"], "running");
    assert_eq!(value["sessions"][0]["freshness"], "fresh");
    assert_ne!(
        value["totals"]["tokens"]["outputTokens"], 999,
        "tail state observation must not count unindexed usage"
    );
}

#[test]
fn global_monitor_unindexed_tail_does_not_report_old_completion_as_current() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let (_, mut file) = backlog_fixture(&home, "tail-unknown");
    record(
        &mut file,
        json!({"type":"response_item","payload":{"content":"x".repeat(128 * 1024)}}),
    );
    drop(file);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    kernel
        .scan(&json!({"generation":1,"roots":[home],"nowMs":1792972820000u64}))
        .unwrap();
    let value = kernel.query(&json!({})).unwrap();
    assert_eq!(
        value["sessions"][0]["lifecycleState"], "unknown",
        "the unseen backlog may contain a newer turn"
    );
}

#[test]
fn global_monitor_unindexed_tail_ignores_unfinished_completion_record() {
    let _guard = guarded();
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let (_, mut file) = backlog_fixture(&home, "tail-partial");
    record(
        &mut file,
        json!({"type":"event_msg","timestamp":"2026-10-26T00:00:19Z","payload":{"type":"task_started","turn_id":"new-turn"}}),
    );
    write!(file, "{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_complete\",\"turn_id\":\"new-turn\"}}}}").unwrap();
    file.flush().unwrap();
    drop(file);
    let mut kernel = Kernel::new(temp.path().join("cache.json"));
    kernel
        .scan(&json!({"generation":1,"roots":[home],"nowMs":1792972820000u64}))
        .unwrap();
    assert_eq!(
        kernel.query(&json!({})).unwrap()["sessions"][0]["lifecycleState"],
        "running"
    );
}
