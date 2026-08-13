param(
    [string]$TradingDashboardBaseUrl = "http://127.0.0.1:5080",
    [string]$ActionQueuePath = ".\Analysis\squeeze-action-queue-20260811.csv",
    [string]$OutDir = ".\Analysis"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Mask-Account([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return "ACCOUNT" }
    $digits = ($value -replace '\D', '')
    if ($digits.Length -lt 4) { return "****" }
    return "****" + $digits.Substring($digits.Length - 4)
}

function Get-Balance($account, [string[]]$keys) {
    foreach ($source in @($account.currentBalances, $account.projectedBalances, $account.initialBalances, $account)) {
        if ($null -eq $source) { continue }
        foreach ($key in $keys) {
            if ($null -ne $source.$key -and [string]$source.$key -ne "") {
                return $source.$key
            }
        }
    }
    return $null
}

function Convert-DecimalOrNull($value) {
    if ($null -eq $value -or [string]$value -eq "") { return $null }
    try { return [decimal]$value } catch { return $null }
}

function Get-PositionSymbol($position) {
    if ($position.instrument.underlyingSymbol) { return [string]$position.instrument.underlyingSymbol }
    if ($position.instrument.symbol) { return [string]$position.instrument.symbol }
    return ""
}

$status = Invoke-RestMethod -Method Get -Uri "$TradingDashboardBaseUrl/api/schwab/status" -TimeoutSec 10
$rawAccounts = Invoke-RestMethod -Method Get -Uri "$TradingDashboardBaseUrl/api/schwab/accounts?positions=true" -TimeoutSec 20
$accounts = @($rawAccounts | ForEach-Object { if ($_.securitiesAccount) { $_.securitiesAccount } else { $_ } })

$expectedTickers = @()
if (Test-Path -LiteralPath $ActionQueuePath) {
    $expectedTickers = @(Import-Csv -LiteralPath $ActionQueuePath |
        Where-Object { $_.Ticker } |
        Select-Object -ExpandProperty Ticker -Unique)
}

$accountRows = foreach ($account in $accounts) {
    $availableFunds = Get-Balance $account @("availableFunds", "availableFundsNonMarginableTrade")
    $buyingPower = Get-Balance $account @("buyingPower", "buyingPowerNonMarginableTrade")
    [pscustomobject]@{
        AccountAlias = "$(Mask-Account $account.accountNumber) $($account.type)"
        AccountType = $account.type
        PositionCount = @($account.positions).Count
        AvailableFunds = $availableFunds
        BuyingPower = $buyingPower
        StockBuyingPower = Get-Balance $account @("stockBuyingPower", "buyingPower")
        OptionBuyingPowerProxy = $availableFunds
        CashBalance = Get-Balance $account @("cashBalance", "cashAvailableForTrading")
        LiquidationValue = Get-Balance $account @("liquidationValue", "accountValue")
        IsInCall = Get-Balance $account @("isInCall")
    }
}

$positionRows = foreach ($account in $accounts) {
    foreach ($position in @($account.positions)) {
        $symbol = Get-PositionSymbol $position
        if ($expectedTickers.Count -gt 0 -and $symbol -notin $expectedTickers) { continue }
        [pscustomobject]@{
            AccountAlias = "$(Mask-Account $account.accountNumber) $($account.type)"
            MatchedTicker = $symbol
            InstrumentSymbol = $position.instrument.symbol
            AssetType = $position.instrument.assetType
            PutCall = $position.instrument.putCall
            LongQuantity = $position.longQuantity
            ShortQuantity = $position.shortQuantity
            MarketValue = $position.marketValue
            AveragePrice = $position.averagePrice
            DayPL = $position.currentDayProfitLoss
        }
    }
}

$pendingRows = @()
if (Test-Path -LiteralPath $ActionQueuePath) {
    $pendingRows = @(Import-Csv -LiteralPath $ActionQueuePath |
        Where-Object { $_.Action -eq "PENDING_ENTRY_TRIGGER" } |
        ForEach-Object {
            $estimated = Convert-DecimalOrNull $_.EstimatedCost
            $max = Convert-DecimalOrNull $_.MaxCapital
            [pscustomobject]@{
                Account = $_.Account
                Portfolio = $_.Portfolio
                Ticker = $_.Ticker
                Structure = $_.Structure
                ContractLabel = $_.ContractLabel
                TriggerOperator = $_.TriggerOperator
                TriggerPrice = $_.TriggerPrice
                Quantity = $_.Quantity
                MaxCapital = $_.MaxCapital
                EstimatedCost = $_.EstimatedCost
                CapitalStatus = if ($null -ne $estimated -and $null -ne $max -and $estimated -gt $max) { "OVER_BUDGET_REVIEW" } else { "OK" }
                NeedsBuyingPowerCheck = $_.NeedsBuyingPowerCheck
            }
        })
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$accountsCsv = Join-Path $OutDir "schwab-sanitized-accounts-$stamp.csv"
$positionsCsv = Join-Path $OutDir "schwab-squeeze-position-matches-$stamp.csv"
$pendingCsv = Join-Path $OutDir "squeeze-pending-buying-power-preflight-$stamp.csv"
$reportPath = Join-Path $OutDir "schwab-swingmanager-snapshot-$stamp.md"

$accountRows | Export-Csv -LiteralPath $accountsCsv -NoTypeInformation
$positionRows | Export-Csv -LiteralPath $positionsCsv -NoTypeInformation
$pendingRows | Export-Csv -LiteralPath $pendingCsv -NoTypeInformation

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Schwab Snapshot For Swing Manager")
$md.Add("")
$md.Add("TradingDashboard status: connected=$($status.connected), accessTokenExpired=$($status.accessTokenExpired), orderCapability=$($status.orderCapability)")
$md.Add("")
$md.Add("## Sanitized Accounts")
$md.Add(($accountRows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd())
$md.Add("")
$md.Add("## Squeeze Ticker Positions Found")
if (@($positionRows).Count) {
    $md.Add(($positionRows | Sort-Object AccountAlias,MatchedTicker,AssetType,InstrumentSymbol | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
} else {
    $md.Add("No positions matched the current Squeeze action queue tickers.")
}
$md.Add("")
$md.Add("## Pending Buying-Power Worklist")
$md.Add("These are the orders Swing Manager should preflight against the mapped Schwab account before submitting an API entry order.")
$md.Add(($pendingRows | Select-Object Account,Portfolio,Ticker,Structure,ContractLabel,TriggerOperator,TriggerPrice,Quantity,MaxCapital,EstimatedCost,CapitalStatus | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())

Set-Content -LiteralPath $reportPath -Value ($md -join [Environment]::NewLine) -Encoding UTF8

[pscustomobject]@{
    ReportPath = (Resolve-Path -LiteralPath $reportPath).Path
    AccountsCsv = (Resolve-Path -LiteralPath $accountsCsv).Path
    PositionsCsv = (Resolve-Path -LiteralPath $positionsCsv).Path
    PendingPreflightCsv = (Resolve-Path -LiteralPath $pendingCsv).Path
    AccountCount = @($accountRows).Count
    MatchingPositions = @($positionRows).Count
    PendingPreflightRows = @($pendingRows).Count
}
