param(
    [int]$Port = 8765,
    [string]$PythonPath = "C:\Users\charl\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe",
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = Join-Path $root "Data"
New-Item -ItemType Directory -Path $data -Force | Out-Null

if (-not (Test-Path -LiteralPath $PythonPath)) {
    throw "Python runtime was not found: $PythonPath"
}

$env:SWING_MANAGER_PORT = [string]$Port
Write-Host "Starting Swing Manager on http://127.0.0.1:$Port"
Write-Host "Press Ctrl+C in this window to stop it."

if ($OpenBrowser) {
    Start-Process "http://127.0.0.1:$Port"
}

& $PythonPath (Join-Path $root "pending_manager_server.py")
