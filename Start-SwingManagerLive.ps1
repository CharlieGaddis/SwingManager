param(
    [string]$ProjectRoot = "",
    [string]$TradingDashboardRoot = "",
    [string]$PythonPath = "",
    [int]$DashboardPort = 5080,
    [int]$SwingManagerPort = 8765,
    [int]$StartupTimeoutSeconds = 45,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($TradingDashboardRoot)) {
    $TradingDashboardRoot = Join-Path (Split-Path -Parent $ProjectRoot) "TradingDashboard"
}

$machineConfigPath = Join-Path $ProjectRoot "Config\machine.local.json"
$paths = & (Join-Path $ProjectRoot "tools\Resolve-SwingManagerRuntime.ps1") -ProjectRoot $ProjectRoot
$data = [string]$paths.DataPath

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
    $PythonPath = Join-Path $ProjectRoot $PythonPath
}
$PythonPath = [System.IO.Path]::GetFullPath($PythonPath)

$dashboardBaseUrl = "http://127.0.0.1:$DashboardPort"
$swingManagerBaseUrl = "http://127.0.0.1:$SwingManagerPort"
$dashboardStartScript = Join-Path $TradingDashboardRoot "Scripts\Start-TradingDashboard.ps1"
$managerStartScript = Join-Path $ProjectRoot "Start-SwingPendingManager.ps1"
$readinessScript = Join-Path $ProjectRoot "Test-SwingManagerLiveReadiness.ps1"

foreach ($requiredPath in @($dashboardStartScript, $managerStartScript, $readinessScript, $PythonPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required live-start dependency was not found: $requiredPath"
    }
}

function Get-JsonOrNull {
    param([string]$Uri, [int]$TimeoutSec = 5)
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec $TimeoutSec
    } catch {
        $null
    }
}

function Wait-ForJson {
    param([string]$Uri, [datetime]$Deadline)
    do {
        $result = Get-JsonOrNull -Uri $Uri -TimeoutSec 2
        if ($null -ne $result) {
            return $result
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $Deadline)
    return $null
}

Write-Host "Ensuring TradingDashboard is live-order ready."
$schwabStatus = Get-JsonOrNull "$dashboardBaseUrl/api/schwab/status"
$dashboardHealth = Get-JsonOrNull "$dashboardBaseUrl/api/health"
$dashboardNeedsRestart = $dashboardHealth -and (
    -not $schwabStatus `
    -or $schwabStatus.httpsCallbackState -ne "HTTPS_CALLBACK_READY"
)
if ($dashboardNeedsRestart) {
    $listener = Get-NetTCPConnection -LocalPort $DashboardPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) {
        throw "TradingDashboard needs live-capability recovery, but its process could not be identified."
    }
    $dashboardProcess = Get-Process -Id $listener.OwningProcess -ErrorAction Stop
    if ($dashboardProcess.ProcessName -notlike "TradingDashboard.Web*") {
        throw "Port $DashboardPort belongs to unexpected process $($dashboardProcess.ProcessName); refusing to stop it."
    }
    Stop-Process -Id $dashboardProcess.Id -Force
    Start-Sleep -Seconds 1
}

$dashboardResult = & $dashboardStartScript `
    -ProjectRoot $TradingDashboardRoot `
    -HttpPort $DashboardPort `
    -EnableOrderCapability | ConvertFrom-Json
if ($dashboardResult.httpHealthState -ne "HEALTH_READY") {
    throw "TradingDashboard did not become healthy."
}

$schwabStatus = Get-JsonOrNull "$dashboardBaseUrl/api/schwab/status"
if (-not $schwabStatus -or -not [bool]$schwabStatus.connected) {
    throw "TradingDashboard is not Schwab-connected."
}
if ($schwabStatus.httpsCallbackState -ne "HTTPS_CALLBACK_READY") {
    throw "TradingDashboard Schwab HTTPS callback is not ready: $($schwabStatus.httpsCallbackState)"
}

$pending = Get-JsonOrNull "$swingManagerBaseUrl/api/pending" 3
if (-not $pending) {
    Write-Host "Starting SwingManager server and monitor."
    & $managerStartScript `
        -Port $SwingManagerPort `
        -PythonPath $PythonPath `
        -AutoStartMonitor `
        -Background
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $pending = Wait-ForJson "$swingManagerBaseUrl/api/pending" $deadline
    if (-not $pending) {
        throw "SwingManager server did not become ready before the timeout."
    }
}

if (-not [bool]$pending.runtime.monitorRunning) {
    Write-Host "Starting SwingManager monitor after live preflight."
    $monitorResult = Invoke-RestMethod `
        -Method Post `
        -Uri "$swingManagerBaseUrl/api/monitor/start" `
        -Body "{}" `
        -ContentType "application/json" `
        -TimeoutSec 30
    if (-not [bool]$monitorResult.ok) {
        throw "SwingManager monitor failed to start."
    }
}

if ($OpenBrowser) {
    Start-Process $swingManagerBaseUrl
}

Write-Host "Running end-to-end live readiness and quote-heartbeat verification."
& $readinessScript `
    -ProjectRoot $ProjectRoot `
    -DashboardBaseUrl $dashboardBaseUrl `
    -SwingManagerBaseUrl $swingManagerBaseUrl
if ($LASTEXITCODE -ne 0) {
    throw "SwingManager live readiness failed. See $data\live-readiness-status.json."
}
