use super::*;

fn stamp(sequence: u64) -> MetadataStamp {
    MetadataStamp {
        generation: 7,
        sequence,
        observed_at_ms: 100 + sequence,
    }
}

fn end_page(planner: &mut Bootstrap, id: u64, cursor: Option<&str>, thread: &str) {
    assert!(planner
        .received(MetadataEvent::PageItem {
            id: CorrelationId(id),
            stamp: stamp(id),
            index: 0,
            thread_id: thread.to_owned(),
        })
        .is_none());
    assert!(planner
        .received(MetadataEvent::PageEnd {
            id: CorrelationId(id),
            stamp: stamp(id + 1),
            count: 1,
            next_cursor: cursor.map(str::to_owned),
        })
        .is_none());
}

fn snapshot(planner: &mut Bootstrap, id: u64, thread: &str) -> ThreadSnapshot {
    planner
        .received(MetadataEvent::ThreadSnapshot {
            id: CorrelationId(id),
            stamp: stamp(999),
            thread_id: thread.to_owned(),
            status: 2,
            attention: 1,
        })
        .expect("matching requested thread snapshot")
}

#[test]
fn bootstrap_serial_reads_capture_request_live_watermark() {
    let mut disabled = Bootstrap::new(false);
    assert_eq!(disabled.next(CorrelationId(1), 1, 0), None);

    let mut planner = Bootstrap::default();
    assert_eq!(
        planner.next(CorrelationId(1), 5, 0),
        Some(MetadataRequest::LoadedList {
            id: CorrelationId(1),
            limit: 8,
            cursor: None,
        })
    );
    assert_eq!(planner.next(CorrelationId(2), 6, 1), None);
    end_page(&mut planner, 1, None, "thread-a");
    assert_eq!(
        planner.next(CorrelationId(2), 123, 2),
        Some(MetadataRequest::ThreadRead {
            id: CorrelationId(2),
            thread_id: "thread-a".to_owned(),
            include_turns: false,
        })
    );
    assert_eq!(planner.next(CorrelationId(3), 456, 3), None);
    let observed = snapshot(&mut planner, 2, "thread-a");
    assert_eq!(observed.live_watermark, 123);
    assert_eq!(observed.stamp.sequence, 999);
    assert_eq!(planner.next(CorrelationId(3), 456, 4), None);
}

#[test]
fn bootstrap_eight_page_budget_resumes_opaque_cursor_next_cycle() {
    let mut planner = Bootstrap::new(true);
    let mut cursor: Option<String> = None;
    for page in 0..8_u64 {
        let list_id = page * 2 + 1;
        assert_eq!(
            planner.next(CorrelationId(list_id), 10, page * 10),
            Some(MetadataRequest::LoadedList {
                id: CorrelationId(list_id),
                limit: 8,
                cursor: cursor.clone(),
            })
        );
        cursor = Some(format!("opaque+cursor/{page}==:keep%2Fexact"));
        let thread = format!("thread-{page}");
        end_page(&mut planner, list_id, cursor.as_deref(), &thread);
        assert_eq!(
            planner.next(CorrelationId(list_id + 1), 20, page * 10 + 1),
            Some(MetadataRequest::ThreadRead {
                id: CorrelationId(list_id + 1),
                thread_id: thread.clone(),
                include_turns: false,
            })
        );
        let _ = snapshot(&mut planner, list_id + 1, &thread);
    }
    assert_eq!(planner.next(CorrelationId(17), 30, 29_999), None);
    assert_eq!(
        planner.next(CorrelationId(17), 30, CYCLE_INTERVAL_MS),
        Some(MetadataRequest::LoadedList {
            id: CorrelationId(17),
            limit: 8,
            cursor,
        })
    );
}

#[test]
fn bootstrap_unknown_or_timed_out_write_keeps_one_slot_until_late_terminal() {
    for delivery in [Delivery::Unknown, Delivery::Written] {
        let mut planner = Bootstrap::new(true);
        assert!(planner.next(CorrelationId(1), 5, 0).is_some());
        planner.failed(delivery);
        assert_eq!(planner.next(CorrelationId(2), 6, REQUEST_TIMEOUT_MS), None);
        assert_eq!(planner.next(CorrelationId(2), 7, 90_000), None);
        planner.received(MetadataEvent::RequestError {
            id: CorrelationId(999),
            stamp: stamp(999),
        });
        assert_eq!(planner.next(CorrelationId(2), 8, 120_000), None);
        // Only the matching terminal response clears this registration.
        planner.received(MetadataEvent::PageEnd {
            id: CorrelationId(1),
            stamp: stamp(1000),
            count: 0,
            next_cursor: None,
        });
        assert!(planner.next(CorrelationId(2), 9, 120_001).is_some());
    }
    // A missing write result also times out into late-only state, not a new ID.
    let mut planner = Bootstrap::new(true);
    assert!(planner.next(CorrelationId(10), 1, 0).is_some());
    assert_eq!(planner.next(CorrelationId(11), 2, REQUEST_TIMEOUT_MS), None);
    assert_eq!(planner.next(CorrelationId(11), 3, 300_000), None);
}

#[test]
fn bootstrap_known_not_written_or_matching_error_pauses_without_false_snapshot() {
    for fail_before_admission in [true, false] {
        let mut planner = Bootstrap::new(true);
        assert!(planner.next(CorrelationId(1), 5, 0).is_some());
        if fail_before_admission {
            planner.failed(Delivery::NotWritten);
        } else {
            assert!(planner
                .received(MetadataEvent::RequestError {
                    id: CorrelationId(999),
                    stamp: stamp(999),
                })
                .is_none());
            assert_eq!(planner.next(CorrelationId(2), 6, 1), None);
            assert!(planner
                .received(MetadataEvent::RequestError {
                    id: CorrelationId(1),
                    stamp: stamp(1000),
                })
                .is_none());
        }
        assert_eq!(planner.next(CorrelationId(2), 6, 29_999), None);
        assert_eq!(
            planner.next(CorrelationId(2), 7, CYCLE_INTERVAL_MS),
            Some(MetadataRequest::LoadedList {
                id: CorrelationId(2),
                limit: 8,
                cursor: None,
            })
        );
    }
}
