param(
    [Parameter(Mandatory=$true)][string]$TreePath,
    [string]$ActionQueuePath = "",
    [string]$OutDir = ".\Analysis"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Get-LabelName([string]$line) {
    if ($line -match 'role="label"\s+name="([^"]*)"') {
        return $matches[1]
    }
    return $null
}

function Parse-Order([string]$text, [string]$status) {
    $ticker = ""
    $quantity = ""
    $orderType = ""
    $ocoId = ""
    $conditionSymbol = ""
    $conditionSide = ""
    $conditionThreshold = ""
    $toClose = $text -match '\[TO CLOSE'

    if ($text -match '^(?:\(Replacing #[0-9]+\)\s*)?(BUY|SELL)\s+([+-]?\d+)\s+([A-Z./$]+)\b') {
        $side = $matches[1]
        $quantity = $matches[2]
        $ticker = $matches[3]
    } else {
        $side = ""
    }

    if ($text -match '\s(STP|LMT|NET_DEBIT|NET_CREDIT)\s') {
        $orderType = $matches[1]
    }
    if ($text -match '\bOCO #([0-9]+)') {
        $ocoId = $matches[1]
    }
    if ($text -match '\bWHEN\s+([A-Z./$]+)\s+MARK\s+AT\s+OR\s+(ABOVE|BELOW)\s+([0-9.]+)') {
        $conditionSymbol = $matches[1]
        $conditionSide = $matches[2]
        $conditionThreshold = $matches[3]
    }

    [pscustomobject]@{
        Status = $status
        Side = $side
        Quantity = $quantity
        Ticker = $ticker
        OrderType = $orderType
        OcoId = $ocoId
        ConditionSymbol = $conditionSymbol
        ConditionSide = $conditionSide
        ConditionThreshold = $conditionThreshold
        ToClose = $toClose
        RawOrder = $text
    }
}

function Convert-NumberOrNull($value) {
    if ($null -eq $value -or [string]$value -eq "") { return $null }
    try { return [decimal]$value } catch { return $null }
}

function Test-HasThreshold($orders, $expectedValue, [string]$side, [decimal]$tolerance = 0.01) {
    $expected = Convert-NumberOrNull $expectedValue
    if ($null -eq $expected) { return $false }
    foreach ($order in @($orders)) {
        if ($order.ConditionSide -ne $side) { continue }
        $actual = Convert-NumberOrNull $order.ConditionThreshold
        if ($null -ne $actual -and [math]::Abs($actual - $expected) -le $tolerance) {
            return $true
        }
    }
    return $false
}

function Get-ThresholdsBySide($orders, [string]$side) {
    return (@($orders |
        Where-Object { $_.ConditionSide -eq $side -and $_.ConditionThreshold } |
        Select-Object -ExpandProperty ConditionThreshold -Unique) -join ", ")
}

$labels = New-Object System.Collections.Generic.List[string]
foreach ($line in Get-Content -LiteralPath $TreePath) {
    $name = Get-LabelName $line
    if ($null -ne $name -and $name.Trim() -ne "") {
        $labels.Add($name) | Out-Null
    }
}

$orders = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $labels.Count; $i++) {
    $label = $labels[$i]
    $looksLikeOrder = $label -match '^(?:\(Replacing #[0-9]+\)\s*)?(BUY|SELL)\s+[+-]?\d+\s+'
    if (-not $looksLikeOrder) { continue }

    $status = ""
    for ($j = $i + 1; $j -lt [Math]::Min($labels.Count, $i + 6); $j++) {
        if ($labels[$j] -in @("WAIT COND","WORKING","FILLED","CANCELED","REJECTED","EXPIRED")) {
            $status = $labels[$j]
            break
        }
    }

    $orders.Add((Parse-Order $label $status)) | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ordersCsv = Join-Path $OutDir "tos-visible-working-orders-$stamp.csv"
$reportPath = Join-Path $OutDir "tos-visible-working-orders-$stamp.md"
$orders | Export-Csv -LiteralPath $ordersCsv -NoTypeInformation

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# TOS Visible Working Orders")
$md.Add("")
$md.Add("Source tree: ``$TreePath``")
$md.Add("")
$md.Add("## Extracted Orders")
if ($orders.Count) {
    $md.Add(($orders | Select-Object Status,Ticker,Quantity,OrderType,OcoId,ConditionSymbol,ConditionSide,ConditionThreshold,ToClose,RawOrder | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())
} else {
    $md.Add("No order rows were extracted from the visible JAB tree.")
}

if ($ActionQueuePath) {
    $expected = @(Import-Csv -LiteralPath $ActionQueuePath | Where-Object { $_.Action -eq "EXPECTED_ACTIVE_OCO" })
    $workingCloseOrders = @($orders | Where-Object { $_.ToClose -and $_.Status -in @("WAIT COND","WORKING") })

    $md.Add("")
    $md.Add("## Expected Active OCO Visibility Check")
    $checks = @(foreach ($row in $expected) {
        $matchesByTicker = @($workingCloseOrders | Where-Object { $_.ConditionSymbol -eq $row.Ticker -or $_.Ticker -eq $row.Ticker })
        $hasStop = Test-HasThreshold $matchesByTicker $row.Stop "BELOW"
        $hasT1 = Test-HasThreshold $matchesByTicker $row.T1 "ABOVE"
        $hasT2 = Test-HasThreshold $matchesByTicker $row.T2 "ABOVE"
        $missing = @()
        if (-not $hasStop) { $missing += "STOP" }
        if (-not $hasT1) { $missing += "T1" }
        if (-not $hasT2) { $missing += "T2" }
        $status =
            if ($matchesByTicker.Count -eq 0) { "NOT_VISIBLE_IN_CURRENT_VIEW" }
            elseif ($missing.Count -eq 0) { "MATCHED_EXPECTED_LEVELS" }
            else { "REVIEW_" + ($missing -join "_") }
        [pscustomobject]@{
            Account = $row.Account
            Portfolio = $row.Portfolio
            Ticker = $row.Ticker
            ContractLabel = $row.ContractLabel
            ExpectedStop = $row.Stop
            ExpectedT1 = $row.T1
            ExpectedT2 = $row.T2
            VisibleWorkingCloseRows = $matchesByTicker.Count
            VisibleStopsBelow = Get-ThresholdsBySide $matchesByTicker "BELOW"
            VisibleTargetsAbove = Get-ThresholdsBySide $matchesByTicker "ABOVE"
            ReconcileStatus = $status
        }
    })
    $checksCsv = Join-Path $OutDir "tos-oco-reconciliation-$stamp.csv"
    $checks | Export-Csv -LiteralPath $checksCsv -NoTypeInformation
    $md.Add(($checks | Select-Object Account,Portfolio,Ticker,ContractLabel,ExpectedStop,ExpectedT1,ExpectedT2,VisibleWorkingCloseRows,VisibleStopsBelow,VisibleTargetsAbove,ReconcileStatus | Format-Table -AutoSize | Out-String -Width 280).TrimEnd())
}

Set-Content -LiteralPath $reportPath -Value ($md -join [Environment]::NewLine) -Encoding UTF8

[pscustomobject]@{
    OrdersCsv = (Resolve-Path -LiteralPath $ordersCsv).Path
    ReportPath = (Resolve-Path -LiteralPath $reportPath).Path
    ExtractedOrders = $orders.Count
}
