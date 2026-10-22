# CodexTimeZone Stage M1 candidate

0.2.4-rc.6+10 adds local-session quality and source labels plus separate 当前会话 and 独立 API 测速 entries. The API entry is a pending-work explanation; M1 makes no model request. The main window still opens on the timezone launcher, account quota remains independent, and switching measurement entries preserves the selected collector.

Only a completed turn with reconciled identities, usage and timing can contribute a verified rate. Other results explain missing, conflicting, reported-only or unsupported evidence. Whole-turn output throughput includes all logged turn time; it is not a decoder measurement. Identical replay stays idempotent, conflicting replay is visible, and a replaced log silently establishes a fresh history baseline.

Extract into a new directory. Run `Start-Trial.cmd` for the visible isolated candidate and `Stop-Trial.cmd` for explicit exit. `Start-Monitor.cmd` and `Stop-Monitor.cmd` control the same directory's background mode. Closing a selected-session collector hides the main window; it does not stop collection. Old candidates and installed binaries are preserved.

The ZIP contains runtime assets, applicable notices, source commit identity, per-file SHA256 manifest and a separate ZIP checksum. It excludes settings, credentials, session selections, fixtures, logs and debug symbols. It uses a fresh M1 Rust release build. Validation evidence and its exact counts are recorded in the source checkout's `environment/stage-m1-*` acceptance records. Native controls are explicitly injected; physical UI and notification acceptance remain `NOT_RUN`.

M2/M3 streaming benchmark and API UI work and M4 real endpoint validation have not been delivered. No installation, push, merge or publication is part of this local candidate.
