param(
    [string]$TradingDashboardBaseUrl = "http://127.0.0.1:5080",
    [string]$Status = "WORKING",
    [int]$DaysBack = 60,
    [int]$MaxResults = 3000,
    [string]$ActionQueuePath = ".\Analysis\squeeze-action-queue-20260811.csv",
    [string]$OutDir = ".\Analysis",
    [string]$IraAccountNumber = "",
    [string]$LivingTrustAccountNumber = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "tools\TosPrivacyRedactor.psm1") -Force

$machineConfigPath = Join-Path $PSScriptRoot "Config\machine.local.json"
$machineConfig = if (Test-Path -LiteralPath $machineConfigPath) {
    Get-Content -Raw -LiteralPath $machineConfigPath | ConvertFrom-Json
} else {
    $null
}
if ([string]::IsNullOrWhiteSpace($IraAccountNumber)) {
    $IraAccountNumber = $env:SWING_MANAGER_IRA_ACCOUNT_NUMBER
}
if ([string]::IsNullOrWhiteSpace($IraAccountNumber) -and $machineConfig) {
    $IraAccountNumber = [string]$machineConfig.iraAccountNumber
}
if ([string]::IsNullOrWhiteSpace($LivingTrustAccountNumber)) {
    $LivingTrustAccountNumber = $env:SWING_MANAGER_TRUST_ACCOUNT_NUMBER
}
if ([string]::IsNullOrWhiteSpace($LivingTrustAccountNumber) -and $machineConfig) {
    $LivingTrustAccountNumber = [string]$machineConfig.livingTrustAccountNumber
}
if ([string]::IsNullOrWhiteSpace($IraAccountNumber) -or
    [string]::IsNullOrWhiteSpace($LivingTrustAccountNumber)) {
    throw "Swing Manager account selectors are missing. Configure them in the ignored Config\machine.local.json file or the SWING_MANAGER account environment variables."
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Get-AccountEnding([string]$accountNumber) {
    if ([string]::IsNullOrWhiteSpace($accountNumber) -or $accountNumber.Length -lt 4) { return "" }
    return $accountNumber.Substring($accountNumber.Length - 4)
}

function ConvertTo-AccountSafeDiagnosticText([string]$text) {
    $safe = ConvertTo-TosSanitizedText $text
    $safe = [regex]::Replace($safe, '(?i)((?:"?accountNumber"?|AccountNumber|ExpectedAccountNumber)\s*[:=,]\s*"?)(\d{8})(?="|\b)', '${1}ACCOUNT_REDACTED')
    return $safe
}

function ConvertTo-SafeOrderRow($row) {
    $row | Select-Object `
        @{Name='AccountNumber';Expression={'ACCOUNT_REDACTED'}},
        @{Name='AccountEnding';Expression={Get-AccountEnding ([string]$_.AccountNumber)}},
        ParentOrderId,ParentStatus,ParentStrategy,EnteredTime,ChildOrderId,ChildStatus,OrderType,
        ComplexOrderStrategyType,Duration,Quantity,RemainingQuantity,Underlying,Price,PriceLinkBasis,
        PriceLinkType,PriceOffset,StopPrice,StopPriceLinkBasis,StopPriceLinkType,StopPriceOffset,
        StopType,LegSummary,ConditionalTriggerFromApi
}
function Get-FirstLeg($order) {
    if ($order.orderLegCollection -and @($order.orderLegCollection).Count -gt 0) {
        return @($order.orderLegCollection)[0]
    }
    return $null
}

function Get-Underlying($order) {
    $leg = Get-FirstLeg $order
    if ($leg -and $leg.instrument) {
        if ($leg.instrument.underlyingSymbol) { return [string]$leg.instrument.underlyingSymbol }
        if ($leg.instrument.symbol) { return ([string]$leg.instrument.symbol).Trim().Split(" ")[0] }
    }
    return ""
}

function Get-LegSummary($order) {
    $parts = foreach ($leg in @($order.orderLegCollection)) {
        $symbol = if ($leg.instrument.symbol) { ([string]$leg.instrument.symbol).Trim() } else { "" }
        "$($leg.instruction) $($leg.quantity) $symbol"
    }
    return ($parts -join "; ")
}

function Flatten-OrderTree($parent) {
    $children = @($parent.childOrderStrategies)
    if ($children.Count -eq 0) { $children = @($parent) }
    foreach ($child in $children) {
        [pscustomobject]@{
            AccountNumber = $parent.accountNumber
            ParentOrderId = $parent.orderId
            ParentStatus = $parent.status
            ParentStrategy = $parent.orderStrategyType
            EnteredTime = $parent.enteredTime
            ChildOrderId = $child.orderId
            ChildStatus = $child.status
            OrderType = $child.orderType
            ComplexOrderStrategyType = $child.complexOrderStrategyType
            Duration = $child.duration
            Quantity = $child.quantity
            RemainingQuantity = $child.remainingQuantity
            Underlying = Get-Underlying $child
            Price = $child.price
            PriceLinkBasis = $child.priceLinkBasis
            PriceLinkType = $child.priceLinkType
            PriceOffset = $child.priceOffset
            StopPrice = $child.stopPrice
            StopPriceLinkBasis = $child.stopPriceLinkBasis
            StopPriceLinkType = $child.stopPriceLinkType
            StopPriceOffset = $child.stopPriceOffset
            StopType = $child.stopType
            LegSummary = Get-LegSummary $child
            ConditionalTriggerFromApi = "API_NOT_RETURNED"
        }
    }
}

function Convert-DecimalOrNull($value) {
    if ($null -eq $value -or [string]$value -eq "") { return $null }
    try { return [decimal]$value } catch { return $null }
}

function Test-HasOrderType($orders, [string]$type) {
    return @($orders | Where-Object { $_.OrderType -eq $type }).Count -gt 0
}

function Test-HasTargetOrder($orders) {
    return @($orders | Where-Object { $_.OrderType -in @("LIMIT", "NET_CREDIT", "NET_DEBIT") }).Count -gt 0
}

function Get-ExpectedAccountNumber($accountName) {
    switch ([string]$accountName) {
        "IRA" { return $IraAccountNumber }
        "Living Trust" { return $LivingTrustAccountNumber }
        default { return "" }
    }
}

$uri = "$TradingDashboardBaseUrl/api/schwab/orders?status=$([uri]::EscapeDataString($Status))&daysBack=$DaysBack&maxResults=$MaxResults"
$ordersResponse = @(Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 60)
$orders = if ($ordersResponse.Count -eq 1 -and $ordersResponse[0] -is [array]) {
    @($ordersResponse[0])
} else {
    @($ordersResponse)
}
$rows = foreach ($order in $orders) { Flatten-OrderTree $order }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$rawPath = Join-Path $OutDir "schwab-working-orders-api-raw-$stamp.json"
$rowsPath = Join-Path $OutDir "schwab-working-orders-api-rows-$stamp.csv"
$reconPath = Join-Path $OutDir "schwab-working-orders-api-reconciliation-$stamp.csv"
$reportPath = Join-Path $OutDir "schwab-working-orders-api-report-$stamp.md"

$safeOrdersJson = ConvertTo-AccountSafeDiagnosticText ($orders | ConvertTo-Json -Depth 50)
$safeOrdersJson | Set-Content -LiteralPath $rawPath -Encoding UTF8
$safeRows = @($rows | ForEach-Object { ConvertTo-SafeOrderRow $_ })
$safeRows | Export-Csv -LiteralPath $rowsPath -NoTypeInformation

$reconRows = @()
if (Test-Path -LiteralPath $ActionQueuePath) {
    $expected = @(Import-Csv -LiteralPath $ActionQueuePath | Where-Object { $_.Action -eq "EXPECTED_ACTIVE_OCO" })
    $reconRows = foreach ($item in $expected) {
        $expectedAccountNumber = Get-ExpectedAccountNumber $item.Account
        $matches = @($rows | Where-Object {
            $_.Underlying -eq $item.Ticker `
                -and $_.ParentStatus -eq "WORKING" `
                -and ([string]$_.AccountNumber -eq [string]$expectedAccountNumber)
        })
        $hasTarget = Test-HasTargetOrder $matches
        $hasStop = Test-HasOrderType $matches "STOP"
        [pscustomobject]@{
            Account = $item.Account
            ExpectedAccountNumber = "ACCOUNT_REDACTED"
            ExpectedAccountEnding = Get-AccountEnding $expectedAccountNumber
            Portfolio = $item.Portfolio
            Ticker = $item.Ticker
            ContractLabel = $item.ContractLabel
            ExpectedStop = $item.Stop
            ExpectedT1 = $item.T1
            ExpectedT2 = $item.T2
            ApiWorkingChildRows = $matches.Count
            ApiTargetChildren = @($matches | Where-Object { $_.OrderType -in @("LIMIT", "NET_CREDIT", "NET_DEBIT") }).Count
            ApiStopChildren = @($matches | Where-Object OrderType -eq "STOP").Count
            ApiParentOcoIds = (($matches | Select-Object -ExpandProperty ParentOrderId -Unique) -join ", ")
            ApiStopPrices = (($matches | Where-Object { $_.StopPrice -or $_.StopPriceOffset -ne $null } | ForEach-Object {
                if ($_.StopPrice) { $_.StopPrice } else { "$($_.StopPriceLinkBasis)+$($_.StopPriceOffset)" }
            } | Select-Object -Unique) -join ", ")
            ApiConditionThresholds = "API_NOT_RETURNED"
            ApiInventoryStatus =
                if ($matches.Count -eq 0) { "NO_WORKING_ORDER_FOUND_BY_API" }
                elseif ($hasTarget -and $hasStop) { "OCO_STRUCTURE_FOUND_CONDITION_LEVELS_NOT_RETURNED" }
                elseif ($hasTarget) { "TARGET_FOUND_STOP_MISSING" }
                elseif ($hasStop) { "STOP_FOUND_TARGET_MISSING" }
                else { "WORKING_ORDER_FOUND_UNCLASSIFIED" }
        }
    }
    $safeReconRows = @($reconRows | ForEach-Object { $_ })
$safeReconRows | Export-Csv -LiteralPath $reconPath -NoTypeInformation
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Schwab API Working Orders")
$md.Add("")
$md.Add("Endpoint: ``$uri``")
$md.Add("")
$md.Add("## Summary")
$md.Add("- Parent orders returned: $(@($orders).Count)")
$md.Add("- Flattened child/order rows: $(@($rows).Count)")
$md.Add("")
$md.Add("## Working Order Rows")
$md.Add(($safeRows | Select-Object AccountNumber,AccountEnding,ParentOrderId,ParentStatus,ParentStrategy,ChildOrderId,ChildStatus,OrderType,ComplexOrderStrategyType,Duration,Quantity,Underlying,Price,PriceLinkBasis,PriceOffset,StopPrice,StopPriceLinkBasis,StopPriceOffset,StopType,ConditionalTriggerFromApi | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())

if (@($reconRows).Count) {
    $md.Add("")
    $md.Add("## Squeeze OCO Inventory Reconciliation")
    $md.Add(($reconRows | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())
}

$safeReport = ConvertTo-AccountSafeDiagnosticText ($md -join [Environment]::NewLine)
Set-Content -LiteralPath $reportPath -Value $safeReport -Encoding UTF8

[pscustomobject]@{
    ReportPath = (Resolve-Path -LiteralPath $reportPath).Path
    RawPath = (Resolve-Path -LiteralPath $rawPath).Path
    RowsPath = (Resolve-Path -LiteralPath $rowsPath).Path
    ReconciliationPath = if (Test-Path -LiteralPath $reconPath) { (Resolve-Path -LiteralPath $reconPath).Path } else { "" }
    ParentOrders = @($orders).Count
    FlattenedRows = @($rows).Count
}
