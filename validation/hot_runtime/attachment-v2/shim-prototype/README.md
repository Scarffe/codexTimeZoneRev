# Owned self-IAT observer fixture

Source is ready for the root-owned compiler/broker. This subagent has **not compiled or run it**. Real Node/Electron equivalence, real Codex attachment, credentials, and auth acceptance are **NOT_RUN**.

Use an **x64 Native Tools Command Prompt** with Windows SDK/MSVC:

```bat
cl /nologo /std:c++17 /EHsc /W4 /O2 /DUNICODE /D_UNICODE owned_iat_observer_fixture.cpp /Fe:owned_iat_observer_fixture.exe
owned_iat_observer_fixture.exe --receipt C:\absolute\path\owned-iat-receipt.json
```

The receipt filename may be any writable absolute filename. For PowerShell, quote paths normally. Run with an outer 30-second broker timeout so any unexpected OS/compiler behavior remains bounded. Exit 0 means this finite fixture's assertions passed. Console and receipt contain only fixed field names, booleans and counts, never frames or ids.

The parent executable creates its own `--server` child. It patches only its own normal-import IAT slots for `ReadFile` and `GetOverlappedResult`; no DLL or remote-process injection exists. The child uses synthetic JSONL only and waits for two exact synthetic acknowledgments before emitting the continued/done markers. A known owned stdin writer is used; this does not test production handle discovery.

Two controlled scenarios run sequentially:

- `immediate`: synchronous named-pipe stdout reader; the child finishes its initial write and signals ready before the parent reads.
- `pending`: overlapped stdout reader submits its first read before the child is allowed to write, requires `ERROR_IO_PENDING`, then calls its original imported `GetOverlappedResult(TRUE)` after completion is signaled. The hook's single fixed pending record associates that buffer with the original completion call.

Each scenario has 7 initial JSONL frames and 2 final markers. Two direct parser checks additionally reject embedded-NUL aliases in the selected root key or method; these add no I/O frames. Only 2 valid refresh requests are accepted: numeric id 101 and a string id containing an ASCII Unicode escape. Params precede method in valid requests. The same finite stream contains a nested fake request, duplicate top-level method and duplicate top-level id, and synthetic private-value sentinels in params/result. The first read coalesces 6 frames; tiny later reads split the final request and escape sequence. The child accepts only the two expected acknowledgment shapes; the original reader compares every received byte with the entire expected 9-frame stream.

The observer queue is fixed at 16 events. An event contains only a method enum and typed id. The hook copies at most 4096 bytes per call into a fixed 4096-byte JSONL scratch line; parsing uses fixed key/id buffers, 16 top-level keys, and a nesting limit of 16. Unknown values have no semantic output. Scratch is zeroed after each complete or oversized line. No source pointer/line/params/result enters the queue, worker log, or receipt. The worker scans event storage for the synthetic sentinel but emits only a boolean outcome. Queue overflow and parser bounds increment a drop counter; they never wait for the worker. The hook performs no heap allocation, broker I/O, Sleep, mutex wait, or event wait. Extra work is bounded local parsing/hash verification, so no zero-latency claim is made.

The parent reader is the sole stdout reader. `ReadFile`/GOR wrappers call their saved originals once with unchanged arguments and restore the original LastError. Completed buffer hashes and post-original OVERLAPPED snapshots are checked around observer parsing. Reader thread identity and hook/read-submission counts are checked. The map has capacity one because this controlled reader has at most one in-flight operation; general multithreaded/libuv lifecycle coverage is NOT_RUN.

IAT changes use aligned pointer compare-and-swap under temporary `VirtualProtect`, followed by restoring and checking page protection. Shutdown disables observation and restores only slots still owned by this executable. All wrapper code remains resident in the executable: no FreeLibrary or safe-DLL-unload claim exists. Source uses `NOMINMAX` and x64 pointer-width assertions. No PEB, NativeBasic, or cross-process layout is used.

Acceptance remains intentionally narrow: this proves a self-owned Win32 API/IAT observer candidate if it passes. `CancelIoEx` followed by GOR failure/`ERROR_OPERATION_ABORTED` with partial bytes is **NOT_PROVEN**; the timeout cleanup does not constitute cancellation acceptance. General Unicode/surrogate validation, arbitrary malformed/adversarial JSON, multiple in-flight reads, Electron callsite equivalence, production channel identity, concurrent stdin writer safety, lossless overload behavior, and authentication success are **NOT_PROVEN**. The selected id/key output is conservative ASCII and rejects embedded NUL; unrelated synthetic values are skipped. A failed first run requires review of counts/booleans before expanding coverage.
