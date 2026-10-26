//! Private finite metadata bootstrap planner. Scheduling is opt-in at the
//! transport boundary; this module cannot change authentication ownership.
use crate::runtime_helper::{CorrelationId, Delivery};
use std::collections::VecDeque;

pub(crate) const CYCLE_INTERVAL_MS: u64 = 30_000;
pub(crate) const REQUEST_TIMEOUT_MS: u64 = 5_000;
const PAGE_LIMIT: usize = 8;
const PAGE_BUDGET: u8 = 8;
const MAX_VALUE_BYTES: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct MetadataStamp {
    pub generation: u64,
    pub sequence: u64,
    pub observed_at_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum MetadataRequest {
    LoadedList {
        id: CorrelationId,
        limit: u32,
        cursor: Option<String>,
    },
    ThreadRead {
        id: CorrelationId,
        thread_id: String,
        include_turns: bool,
    },
}

pub(crate) enum MetadataEvent {
    PageItem {
        id: CorrelationId,
        stamp: MetadataStamp,
        index: u32,
        thread_id: String,
    },
    PageEnd {
        id: CorrelationId,
        stamp: MetadataStamp,
        count: u32,
        next_cursor: Option<String>,
    },
    ThreadSnapshot {
        id: CorrelationId,
        stamp: MetadataStamp,
        thread_id: String,
        status: u32,
        attention: u32,
    },
    RequestError {
        id: CorrelationId,
        stamp: MetadataStamp,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ThreadSnapshot {
    pub stamp: MetadataStamp,
    pub thread_id: String,
    pub status: u32,
    pub attention: u32,
    // Captured when thread/read was requested, never replaced with the later
    // response sequence. The live store compares its newer observations to it.
    pub live_watermark: u64,
}

struct Page {
    items: [Option<String>; PAGE_LIMIT],
    generation: Option<u64>,
    invalid: bool,
}

enum PendingKind {
    List(Page),
    Read {
        thread_id: String,
        live_watermark: u64,
    },
}

struct Pending {
    id: CorrelationId,
    started_at_ms: u64,
    late_only: bool,
    kind: PendingKind,
}

pub(crate) struct Bootstrap {
    enabled: bool,
    cycle_started_at_ms: Option<u64>,
    cycle_open: bool,
    pages: u8,
    cursor: Option<String>,
    threads: VecDeque<String>,
    pending: Option<Pending>,
}

impl Default for Bootstrap {
    fn default() -> Self {
        Self::new(true)
    }
}

impl Bootstrap {
    pub(crate) fn new(enabled: bool) -> Self {
        Self {
            enabled,
            cycle_started_at_ms: None,
            cycle_open: false,
            pages: 0,
            cursor: None,
            threads: VecDeque::new(),
            pending: None,
        }
    }

    pub(crate) fn next(
        &mut self,
        id: CorrelationId,
        live_watermark: u64,
        now_ms: u64,
    ) -> Option<MetadataRequest> {
        if !self.enabled {
            return None;
        }
        if let Some(pending) = &mut self.pending {
            if !pending.late_only
                && now_ms.saturating_sub(pending.started_at_ms) >= REQUEST_TIMEOUT_MS
            {
                // The frame registration may still own a reply. Never discard
                // it or allocate a replacement on this or later cycle ticks.
                pending.late_only = true;
            }
            return None;
        }

        // At most finish the previous cycle and start one due cycle. A late
        // matching terminal can therefore unblock a cycle already due.
        for _ in 0..2 {
            if !self.cycle_open {
                if self
                    .cycle_started_at_ms
                    .is_some_and(|started| now_ms.saturating_sub(started) < CYCLE_INTERVAL_MS)
                {
                    return None;
                }
                self.cycle_started_at_ms = Some(now_ms);
                self.cycle_open = true;
                self.pages = 0;
            }
            if let Some(thread_id) = self.threads.pop_front() {
                self.pending = Some(Pending {
                    id,
                    started_at_ms: now_ms,
                    late_only: false,
                    kind: PendingKind::Read {
                        thread_id: thread_id.clone(),
                        live_watermark,
                    },
                });
                return Some(MetadataRequest::ThreadRead {
                    id,
                    thread_id,
                    include_turns: false,
                });
            }
            if self.pages == 0 || (self.pages < PAGE_BUDGET && self.cursor.is_some()) {
                self.pending = Some(Pending {
                    id,
                    started_at_ms: now_ms,
                    late_only: false,
                    kind: PendingKind::List(Page {
                        items: std::array::from_fn(|_| None),
                        generation: None,
                        invalid: false,
                    }),
                });
                return Some(MetadataRequest::LoadedList {
                    id,
                    limit: PAGE_LIMIT as u32,
                    cursor: self.cursor.clone(),
                });
            }
            self.cycle_open = false;
        }
        None
    }

    pub(crate) fn received(&mut self, event: MetadataEvent) -> Option<ThreadSnapshot> {
        match event {
            MetadataEvent::PageItem {
                id,
                stamp,
                index,
                thread_id,
            } => {
                let Some(Pending {
                    id: expected,
                    kind: PendingKind::List(page),
                    ..
                }) = &mut self.pending
                else {
                    return None;
                };
                if id != *expected {
                    return None;
                }
                if index as usize >= PAGE_LIMIT
                    || !valid_thread_id(&thread_id)
                    || page.generation.is_some_and(|gen| gen != stamp.generation)
                {
                    page.invalid = true;
                    return None;
                }
                page.generation = Some(stamp.generation);
                let item = &mut page.items[index as usize];
                if item.as_ref().is_some_and(|old| old != &thread_id) {
                    page.invalid = true;
                } else {
                    *item = Some(thread_id);
                }
                None
            }
            MetadataEvent::PageEnd {
                id,
                stamp,
                count,
                next_cursor,
            } => {
                if !self.pending.as_ref().is_some_and(|pending| {
                    pending.id == id && matches!(pending.kind, PendingKind::List(_))
                }) {
                    return None;
                }
                let Some(Pending {
                    kind: PendingKind::List(page),
                    ..
                }) = self.pending.take()
                else {
                    return None;
                };
                let count = count as usize;
                if page.invalid
                    || count > PAGE_LIMIT
                    || page.generation.is_some_and(|gen| gen != stamp.generation)
                    || next_cursor
                        .as_ref()
                        .is_some_and(|s| s.len() > MAX_VALUE_BYTES)
                    || page.items.iter().enumerate().any(|(index, item)| {
                        if index < count {
                            item.is_none()
                        } else {
                            item.is_some()
                        }
                    })
                {
                    self.pause();
                    return None;
                }
                self.threads.extend(page.items.into_iter().flatten());
                self.cursor = next_cursor;
                self.pages += 1;
                None
            }
            MetadataEvent::ThreadSnapshot {
                id,
                stamp,
                thread_id,
                status,
                attention,
            } => {
                if !self.pending.as_ref().is_some_and(|pending| {
                    pending.id == id && matches!(pending.kind, PendingKind::Read { .. })
                }) {
                    return None;
                }
                let Some(Pending {
                    kind:
                        PendingKind::Read {
                            thread_id: expected,
                            live_watermark,
                        },
                    ..
                }) = self.pending.take()
                else {
                    return None;
                };
                if thread_id != expected
                    || !valid_thread_id(&thread_id)
                    || status > 8
                    || attention > 3
                {
                    self.pause();
                    return None;
                }
                Some(ThreadSnapshot {
                    stamp,
                    thread_id,
                    status,
                    attention,
                    live_watermark,
                })
            }
            MetadataEvent::RequestError { id, stamp: _stamp } => {
                if self
                    .pending
                    .as_ref()
                    .is_some_and(|pending| pending.id == id)
                {
                    self.pending = None;
                    self.pause();
                }
                None
            }
        }
    }

    // NotWritten is valid only after the frame layer discarded the known-not-
    // admitted request. Written/Unknown keep the sole registration until its
    // matching terminal reply or target exit/drop. Never return discard IDs.
    pub(crate) fn failed(&mut self, delivery: Delivery) {
        if self.pending.is_none() {
            return;
        }
        match delivery {
            Delivery::NotWritten => {
                self.pending = None;
                self.pause();
            }
            Delivery::Written | Delivery::Unknown => {
                if let Some(pending) = &mut self.pending {
                    pending.late_only = true;
                }
            }
        }
    }

    fn pause(&mut self) {
        // Keep already returned partial observations and the last committed
        // page cursor. Remaining bounded reads may continue next cycle.
        self.cycle_open = false;
    }
}

fn valid_thread_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_VALUE_BYTES
}

#[cfg(test)]
#[path = "runtime_bootstrap_tests.rs"]
mod tests;
