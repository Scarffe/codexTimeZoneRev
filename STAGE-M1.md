# Stage M1 — local session quality and two measurement entries

Version 0.2.4-rc.6+10. The timezone launcher remains the default page. In 监控与工具, 当前会话 reads only the selected local Codex log; 独立 API 测速 explains the pending M2/M3 work. M1 contains no API request, credential form or benchmark start action. The pet remains paused.

Local results show their source and evidence quality. Only verified completed turns publish a numeric verified rate. Reported-only values remain explicitly labelled in details. Output includes reasoning when the supported schema establishes that relationship; reasoning is never added twice. The denominator is the complete logged turn, including waiting, tools and other activity. This is not a server decoding-speed measurement. Verified aggregation uses total output divided by total duration within compatible session/model/effort/service groups.

Repeated records are idempotent; contradictory identities or terminal bounds make quality unavailable. Missing evidence stays unknown. A replaced log, including a longer replacement with the same session ID, creates a new observation baseline and does not replay historical completion notices.

Use `Start-Trial.cmd` for a visible directory-isolated trial and `Stop-Trial.cmd` to exit that isolated process. `Start-Monitor.cmd` explicitly starts its isolated background mode. Ordinary close exits an idle normal instance and hides an active collector; explicit exit ends it normally. The candidate uses a freshly built M1 Rust DLL and is delivered separately from prior stages and installed programs.

Validation records live in `environment/stage-m1-*` in the source checkout. Synthetic logs and native callback injections prove specific offline behavior. Physical notification visibility, physical mouse navigation and human GUI acceptance remain `NOT_RUN`. M2 Rust streaming/Chat support, M3 Responses and the API interface, and M4 user-triggered real-endpoint validation remain pending.
