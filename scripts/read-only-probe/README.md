# K3.2 read-only capability tools

These are engineering verification tools, not production task APIs. Do not use
them to attach to the running Codex, import default authentication, or launch a
model request. The app's real task and hot-switch gates remain closed.

`run-official-preflight.ps1` currently returns `blocked` with
`startup_auth_backend_unverified` before loading native helpers, touching a home,
or launching a child. There is deliberately no override flag. The same-version
startup/policy path has been audited; the actual effective-backend and identity
probe remain incomplete. This offline change preserves the prior no-start
state. The retained sequence documents the bounded read-only probe.

The dormant `Get-K32ReadonlyArguments` builder returns only the fixed future
arguments: `--no-daemon`, explicit file-store and disabled-analytics overrides,
then `app-server --strict-config --listen stdio://`. It does not start anything.
The former startup-config diagnostic launch has been removed. The public gate
still returns before evidence-path validation, helper loading or child creation.

Protocol failures retain their existing `reasonCode` and now include a safe
`diagnostic` projection. Its boundary distinguishes transport/UTF-8/JSON decoding,
top-level shape, notification/error/success envelopes, response id, and method
result rejection. Its fixed fields contain only JSON-kind enums
(`missing|null|object|array|string|number|boolean|unavailable`) and an unknown
top-level-key presence boolean. Unknown key names, values, raw frames and
exception text are never included. Successful receipts have `diagnostic: null`.

Generic envelope checks and method result-shape checks are separate. An object
with optional or null nested `requirements` remains supported; outer `result:
null`, scalar results, extra envelope fields and case-colliding keys remain
rejected, now with distinguishable diagnostics. Missing/null/non-file effective
`config.cli_auth_credentials_store` still stops before any account read. An exact
`file` string in config's additional fields is accepted independently of layer
or origin metadata. These are synthetic protocol checks, not backend evidence.

One evidence-limited official attempt matched the independent home, then stopped
at a management-requirements response with zero account reads. It did not prove
effective credential storage or authenticated continuity. Its source and safe
receipt are retained in the task's local evidence directory. No raw config,
account, stderr, email, token or credential content is exported.

The fake-only checks are `test-owned-stdio.ps1`,
`test-readonly-protocol.ps1`, and `test-preflight-caller.ps1`. They exercise actual
process ownership, strict method/identity projections and fail-closed caller
bookkeeping. Synthetic authenticated observations are not real-account tests.

Before any separately authorized future official startup, the outstanding
evidence includes the pinned binary hash/signature/version/build marker, exact
HKLM64 redirect presence/type/status, KnownFolder/default/redirected policy file
status and non-reparse ancestry, owned `.env` absence, and observation time and
generation. Invalid, unreadable or changed sources remain unverified. This tool
does not implement a policy/registry inspector or treat a local policy snapshot
as runtime backend attestation. The no-start gate remains closed; real login,
backend isolation, authenticated continuity and model/task execution are NOT_RUN.
