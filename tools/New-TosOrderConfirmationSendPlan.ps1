param(
    [Parameter(Mandatory=$true)][string]$SnapshotJson,
    [Parameter(Mandatory=$true)][string]$ExpectedSymbol,
    [Parameter(Mandatory=$true)][string]$ExpectedReplacingOrderId,
    [Parameter(Mandatory=$true)][string]$ExpectedThresholdText,
    [string]$ExpectedOrderRegex = "",
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not (Test-Path -LiteralPath $SnapshotJson)) { throw "SnapshotJson not found: $SnapshotJson" }
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = ($ExpectedSymbol -replace '[^A-Za-z0-9_.-]+', '-')
    $OutFile = Join-Path $projectRoot "TosAutomation\Diagnostics\tos-order-confirmation-send-plan-$safeSymbol-$stamp.json"
}

$snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
$nodes = @($snapshot.nodes)
$dialog = $nodes | Where-Object { $_.role -eq 'dialog' -and $_.name -eq 'Order Confirmation Dialog' } | Select-Object -First 1
$symbol = $nodes | Where-Object { $_.role -eq 'label' -and $_.name -eq $ExpectedSymbol } | Select-Object -First 1
$order = $nodes | Where-Object { $_.role -eq 'label' -and $_.name -match "Replacing #$([regex]::Escape($ExpectedReplacingOrderId))" } | Select-Object -First 1
$condition = $nodes | Where-Object { $_.role -eq 'label' -and $_.name -eq $ExpectedThresholdText } | Select-Object -First 1
$send = $nodes | Where-Object { $_.role -eq 'push button' -and $_.name -eq 'Send' -and $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 } | Select-Object -First 1
$edit = $nodes | Where-Object { $_.role -eq 'push button' -and $_.name -eq 'Edit' } | Select-Object -First 1

$errors = New-Object System.Collections.Generic.List[string]
if (-not $dialog) { $errors.Add("Order Confirmation Dialog was not found.") | Out-Null }
if (-not $symbol) { $errors.Add("Expected symbol label '$ExpectedSymbol' was not found.") | Out-Null }
if (-not $order) { $errors.Add("Expected replacing order id '$ExpectedReplacingOrderId' was not found.") | Out-Null }
if (-not [string]::IsNullOrWhiteSpace($ExpectedOrderRegex) -and ($order.name -notmatch $ExpectedOrderRegex)) { $errors.Add("Order description did not match ExpectedOrderRegex.") | Out-Null }
if (-not $condition) { $errors.Add("Expected condition '$ExpectedThresholdText' was not found.") | Out-Null }
if (-not $send) { $errors.Add("Visible Send button was not found.") | Out-Null }
if (-not $edit) { $errors.Add("Edit button was not found; cannot safely back out through expected control.") | Out-Null }

$sendClickPoint = $null
if ($send) {
    $sendClickPoint = [pscustomobject]@{
        x = [int]([int]$send.bounds.x + ([int]$send.bounds.width / 2))
        y = [int]([int]$send.bounds.y + ([int]$send.bounds.height / 2))
    }
}

$plan = [pscustomobject]@{
    createdAt = (Get-Date).ToString("o")
    dryRun = $true
    snapshot = $SnapshotJson
    expectedSymbol = $ExpectedSymbol
    expectedReplacingOrderId = $ExpectedReplacingOrderId
    expectedThresholdText = $ExpectedThresholdText
    dialog = $dialog
    symbol = $symbol
    orderDescription = $order
    condition = $condition
    editButton = $edit
    sendButton = $send
    sendClickPoint = $sendClickPoint
    allowedToFinalSend = ($errors.Count -eq 0)
    requiredExecutionFlag = "-AllowFinalSend"
    warnings = @(
        "This plan does not click Send.",
        "Final Send is the live order replacement boundary and requires separate explicit approval.",
        "After final Send, capture main TOS state and verify the old replacing row is gone or the resulting order id/status changed as expected."
    )
    errors = @($errors)
}
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$plan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$plan | ConvertTo-Json -Depth 14
Write-Host "Wrote Order Confirmation Send plan to $OutFile"
if ($errors.Count -gt 0) { exit 2 }

