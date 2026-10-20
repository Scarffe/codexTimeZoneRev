@echo off
rem Isolated Stage C build. Close main window to keep the pet monitoring.
start "" "%~dp0environment\stage-c-portable\codex_timezone.exe" --desktop-monitor
