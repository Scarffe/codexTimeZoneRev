# CodexTimeZone Stage W candidate

0.2.4-rc.5+9 introduces a two-page workspace: the main page remains the timezone launcher, with quota/session tools on 监控与工具. Page switches preserve drafts, monitoring and selected-session history. Pet and role surfaces are paused in the live application.

Start `Start-Trial.cmd` for the visible isolated trial. Stop it with `Stop-Trial.cmd`. The executable also supports explicit `--desktop-monitor` background startup. Same-directory normal/background launches reuse the existing process. Closing an idle normal window exits; closing an active collector hides it. Tray restore returns to the same window and page. Explicit exit waits for settings/selection writes and query cleanup.

Fresh directories start without quota monitoring. Existing explicit saved monitoring remains enabled. Session-only collection remains independent and can run while hidden. Historical, duplicate and recovered completions remain silent. Valid completion and quota notices use Windows notifications without showing a pet or moving focus on publication. Windows can suppress presentation even when its shell accepts the request.

The candidate ZIP includes runtime assets, documentation, build identity, a per-file SHA256 manifest and an external archive checksum. It excludes account credentials, settings, session selections, test fixtures, logs and debug symbols. It is a separate local release candidate; no installed replacement, merge, push or publication is performed.

Validation evidence is retained in the source checkout under `environment/stage-w-*`. Automated native notification callbacks and CLI actions are explicitly labelled injections. Physical Windows notification visibility, physical mouse clicks and real-user GUI acceptance remain unverified. Measurement selection beyond the existing whole-turn metrics remains an open user decision.

Validation completed: 135 Flutter tests, clean analyzer, Windows release build, 22 native fixture checks and 121 historical prototype checks. An isolated runtime trial passed 22 assertions covering normal/background singleton behavior, close/restore, hidden session collection, missing-file unknown state, silent recovery/restart, notice deduplication and injected callback routing. Quota requests stayed at zero. All 17 original installed/package hashes and all 21 baseline Codex process identities were preserved; the trial left zero owned processes after normal explicit exit. The reused unchanged Rust core has a 41-pass/one-ignored baseline.
