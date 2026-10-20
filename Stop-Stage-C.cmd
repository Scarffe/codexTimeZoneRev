@echo off
rem Gracefully stop only this isolated Stage C monitor.
start "" "%~dp0environment\stage-c-portable\codex_timezone.exe" --desktop-monitor --monitor-exit
