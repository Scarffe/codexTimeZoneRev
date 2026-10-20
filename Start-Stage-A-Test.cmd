@echo off
rem Independent native input target; no account access.
start "" "%~dp0environment\desktop-prototype\Release\desktop_prototype.exe" --desktop-prototype --preview --prototype-test-host
