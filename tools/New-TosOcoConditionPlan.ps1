param(
    [Parameter(Mandatory = $true)]
    [string]$Symbol,
    [Parameter(Mandatory = $true)]
    [int]$TotalQuantity,
    [Parameter(Mandatory = $true)]
    [decimal]$Target1,
    [Parameter(Mandatory = $true)]
    [decimal]$Target2,
    [Parameter(Mandatory = $true)]
    [decimal]$Stop,
    [string]$ConditionMethod = "MARK",
    [string]$OrderPriceLink = "MARK",
    [decimal]$OrderPriceOffset = 0,
    [string]$TimeInForce = "GTC",
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-oco-condition-plan.csv"
)

$ErrorActionPreference = "Stop"

if ($TotalQuantity -eq 0) {
    throw "TotalQuantity cannot be zero."
}

$closingSide = if ($TotalQuantity -gt 0) { "SELL" } else { "BUY" }
$absQuantity = [Math]::Abs($TotalQuantity)

if ($absQuantity -lt 2) {
    throw "OCO split requires at least quantity 2. Received $absQuantity."
}

$t1Quantity = [Math]::Floor($absQuantity / 2)
$t2Quantity = $absQuantity - $t1Quantity

function New-PlanRow {
    param(
        [string]$Leg,
        [string]$OrderRole,
        [int]$Quantity,
        [string]$ConditionType,
        [decimal]$Threshold,
        [string]$OrderPriceRule
    )

    $trigger = switch ($ConditionType) {
        "Target" { ">=" }
        "Stop" { "<=" }
        default { throw "Unsupported condition type $ConditionType" }
    }

    [pscustomobject]@{
        Symbol = $Symbol.ToUpperInvariant()
        Leg = $Leg
        ClosingSide = $closingSide
        Quantity = $Quantity
        OrderRole = $OrderRole
        OrderPriceRule = $OrderPriceRule
        OrderPriceLink = $OrderPriceLink
        OrderPriceOffset = $OrderPriceOffset
        TimeInForce = $TimeInForce
        ConditionMethod = $ConditionMethod
        ConditionType = $ConditionType
        Trigger = $trigger
        Threshold = $Threshold
        TosOrderPrice = "$OrderPriceRule linked to $OrderPriceLink + $OrderPriceOffset"
        TosCondition = "$($Symbol.ToUpperInvariant()) $ConditionMethod $trigger $Threshold"
        Notes = if ($OrderRole -eq "ProfitTarget") { "Profit target: GTC limit order priced from option MARK, triggered by underlying target." } else { "Stop loss: GTC stop order priced from option MARK, triggered by underlying stop." }
    }
}

$rows = @(
    New-PlanRow -Leg "T1" -OrderRole "ProfitTarget" -Quantity $t1Quantity -ConditionType "Target" -Threshold $Target1 -OrderPriceRule "LIMIT"
    New-PlanRow -Leg "T1" -OrderRole "StopLoss" -Quantity $t1Quantity -ConditionType "Stop" -Threshold $Stop -OrderPriceRule "STOP"
    New-PlanRow -Leg "T2" -OrderRole "ProfitTarget" -Quantity $t2Quantity -ConditionType "Target" -Threshold $Target2 -OrderPriceRule "LIMIT"
    New-PlanRow -Leg "T2" -OrderRole "StopLoss" -Quantity $t2Quantity -ConditionType "Stop" -Threshold $Stop -OrderPriceRule "STOP"
)

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$rows | Format-Table -AutoSize
Write-Host "Wrote OCO condition plan to $OutFile"
