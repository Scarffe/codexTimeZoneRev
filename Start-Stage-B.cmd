@echo off
rem Isolated Stage B build. Closing the main window keeps monitoring in tray.
start "" "%~dp0environment\stage-b-portable\codex_timezone.exe" --desktop-monitor
