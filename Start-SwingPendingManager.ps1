param(
    [int]$Port = 8765,
    [string]$PythonPath = "",
    [switch]$AutoStartMonitor,
    [switch]$Background,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$paths = & (Join-Path $root "tools\Resolve-SwingManagerRuntime.ps1") -ProjectRoot $root
$runtimeRoot = [string]$paths.RuntimeRoot
$data = [string]$paths.DataPath
New-Item -ItemType Directory -Path $data -Force | Out-Null

$machineConfigPath = Join-Path $root "Config\machine.local.json"
$machineConfig = $null
if (Test-Path -LiteralPath $machineConfigPath) {
    $machineConfig = Get-Content -Raw -LiteralPath $machineConfigPath | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $PythonPath = $env:SWING_MANAGER_PYTHON
}
if ([string]::IsNullOrWhiteSpace($PythonPath) -and $machineConfig) {
    $PythonPath = [string]$machineConfig.pythonPath
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pythonCommand) { $PythonPath = $pythonCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    throw "Python runtime was not found. Set SWING_MANAGER_PYTHON or Config\machine.local.json pythonPath to a Swing Manager-approved Python."
}
$PythonPath = [Environment]::ExpandEnvironmentVariables($PythonPath)
if (-not [System.IO.Path]::IsPathRooted($PythonPath)) {
    $PythonPath = Join-Path $root $PythonPath
}
$PythonPath = [System.IO.Path]::GetFullPath($PythonPath)

if (-not (Test-Path -LiteralPath $PythonPath)) {
    throw "Python runtime was not found: $PythonPath"
}

$env:SWING_MANAGER_PORT = [string]$Port
$env:SWING_MANAGER_RUNTIME_ROOT = $runtimeRoot
$env:SWING_MANAGER_AUTO_START_MONITOR = if ($AutoStartMonitor) { "true" } else { "false" }
Write-Host "Starting Swing Manager on http://127.0.0.1:$Port"

if ($OpenBrowser) {
    Start-Process "http://127.0.0.1:$Port"
}

$serverScript = Join-Path $root "pending_manager_server.py"
if ($Background) {
    $stdoutPath = Join-Path $data "pending-server-start.out.log"
    $stderrPath = Join-Path $data "pending-server-start.err.log"
    $quotedServerScript = '"' + $serverScript + '"'
    $process = Start-Process `
        -FilePath $PythonPath `
        -ArgumentList $quotedServerScript `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    Write-Host "Swing Manager process started (PID $($process.Id))."
    return
}

Write-Host "Press Ctrl+C in this window to stop it."
& $PythonPath $serverScript
