param(
    [string]$ProjectRoot = "",
    [string]$DashboardBaseUrl = "http://127.0.0.1:5080",
    [string]$SwingManagerBaseUrl = "http://127.0.0.1:8765",
    [int]$QuoteAdvanceWaitSeconds = 7,
    [switch]$OpenBrowserOnAuthRequired
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$paths = & (Join-Path $ProjectRoot "tools\Resolve-SwingManagerRuntime.ps1") -ProjectRoot $ProjectRoot
$dataDir = [string]$paths.DataPath
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$statusPath = Join-Path $dataDir "live-readiness-status.json"

function Get-JsonOrNull {
    param([string]$Uri, [int]$TimeoutSec = 5)
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec $TimeoutSec
    } catch {
        $null
    }
}

function New-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    [ordered]@{ name = $Name; ok = $Ok; detail = $Detail }
}

$checks = New-Object System.Collections.Generic.List[object]
$dashboardHealth = Get-JsonOrNull "$DashboardBaseUrl/api/health"
$schwabStatus = Get-JsonOrNull "$DashboardBaseUrl/api/schwab/status"
$pending = Get-JsonOrNull "$SwingManagerBaseUrl/api/pending" 8
$initialQuoteRefreshAt = if ($pending) { $pending.runtime.lastQuoteRefreshAt } else { $null }
if ($pending -and [bool]$pending.runtime.monitorRunning -and $QuoteAdvanceWaitSeconds -gt 0) {
    $firstRefreshDeadline = (Get-Date).AddSeconds([math]::Max(15, $QuoteAdvanceWaitSeconds * 2))
    while (-not $initialQuoteRefreshAt -and (Get-Date) -lt $firstRefreshDeadline) {
        Start-Sleep -Milliseconds 500
        $pending = Get-JsonOrNull "$SwingManagerBaseUrl/api/pending" 8
        $initialQuoteRefreshAt = if ($pending) { $pending.runtime.lastQuoteRefreshAt } else { $null }
    }
    Start-Sleep -Seconds $QuoteAdvanceWaitSeconds
    $pending = Get-JsonOrNull "$SwingManagerBaseUrl/api/pending" 8
}

$checks.Add((New-Check "TradingDashboard health" ($null -ne $dashboardHealth) $(if ($dashboardHealth) { "ready" } else { "not responding" }))) | Out-Null
$checks.Add((New-Check "Schwab callback" ($schwabStatus -and $schwabStatus.httpsCallbackState -eq "HTTPS_CALLBACK_READY") $(if ($schwabStatus) { [string]$schwabStatus.httpsCallbackState } else { "status unavailable" }))) | Out-Null
$checks.Add((New-Check "Schwab connected" ($schwabStatus -and [bool]$schwabStatus.connected) $(if ($schwabStatus) { "connected=$($schwabStatus.connected)" } else { "status unavailable" }))) | Out-Null
$checks.Add((New-Check "SwingManager direct submit path" ($schwabStatus -and [bool]$schwabStatus.connected) $(if ($schwabStatus) { "dashboardOrderCapability=$($schwabStatus.orderCapability); directSubmitUsesSharedOAuthToken=true" } else { "status unavailable" }))) | Out-Null
$checks.Add((New-Check "SwingManager server" ($null -ne $pending) $(if ($pending) { "ready" } else { "not responding" }))) | Out-Null
$checks.Add((New-Check "SwingManager monitor" ($pending -and [bool]$pending.runtime.monitorRunning) $(if ($pending) { "monitorRunning=$($pending.runtime.monitorRunning)" } else { "pending unavailable" }))) | Out-Null
$quoteRefreshAdvanced = $pending -and $initialQuoteRefreshAt -and $pending.runtime.lastQuoteRefreshAt `
    -and ([datetimeoffset]$pending.runtime.lastQuoteRefreshAt -gt [datetimeoffset]$initialQuoteRefreshAt)
$checks.Add((New-Check "SwingManager monitor heartbeat" $quoteRefreshAdvanced $(if ($pending) { "initialQuoteRefreshAt=$initialQuoteRefreshAt; currentQuoteRefreshAt=$($pending.runtime.lastQuoteRefreshAt)" } else { "pending unavailable" }))) | Out-Null
$checks.Add((New-Check "SwingManager quote refresh" ($pending -and -not $pending.runtime.lastQuoteError -and [int]$pending.runtime.quoteCount -gt 0) $(if ($pending) { "lastQuoteError=$($pending.runtime.lastQuoteError); quoteCount=$($pending.runtime.quoteCount)" } else { "pending unavailable" }))) | Out-Null
$refreshAgeSeconds = $null
$maxRefreshAgeSeconds = 180
if ($pending -and $pending.runtime.lastQuoteFreshness.maxQuoteAgeSeconds) {
    $maxRefreshAgeSeconds = [int]$pending.runtime.lastQuoteFreshness.maxQuoteAgeSeconds
}
if ($pending -and $pending.runtime.lastQuoteRefreshAt) {
    $refreshAgeSeconds = ((Get-Date).ToUniversalTime() - ([datetimeoffset]$pending.runtime.lastQuoteRefreshAt).UtcDateTime).TotalSeconds
}
$freshnessOk = $pending -and $pending.runtime.lastQuoteRefreshAt `
    -and $null -ne $refreshAgeSeconds `
    -and $refreshAgeSeconds -le $maxRefreshAgeSeconds `
    -and -not @($pending.runtime.lastQuoteFreshness.stale).Count
$freshnessDetail = "pending unavailable"
if ($pending) {
    $freshnessDetail = "lastQuoteRefreshAt=$($pending.runtime.lastQuoteRefreshAt); ageSeconds=$([math]::Round([double]$refreshAgeSeconds, 1)); maxAgeSeconds=$maxRefreshAgeSeconds; stale=$(@($pending.runtime.lastQuoteFreshness.stale) -join ', ')"
}
$checks.Add((New-Check "SwingManager quote freshness" $freshnessOk $freshnessDetail)) | Out-Null
$checks.Add((New-Check "SwingManager order reconciliation" ($pending -and -not $pending.runtime.lastOrderError) $(if ($pending) { "lastOrderError=$($pending.runtime.lastOrderError)" } else { "pending unavailable" }))) | Out-Null
$checks.Add((New-Check "SwingManager token keepalive" ($pending -and -not $pending.runtime.lastTokenRefreshError -and $pending.runtime.lastTokenRefreshAt) $(if ($pending) { "lastTokenRefreshAt=$($pending.runtime.lastTokenRefreshAt); lastTokenRefreshError=$($pending.runtime.lastTokenRefreshError)" } else { "pending unavailable" }))) | Out-Null

$ready = -not @($checks | Where-Object { -not $_.ok }).Count
if (-not $ready -and $OpenBrowserOnAuthRequired -and $schwabStatus -and -not [bool]$schwabStatus.connected) {
    Start-Process "$DashboardBaseUrl/schwab.html"
}

$runtimeSnapshot = $null
if ($pending) {
    $runtimeSnapshot = $pending.runtime
}

$nextAction = "Run the live recovery/startup guard after explicit approval."
if ($ready) {
    $nextAction = "READY"
} elseif ($schwabStatus -and -not [bool]$schwabStatus.connected) {
    $nextAction = "Open $DashboardBaseUrl/schwab.html and reauthorize Schwab."
}

$payload = @{}
$payload["checkedAt"] = (Get-Date).ToString("o")
$payload["ready"] = [bool]$ready
$payload["dashboard"] = $schwabStatus
$payload["swingManagerRuntime"] = $runtimeSnapshot
$payload["checks"] = @($checks.ToArray())
$payload["nextAction"] = $nextAction

$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
$payload | ConvertTo-Json -Depth 10
if (-not $ready) { exit 1 }
exit 0
