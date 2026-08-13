param(
    [string]$WindowTitle = "Main@thinkorswim",
    [Parameter(Mandatory = $true)]
    [string]$Symbol,
    [string]$OcoId = "",
    [ValidateSet("Target", "Stop")]
    [string]$ConditionType = "Stop",
    [decimal]$ExpectedOldThreshold,
    [Parameter(Mandatory = $true)]
    [decimal]$NewThreshold,
    [string]$TreePath = "",
    [switch]$UseExistingTree,
    [switch]$OpenCancelReplace,
    [switch]$ApplyOrderRules,
    [switch]$AllowSave,
    [switch]$AllowFinalSubmit,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repoRoot "Analysis" }
$dumpScript = Join-Path $repoRoot "tools\Dump-TosJabTree.ps1"
$extractScript = Join-Path $repoRoot "Extract-TosWorkingOrdersFromTree.ps1"
$setConditionScript = Join-Path $repoRoot "tools\Set-TosOrderCondition.ps1"

foreach ($required in @($extractScript, $setConditionScript)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required script not found: $required" }
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($TreePath)) {
    $TreePath = Join-Path $OutDir "tos-oco-update-$($Symbol.ToUpperInvariant())-$stamp.txt"
}

if (-not $UseExistingTree) {
    if (-not (Test-Path -LiteralPath $dumpScript)) { throw "Required script not found: $dumpScript" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dumpScript -WindowTitle $WindowTitle -OutFile $TreePath | Out-Host
}
if (-not (Test-Path -LiteralPath $TreePath)) { throw "TreePath not found: $TreePath" }

$extractResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $extractScript -TreePath $TreePath -OutDir $OutDir
$ordersCsv = @($extractResult | Where-Object { $_.OrdersCsv } | Select-Object -ExpandProperty OrdersCsv -First 1)
if ([string]::IsNullOrWhiteSpace($ordersCsv) -or -not (Test-Path -LiteralPath $ordersCsv)) {
    $candidate = Get-ChildItem -LiteralPath $OutDir -Filter "tos-visible-working-orders-*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $candidate) { throw "Could not locate extracted orders CSV." }
    $ordersCsv = $candidate.FullName
}

$rows = @(Import-Csv -LiteralPath $ordersCsv)
$activeRows = @($rows | Where-Object {
    $_.Status -eq "WAIT COND" -and
    $_.ConditionSymbol -eq $Symbol -and
    ([string]::IsNullOrWhiteSpace($OcoId) -or $_.OcoId -eq $OcoId) -and
    ([decimal]$_.ConditionThreshold -eq $ExpectedOldThreshold)
})

if ($activeRows.Count -ne 1) {
    $near = @($rows | Where-Object {
        $_.ConditionSymbol -eq $Symbol -and ([string]::IsNullOrWhiteSpace($OcoId) -or $_.OcoId -eq $OcoId)
    } | Select-Object Status,Quantity,Ticker,OrderType,OcoId,ConditionSymbol,ConditionSide,ConditionThreshold,RawOrder)

    $nearPath = Join-Path $OutDir "tos-oco-update-$($Symbol.ToUpperInvariant())-$stamp-near-matches.csv"
    $near | Export-Csv -LiteralPath $nearPath -NoTypeInformation -Encoding UTF8
    throw "Refusing to proceed. Expected exactly one active $Symbol OCO row with threshold $ExpectedOldThreshold; found $($activeRows.Count). Near matches: $nearPath"
}

$row = $activeRows[0]
$expectedSide = if ($ConditionType -eq "Stop") { "BELOW" } else { "ABOVE" }
if ($row.ConditionSide -ne $expectedSide) {
    throw "Refusing to proceed. ConditionType $ConditionType expects side $expectedSide, but matched row has $($row.ConditionSide)."
}

$operatorText = if ($ConditionType -eq "Stop") { "AT OR BELOW" } else { "AT OR ABOVE" }
$newConditionText = "$Symbol MARK $operatorText $($NewThreshold.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture))"
$plan = [pscustomobject]@{
    Timestamp = (Get-Date).ToString("s")
    Mode = if ($AllowFinalSubmit) { "LIVE_SUBMIT_ALLOWED" } elseif ($AllowSave) { "SAVE_ALLOWED" } elseif ($ApplyOrderRules) { "ORDER_RULES_EDIT_ONLY" } elseif ($OpenCancelReplace) { "OPEN_CANCEL_REPLACE_ONLY" } else { "DRY_RUN" }
    Symbol = $Symbol
    OcoId = $row.OcoId
    ConditionType = $ConditionType
    OldThreshold = $row.ConditionThreshold
    NewThreshold = $NewThreshold
    ExpectedNewConditionText = $newConditionText
    MatchedStatus = $row.Status
    MatchedQuantity = $row.Quantity
    MatchedTicker = $row.Ticker
    MatchedOrderType = $row.OrderType
    MatchedRawOrder = $row.RawOrder
    TreePath = $TreePath
    OrdersCsv = $ordersCsv
}

$planPath = Join-Path $OutDir "tos-oco-update-$($Symbol.ToUpperInvariant())-$stamp-plan.csv"
$plan | Export-Csv -LiteralPath $planPath -NoTypeInformation -Encoding UTF8
$plan | Format-List
Write-Host "Wrote OCO update plan to $planPath"

if (-not $OpenCancelReplace -and -not $ApplyOrderRules -and -not $AllowSave -and -not $AllowFinalSubmit) {
    Write-Host "Dry run complete. No TOS clicks were performed."
    return
}

throw "Live cancel/replace orchestration is intentionally not enabled in this wrapper yet. Next implementation step: wire matched-row context menu open, Order Rules update, Save, Confirm/Send, and post-submit verification behind these switches."


