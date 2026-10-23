# Desktop monitor M2 source candidate

M2 adds an independent Rust Chat Completions measurement kernel and process-owned asynchronous FFI jobs. Tests replay synthetic responses on literal loopback addresses. No credentials, live provider calls, current Codex control, desktop launch, installation, or M1 replacement is included.

The FFI supports start, snapshot, cancel, interrupt, clear and bounded shutdown. Strict replay routing requires explicit DIRECT and rejects DNS/external hosts, credential fields, redirects and retries. Timing uses monotonic facts and actual HTTP EOF; DONE alone cannot finish a successful run. Metric results retain count scope, quality and reasons; partial failures do not turn absent counts into zeros.

Delivery consists of source, focused/full Rust verification, a freshly built DLL used only by isolated FFI smoke, and local replay evidence. See `STAGE-M2.md` for the contract and `environment/stage-m2-*` verification receipts for check results. M3 covers UI/native lifecycle and endpoint/proxy preparation; M4 covers authorized real API acceptance. Existing M1 binaries and candidate archives remain separate.

Verification passed 89 Rust tests (one existing diagnostic ignored), the locked release build and 11 child-DLL replay checks. All 20 original artifact hashes and all 15 process identities present immediately before smoke were preserved; owned child/fixture counts ended at zero. Continuity with the older interrupted-session process baseline is unproven and recorded separately.
