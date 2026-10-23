# M2: independent API measurement kernel

M2 delivers Rust protocol, measurement, HTTP job ownership and version-1 FFI source. Its executable checks use synthetic Chat Completions SSE served by literal loopback IP fixtures. It does not spend API credit, read authentication or actual sessions, start Codex, launch the desktop application, install a DLL, or replace the M1 candidate. UI integration and real endpoint preparation remain M3; real API acceptance remains M4.

## FFI lifecycle

Use `launcher_call` / `launcher_free` with the existing `{version:1,command,payload}` envelope. Every returned pointer is owned by the caller and freed exactly once. Commands return immediately except `benchmark_shutdown`, which waits at most 500 ms outside the settings and snapshot locks.

Start with `benchmark_start` and this complete required payload (port is the caller's owned local fixture):

```json
{"mode":"local_replay","protocol":"chat_completions","baseUrl":"http://127.0.0.1:PORT/v1","model":"fixture-model","prompt":"independent synthetic prompt","maxOutputTokens":256,"resolvedProxy":"DIRECT","timeoutMs":30000,"idleTimeoutMs":5000}
```

Required mode, protocol, URL, model, prompt and proxy have no implicit defaults. Optional bounds: max output 1..8192, model 1..256 bytes, prompt 1..65536 bytes, total timeout 100..120000 ms, idle timeout 50..30000 ms and no greater than total. Unknown fields, credential fields, live mode, DNS hosts, non-loopback addresses, URL credentials/query/fragment and non-DIRECT routes are rejected before network work. The transport appends one `/chat/completions` suffix, ignores environment/system proxies, sends no Authorization, follows no redirects and performs no retry/reconnection. TLS validation remains enabled by default.

Start returns a generated `runId`, `state:queued`, `measurementKind:independent_api`, and `cleanupPending:true`. The manager owns one worker, including terminal cleanup. Poll `benchmark_status` with `{runId}`. `benchmark_cancel` and `benchmark_interrupt` freeze the matching active run, signal cleanup, and return a copy; late network events cannot alter those terminal facts. `benchmark_clear` rejects active or cleaning runs. A cleared or prior run ID cannot operate on a later run. `benchmark_shutdown` requires the current run ID when present, closes admission, cancels the owned worker and reports whether cleanup finished within its 500 ms budget. It never waits while holding `REQUEST_LOCK` or the snapshot lock.

## Measurement scope

Status contains separate monotonic nanosecond facts for first/last content, first/last visible text, usage, DONE and actual HTTP EOF. Role-only/control/heartbeat frames do not establish first content. `[DONE]` does not establish HTTP EOF; successful completion waits for real body EOF. Response model identity comes from the response, requested model from the validated start request. No request prompt, raw URL, response body or provider error text is retained in snapshots/errors.

Each metric includes value (or null), unit, quality, reasons, numerator, denominator and count source. Missing counts stay missing; SSE blocks and characters are not tokens. Output includes reasoning as a subset. Reported zero and one-token complete responses retain whole-request E2E rates, while insufficient intervals make stream/ITL rates unavailable. Hidden reasoning can invalidate visible-stream rates while retaining a scoped reported whole-request rate.

The pinned AIPerf rules are attributed separately. Project TTFO excludes tool arguments, and project whole-request E2E ends at HTTP EOF. These are deliberate scope differences from the upstream tool-text TTFO and last-content E2E boundaries. No claim of running the full upstream framework is made.

## Verification and artifacts

`native/launcher_core/tests/benchmark_jobs.rs` exercises the real public C ABI with self-owned literal-loopback fixtures. `scripts/test-benchmark-m2.ps1` loads the exact fresh test DLL in a child PowerShell process and frees every returned buffer. Compiler, focused/full Rust tests, release build and DLL receipt logs use new `environment/stage-m2-*` paths. Pre-existing `environment/m2-before-*` process/file/ZIP baselines are never overwritten. Final counts, hashes and remaining limitations are recorded in the task report and release receipt.

This stage does not establish real provider interoperability, latency accuracy on paid endpoints, Flutter UI lifecycle acceptance, Windows suspend/resume integration, or a complete user-facing API benchmark feature.

The recovered integration verification passed 89 Rust tests with one existing installed-MSIX diagnostic ignored, the locked release build, and all 11 fresh-DLL child replay checks. Evidence is `environment/stage-m2-rust-full-recovery.log`, `stage-m2-release-recovery.log`, and `stage-m2-ffi-recovery.json`. The smoke preserved all 15 current monitored process identities (path and UTC start ticks) and all 20 original file hashes (18 ZIPs and two root binaries); owned fixture tasks and client processes ended at zero. The original interrupted-session 21-process baseline had already become stale before smoke (19 absent, two PIDs reused), so its continuity is explicitly unproven in the separate preservation receipt. Original baselines remain intact.
