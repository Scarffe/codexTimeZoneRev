@echo off
rem Gracefully stop only the isolated Stage B instance, waiting for its query.
start "" "%~dp0environment\stage-b-portable\codex_timezone.exe" --desktop-monitor --monitor-exit
