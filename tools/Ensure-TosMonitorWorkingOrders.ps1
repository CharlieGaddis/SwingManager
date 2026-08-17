param(
    [string]$WindowTitle = "Main@thinkorswim",
    [switch]$AllowInput,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
$diagnosticsDir = Join-Path $projectRoot "TosAutomation\Diagnostics"
$discoveryDir = Join-Path $projectRoot "TosAutomation\Discovery"
if (-not (Test-Path -LiteralPath $diagnosticsDir)) { New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null }
if (-not (Test-Path -LiteralPath $discoveryDir)) { New-Item -ItemType Directory -Force -Path $discoveryDir | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $diagnosticsDir ("tos-monitor-working-orders-guard-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

$errors = New-Object System.Collections.Generic.List[string]
$steps = New-Object System.Collections.Generic.List[object]

function Invoke-Step {
    param([string]$Name, [string]$Script, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Script)) { throw "Missing script for $Name`: $Script" }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
    $step = [pscustomobject]@{
        name = $Name
        script = $Script
        arguments = @($Arguments)
        output = ($output | Out-String).Trim()
        exitCode = $LASTEXITCODE
    }
    $steps.Add($step) | Out-Null
    return $step
}

function New-SnapshotJson {
    param([string]$Label)
    $snapshotScript = Join-Path $scriptDir "New-TosAutomationSnapshot.ps1"
    $started = Get-Date
    $step = Invoke-Step -Name "Snapshot-$Label" -Script $snapshotScript -Arguments @("-WindowTitle", $WindowTitle, "-Label", $Label, "-MaxDepth", "35", "-MaxChildrenPerNode", "1000")
    if ($step.exitCode -ne 0) { throw "Snapshot command failed for $Label with exit code $($step.exitCode)." }
    $snapshot = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-$Label-*-tree.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $snapshot) { throw "Fresh snapshot JSON was not produced for label $Label." }
    return $snapshot.FullName
}

function Get-SnapshotNodes {
    param([string]$SnapshotJson)
    $snap = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
    return @($snap.nodes)
}

function Find-Node {
    param([object[]]$Nodes, [string]$Role, [string]$NameRegex, [switch]$ShowingOnly)
    $matches = @($Nodes | Where-Object {
        $_.role -eq $Role -and
        ([string]$_.name) -match $NameRegex -and
        $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 -and
        (-not $ShowingOnly -or ([string]$_.states -match 'showing'))
    })
    return $matches | Sort-Object @{ Expression = { if (([string]$_.states) -match 'selected|checked') { 0 } else { 1 } } }, @{ Expression = { [int]$_.bounds.y } }, @{ Expression = { [int]$_.bounds.x } } | Select-Object -First 1
}

function Invoke-NodeAction {
    param([object]$Node, [string]$ExpectedRole, [string]$ExpectedName, [string]$StepName)
    if (-not $Node) { throw "Cannot invoke missing node for $StepName." }
    if (-not $Node.bounds -or [int]$Node.bounds.width -le 0 -or [int]$Node.bounds.height -le 0) { throw "Cannot click node without visible bounds for $StepName." }
    if (-not $AllowInput) { throw "$StepName requires -AllowInput." }
    $actionScript = Join-Path $scriptDir "Invoke-TosJabActionPath.ps1"
    $args = @("-WindowTitle", $WindowTitle, "-Path", [string]$Node.path, "-ExpectedRole", $ExpectedRole, "-ExpectedName", $ExpectedName, "-AllowAction")
    $step = Invoke-Step -Name $StepName -Script $actionScript -Arguments $args
    if ($step.exitCode -eq 0) { return $step }

    $clickScript = Join-Path $scriptDir "Invoke-TosNativeInput.ps1"
    $x = [int]([int]$Node.bounds.x + ([int]$Node.bounds.width / 2))
    $y = [int]([int]$Node.bounds.y + ([int]$Node.bounds.height / 2))
    $clickArgs = @("-Action", "Click", "-X", [string]$x, "-Y", [string]$y, "-AllowInput")
    $click = Invoke-Step -Name "$StepName-NativeClickFallback" -Script $clickScript -Arguments $clickArgs
    if ($click.exitCode -ne 0) { throw "$StepName failed by action and click fallback." }
    return $click
}

try {
    $snapshot = New-SnapshotJson "EnsureMonitorWorkingOrders-Initial"
    $nodes = Get-SnapshotNodes $snapshot

    $monitor = Find-Node -Nodes $nodes -Role "page tab" -NameRegex "^Monitor$" -ShowingOnly
    if (-not $monitor) { throw "Could not find visible Monitor page tab." }
    if (([string]$monitor.states) -notmatch 'selected') {
        Invoke-NodeAction -Node $monitor -ExpectedRole "page tab" -ExpectedName "Monitor" -StepName "SelectMonitor" | Out-Null
        Start-Sleep -Milliseconds 900
        $snapshot = New-SnapshotJson "EnsureMonitorWorkingOrders-AfterMonitor"
        $nodes = Get-SnapshotNodes $snapshot
    }

    $activity = Find-Node -Nodes $nodes -Role "toggle button" -NameRegex "^Activity and Positions$" -ShowingOnly
    if ($activity -and ([string]$activity.states) -notmatch 'checked|selected') {
        Invoke-NodeAction -Node $activity -ExpectedRole "toggle button" -ExpectedName "Activity and Positions" -StepName "OpenActivityAndPositions" | Out-Null
        Start-Sleep -Milliseconds 700
        $snapshot = New-SnapshotJson "EnsureMonitorWorkingOrders-AfterActivity"
        $nodes = Get-SnapshotNodes $snapshot
    }

    $workingOrders = Find-Node -Nodes $nodes -Role "toggle button" -NameRegex "^Working Orders" -ShowingOnly
    if (-not $workingOrders) {
        $workingOrders = Find-Node -Nodes $nodes -Role "toggle button" -NameRegex "^Working Orders"
    }
    if ($workingOrders -and ([string]$workingOrders.states) -notmatch 'checked') {
        Invoke-NodeAction -Node $workingOrders -ExpectedRole "toggle button" -ExpectedName ([string]$workingOrders.name) -StepName "OpenWorkingOrders" | Out-Null
        Start-Sleep -Milliseconds 700
        $snapshot = New-SnapshotJson "EnsureMonitorWorkingOrders-AfterWorkingOrders"
        $nodes = Get-SnapshotNodes $snapshot
    }

    $monitor = Find-Node -Nodes $nodes -Role "page tab" -NameRegex "^Monitor$" -ShowingOnly
    $workingOrders = Find-Node -Nodes $nodes -Role "toggle button" -NameRegex "^Working Orders" -ShowingOnly
    if (-not $monitor -or ([string]$monitor.states) -notmatch 'selected') { $errors.Add("Monitor tab is not selected after guard.") | Out-Null }
    if (-not $workingOrders) { $errors.Add("Working Orders accordion was not found after guard.") | Out-Null }
    elseif ([string]$workingOrders.states -notmatch 'checked') { $errors.Add("Working Orders accordion is not open after guard.") | Out-Null }
} catch {
    $errors.Add($_.Exception.Message) | Out-Null
}

$result = [ordered]@{
    createdAt = (Get-Date).ToString('o')
    allowInput = [bool]$AllowInput
    finalSnapshot = $snapshot
    monitorState = if ($monitor) { [string]$monitor.states } else { "" }
    workingOrdersName = if ($workingOrders) { [string]$workingOrders.name } else { "" }
    workingOrdersState = if ($workingOrders) { [string]$workingOrders.states } else { "" }
    steps = @([object[]]$steps.ToArray())
    errors = @([string[]]$errors.ToArray())
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 16
Write-Host "Wrote TOS Monitor/Working Orders guard result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }
