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
    $OutFile = Join-Path $diagnosticsDir ("tos-order-entry-maintenance-surface-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
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

function Get-Nodes {
    param([string]$SnapshotJson)
    $snap = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
    return @($snap.nodes)
}

function Find-VisibleNode {
    param([object[]]$Nodes, [string]$Role, [string]$Name)
    return @($Nodes | Where-Object {
        $_.role -eq $Role -and
        ([string]$_.name) -eq $Name -and
        $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 -and
        ([string]$_.states) -match 'showing'
    } | Sort-Object @{ Expression = { [int]$_.bounds.y } }, @{ Expression = { [int]$_.bounds.x } } | Select-Object -First 1)
}

function Click-Node {
    param([object]$Node, [string]$StepName)
    if (-not $AllowInput) { throw "$StepName requires -AllowInput." }
    if (-not $Node -or -not $Node.bounds) { throw "Cannot click missing node for $StepName." }
    $x = [int]([int]$Node.bounds.x + ([int]$Node.bounds.width / 2))
    $y = [int]([int]$Node.bounds.y + ([int]$Node.bounds.height / 2))
    $inputScript = Join-Path $scriptDir "Invoke-TosNativeInput.ps1"
    $step = Invoke-Step -Name $StepName -Script $inputScript -Arguments @("-Action", "Click", "-X", [string]$x, "-Y", [string]$y, "-AllowInput")
    if ($step.exitCode -ne 0) { throw "$StepName failed with exit code $($step.exitCode)." }
}

try {
    $snapshot = New-SnapshotJson "EnsureOrderEntrySurface-Initial"
    $nodes = Get-Nodes $snapshot

    $entryAccordion = Find-VisibleNode -Nodes $nodes -Role "toggle button" -Name "Order Entry and Saved Orders"
    if (-not $entryAccordion) { throw "Order Entry and Saved Orders accordion was not found." }
    if ([string]$entryAccordion.states -notmatch 'checked') {
        Click-Node -Node $entryAccordion -StepName "OpenOrderEntryAndSavedOrders"
        Start-Sleep -Milliseconds 700
        $snapshot = New-SnapshotJson "EnsureOrderEntrySurface-AfterOpenOrderEntry"
        $nodes = Get-Nodes $snapshot
    }

    $entryTab = Find-VisibleNode -Nodes $nodes -Role "page tab" -Name "Order Entry"
    if ($entryTab -and [string]$entryTab.states -notmatch 'selected') {
        Click-Node -Node $entryTab -StepName "SelectOrderEntryTab"
        Start-Sleep -Milliseconds 500
        $snapshot = New-SnapshotJson "EnsureOrderEntrySurface-AfterSelectOrderEntry"
        $nodes = Get-Nodes $snapshot
    }

    $strategyBook = Find-VisibleNode -Nodes $nodes -Role "toggle button" -Name "Order and Strategy Book"
    if ($strategyBook -and [string]$strategyBook.states -match 'checked') {
        Click-Node -Node $strategyBook -StepName "CloseOrderAndStrategyBook"
        Start-Sleep -Milliseconds 700
        $snapshot = New-SnapshotJson "EnsureOrderEntrySurface-AfterCloseStrategyBook"
        $nodes = Get-Nodes $snapshot
    }

    $entryAccordion = Find-VisibleNode -Nodes $nodes -Role "toggle button" -Name "Order Entry and Saved Orders"
    $entryTab = Find-VisibleNode -Nodes $nodes -Role "page tab" -Name "Order Entry"
    $strategyBook = Find-VisibleNode -Nodes $nodes -Role "toggle button" -Name "Order and Strategy Book"
    if (-not $entryAccordion -or [string]$entryAccordion.states -notmatch 'checked') { $errors.Add("Order Entry and Saved Orders is not open after guard.") | Out-Null }
    if (-not $entryTab -or [string]$entryTab.states -notmatch 'selected') { $errors.Add("Order Entry tab is not selected after guard.") | Out-Null }
    if ($strategyBook -and [string]$strategyBook.states -match 'checked') { $errors.Add("Order and Strategy Book is still open after guard.") | Out-Null }
} catch {
    $errors.Add($_.Exception.Message) | Out-Null
}

$result = [ordered]@{
    createdAt = (Get-Date).ToString('o')
    allowInput = [bool]$AllowInput
    finalSnapshot = $snapshot
    orderEntryAccordionState = if ($entryAccordion) { [string]$entryAccordion.states } else { "" }
    orderEntryTabState = if ($entryTab) { [string]$entryTab.states } else { "" }
    strategyBookState = if ($strategyBook) { [string]$strategyBook.states } else { "" }
    steps = @([object[]]$steps.ToArray())
    errors = @([string[]]$errors.ToArray())
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 16
Write-Host "Wrote TOS Order Entry maintenance surface guard result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }
