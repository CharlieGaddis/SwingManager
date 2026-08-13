@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Start-SwingPendingManager.ps1" -OpenBrowser
pause
