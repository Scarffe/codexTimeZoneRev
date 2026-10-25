# K3.2 read-only capability tools

These are engineering verification tools, not production task APIs. Do not use
them to attach to the running Codex, import default authentication, or launch a
model request. The app's real task and hot-switch gates remain closed.

The user authorized restoring official read-only verification after rc21.
`run-official-preflight.ps1 -EvidenceDirectory <new-existing-directory>` now runs
the bounded probe. The evidence directory must be under this checkout's
`environment/`; no historical default evidence directory is used. Before
invocation, refresh the pinned binary and exact host-policy checks below. This
is an engineering entry, not a task API or an automatic login command.

The `Get-K32ReadonlyArguments` builder returns only the fixed
arguments: `--no-daemon`, explicit file-store and disabled-analytics overrides,
then `app-server --strict-config --listen stdio://`. The former startup-config
diagnostic launch has been removed. Each invocation creates a fresh private
home and owns at most two sequential stdio children. No existing authentication
directory is accepted or imported.

Protocol failures retain their existing `reasonCode` and now include a safe
`diagnostic` projection. Its boundary distinguishes transport/UTF-8/JSON decoding,
top-level shape, notification/error/success envelopes, response id, and method
result rejection. Its fixed fields contain only JSON-kind enums
(`missing|null|object|array|string|number|boolean|unavailable`) and an unknown
top-level-key presence boolean and a fixed known-notification enum. Unknown key
names/methods, payload values, raw frames and exception text are never included.
Successful receipts have `diagnostic: null`.

Generic envelope checks and method result-shape checks are separate. An object
with optional or null nested `requirements` remains supported; outer `result:
null`, scalar results, extra envelope fields and case-colliding keys remain
rejected, now with distinguishable diagnostics. The pinned official notification
envelope supports optional `emittedAtMs` (nullable Int64); timestamp values are
never exported. The server also emits `remoteControl/status/changed` after
initialize, even when disabled. It is counted and discarded without querying or
enabling remote control. Success/error envelopes and all other notification
methods retain their existing checks. Missing/null/non-file effective
`config.cli_auth_credentials_store` still stops before any account read. An exact
`file` string in config's additional fields is accepted independently of layer
or origin metadata. These are synthetic protocol checks, not backend evidence.

Fresh official observations in
`environment/k3-2-live-readonly-20261025-a/` established independent-home matching,
successful requirements/config reads and explicit effective file storage in two
sequential children. Four `account/read(false)` responses were null, correctly
classified `auth_required`. Both children were cleaned up and no auth file was
created. The earlier envelope failure was reproduced and repaired using the
fixed-tag official notification shape. Authenticated continuity remains NOT_RUN
until a dedicated source is logged in by the user. No raw config, account,
stderr, email, token or credential content is exported.

The fake-only checks are `test-owned-stdio.ps1`,
`test-readonly-protocol.ps1`, and `test-preflight-caller.ps1`. They exercise actual
process ownership, strict method/identity projections and fail-closed caller
bookkeeping. Synthetic authenticated observations are not real-account tests.

Before official startup, refresh the pinned binary hash/signature/version/build
marker and exact
HKLM64 redirect presence/type/status, KnownFolder/default/redirected policy file
status and non-reparse ancestry, owned `.env` absence, and observation time and
generation. Invalid, unreadable or changed sources remain unverified. This tool
does not implement a policy/registry framework or treat a local policy snapshot
as runtime backend attestation. The audited exact policy inspector is retained
with the new evidence; it is run before the official probe. Real login,
authenticated continuity and model/task execution remain NOT_RUN.
