# K3.2 read-only capability tools

These are engineering verification tools, not production task APIs. Do not use
them to attach to the running Codex, import default authentication, or launch a
model request. The app's real task and hot-switch gates remain closed.

`run-official-preflight.ps1` currently returns `blocked` with
`startup_auth_backend_unverified` before loading native helpers, touching a home,
or launching a child. There is deliberately no override flag. The retained
sequence documents the bounded read-only probe, but cannot be enabled until
the pinned Windows CLI's pre-auth requirements precedence and backend selection
have independent evidence. A post-start config RPC alone is not that evidence.

One evidence-limited official attempt matched the independent home, then stopped
at a management-requirements response with zero account reads. It did not prove
effective credential storage or authenticated continuity. Its source and safe
receipt are retained in the task's local evidence directory. No raw config,
account, stderr, email, token or credential content is exported.

The fake-only checks are `test-owned-stdio.ps1`,
`test-readonly-protocol.ps1`, and `test-preflight-caller.ps1`. They exercise actual
process ownership, strict method/identity projections and fail-closed caller
bookkeeping. Synthetic authenticated observations are not real-account tests.
