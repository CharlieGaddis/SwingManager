@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Start-SwingManagerLive.ps1" -OpenBrowser
if errorlevel 1 pause
