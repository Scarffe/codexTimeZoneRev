# Stage W — launcher workspace candidate

Version 0.2.4-rc.5+9. The normal window opens on 时区启动器. 监控与工具 contains quota and selected-session monitoring; switching pages retains controller and draft state. Production pet windows and role controls are paused.

Use `Start-Trial.cmd` for a visible, directory-isolated trial; `Stop-Trial.cmd` explicitly exits that same isolated instance. `Start-Monitor.cmd` retains explicit background startup. Ordinary close exits when idle, and hides while quota monitoring or a selected-session collector is active. Background-start close hides. Tray restore opens the same main window.

Fresh portable directories do not automatically query quota. An explicit saved enabled preference restores monitoring. Selected-session collection reads local files independently and can continue while hidden. No generation-speed claim is added; current measurements remain whole-turn statistics.

Quota and session notices use independent Windows notifications. Shell acceptance does not prove Windows visibly displayed a notification. Automated callback tests use explicit injection controls and do not represent physical notification clicks.

This candidate is delivered separately. It does not replace installed binaries, old packages or current Codex. The core Rust DLL is reused only after byte-for-byte hash comparison; there are no Rust behavior changes in Stage W. See the accompanying README for validation boundaries.

Source validation: full Flutter suite 135 passed; analyzer reported no issues; Windows release build passed. The isolated runtime acceptance passed 22 assertions, left zero owned processes, retained 17 original file hashes and all 21 baseline Codex process identities. Native fixture validation is 22/22 plus the historical prototype's 121 checks. Rust baseline is 41 passed, one ignored. These results do not establish physical notification presentation or physical mouse acceptance.
