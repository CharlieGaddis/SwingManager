param(
    [Parameter(Mandatory=$true)][string]$TodayPath,
    [string]$PreviousPath = "",
    [string]$OutDir = ".\Analysis",
    [string]$StockAccount = "IRA",
    [string]$OptionAccount = "Living Trust",
    [decimal]$StockMaxCapital = 5000.00,
    [decimal]$DefaultOptionBudget = 2500.00
)

$ErrorActionPreference = "Stop"

function Read-JsonFile([string]$path) {
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Get-OptionKey($x) {
    if ($x.leg_group_id) { return [string]$x.leg_group_id }
    return "$($x.ticker)|$($x.contract_label)|$($x.structure)"
}

function Get-StockEntryOperator($row) {
    return "<="
}

function Get-StockShareQuantity([decimal]$maxCapital, [decimal]$limitPrice) {
    if ($limitPrice -le 0) { return 0 }
    $shares = [int][math]::Round(
        $maxCapital / $limitPrice,
        0,
        [System.MidpointRounding]::AwayFromZero)
    while ($shares -gt 0 -and (($shares * $limitPrice) -gt $maxCapital)) {
        $shares--
    }
    return $shares
}

function Get-OptionEntryOperator($row) {
    if ([string]$row.direction -eq "put") { return ">=" }
    return "<="
}

function Get-ProfitOperator([string]$direction) {
    if ($direction -eq "put") { return "<=" }
    return ">="
}

function Get-StopOperator([string]$direction) {
    if ($direction -eq "put") { return ">=" }
    return "<="
}

function New-MapByKey($items, [scriptblock]$keyFn) {
    $map = @{}
    foreach ($item in @($items)) {
        $map[(& $keyFn $item)] = $item
    }
    return $map
}

function Get-ChangedFields($oldItem, $newItem, [string[]]$fields) {
    $changed = @()
    foreach ($field in $fields) {
        if ([string]$oldItem.$field -ne [string]$newItem.$field) {
            $changed += "${field}: $($oldItem.$field) -> $($newItem.$field)"
        }
    }
    return $changed
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$today = Read-JsonFile $TodayPath
$previous = $null
if ($PreviousPath) {
    $previous = Read-JsonFile $PreviousPath
}

$optionBudget = $DefaultOptionBudget
if ($today.portfolio_options.budget_per_trade) {
    $optionBudget = [decimal]$today.portfolio_options.budget_per_trade
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($p in @($today.portfolio.pending)) {
    $limit = [decimal]$p.limit_price
    $shares = Get-StockShareQuantity $StockMaxCapital $limit
    $rows.Add([pscustomobject]@{
        Action = "PENDING_ENTRY_TRIGGER"
        Priority = "ENTRY"
        Account = $StockAccount
        Portfolio = "stock"
        AssetType = "stock"
        Key = [string]$p.ticker
        Ticker = [string]$p.ticker
        Structure = "long_stock"
        ContractLabel = ""
        Direction = "stock_long"
        TriggerSymbol = [string]$p.ticker
        TriggerOperator = Get-StockEntryOperator $p
        TriggerPrice = $limit
        EntryOrderIntent = "Submit real stock entry through Schwab/TOS API when trigger hits; then reconcile fill."
        Quantity = $shares
        MaxCapital = $StockMaxCapital
        EstimatedCost = [math]::Round($shares * $limit, 2)
        Stop = $p.stop
        T1 = $p.target
        T2 = $p.second_target
        DaysRemaining = $p.days_remaining
        NeedsBuyingPowerCheck = $true
        ReconcileAfterSend = $true
        ChangeNote = ""
    })
}

foreach ($p in @($today.portfolio_options.pending)) {
    $estimatedCost = $null
    if ($p.estimated_premium -and $p.contracts) {
        $estimatedCost = [math]::Round(([decimal]$p.estimated_premium) * ([decimal]$p.contracts) * 100, 2)
    }
    $rows.Add([pscustomobject]@{
        Action = "PENDING_ENTRY_TRIGGER"
        Priority = "ENTRY"
        Account = $OptionAccount
        Portfolio = "options"
        AssetType = "option"
        Key = Get-OptionKey $p
        Ticker = [string]$p.ticker
        Structure = [string]$p.structure
        ContractLabel = [string]$p.contract_label
        Direction = [string]$p.direction
        TriggerSymbol = [string]$p.ticker
        TriggerOperator = Get-OptionEntryOperator $p
        TriggerPrice = $p.stock_limit
        EntryOrderIntent = "Submit real option/spread entry through Schwab/TOS API when underlying trigger hits; then reconcile fill."
        Quantity = $p.contracts
        MaxCapital = $optionBudget
        EstimatedCost = $estimatedCost
        Stop = ""
        T1 = ""
        T2 = ""
        DaysRemaining = $p.days_remaining
        NeedsBuyingPowerCheck = $true
        ReconcileAfterSend = $true
        ChangeNote = ""
    })
}

foreach ($p in @($today.portfolio.active)) {
    $rows.Add([pscustomobject]@{
        Action = "EXPECTED_ACTIVE_OCO"
        Priority = "RECONCILE"
        Account = $StockAccount
        Portfolio = "stock"
        AssetType = "stock"
        Key = [string]$p.ticker
        Ticker = [string]$p.ticker
        Structure = "long_stock"
        ContractLabel = ""
        Direction = "stock_long"
        TriggerSymbol = [string]$p.ticker
        TriggerOperator = ""
        TriggerPrice = ""
        EntryOrderIntent = ""
        Quantity = ""
        MaxCapital = ""
        EstimatedCost = ""
        Stop = $p.stop
        T1 = $p.target
        T2 = $p.second_target
        DaysRemaining = ""
        NeedsBuyingPowerCheck = $false
        ReconcileAfterSend = $false
        ChangeNote = "Expected OCO: T1 $($p.target), T2 $($p.second_target), stop $($p.stop)."
    })
}

foreach ($p in @($today.portfolio_options.positions)) {
    $direction = [string]$p.direction
    $rows.Add([pscustomobject]@{
        Action = "EXPECTED_ACTIVE_OCO"
        Priority = "RECONCILE"
        Account = $OptionAccount
        Portfolio = "options"
        AssetType = "option"
        Key = Get-OptionKey $p
        Ticker = [string]$p.ticker
        Structure = [string]$p.structure
        ContractLabel = [string]$p.contract_label
        Direction = $direction
        TriggerSymbol = [string]$p.ticker
        TriggerOperator = ""
        TriggerPrice = ""
        EntryOrderIntent = ""
        Quantity = $p.contracts
        MaxCapital = ""
        EstimatedCost = ""
        Stop = $p.stock_stop
        T1 = $p.stock_target
        T2 = $p.stock_second_target
        DaysRemaining = ""
        NeedsBuyingPowerCheck = $false
        ReconcileAfterSend = $false
        ChangeNote = "Expected OCO: profit operator $(Get-ProfitOperator $direction), stop operator $(Get-StopOperator $direction). T1 $($p.stock_target), T2 $($p.stock_second_target), stop $($p.stock_stop)."
    })
}

if ($previous) {
    $oldStockActive = New-MapByKey $previous.portfolio.active { param($x) [string]$x.ticker }
    foreach ($p in @($today.portfolio.active)) {
        $key = [string]$p.ticker
        if (-not $oldStockActive.ContainsKey($key)) {
            $changeNote = "New active stock position; build initial OCO after confirming fill in TOS."
        } else {
            $changes = Get-ChangedFields $oldStockActive[$key] $p @("stop","target","second_target","partial_taken","size_multiple")
            if ($changes.Count -eq 0) { continue }
            $changeNote = $changes -join "; "
        }
        $rows.Add([pscustomobject]@{
            Action = "OCO_REVIEW_REQUIRED"
            Priority = "OCO_UPDATE"
            Account = $StockAccount
            Portfolio = "stock"
            AssetType = "stock"
            Key = $key
            Ticker = $key
            Structure = "long_stock"
            ContractLabel = ""
            Direction = "stock_long"
            TriggerSymbol = $key
            TriggerOperator = ""
            TriggerPrice = ""
            EntryOrderIntent = ""
            Quantity = ""
            MaxCapital = ""
            EstimatedCost = ""
            Stop = $p.stop
            T1 = $p.target
            T2 = $p.second_target
            DaysRemaining = ""
            NeedsBuyingPowerCheck = $false
            ReconcileAfterSend = $false
            ChangeNote = $changeNote
        })
    }

    $oldOptionPositions = New-MapByKey $previous.portfolio_options.positions ${function:Get-OptionKey}
    foreach ($p in @($today.portfolio_options.positions)) {
        $key = Get-OptionKey $p
        if (-not $oldOptionPositions.ContainsKey($key)) {
            $changeNote = "New active option position; build initial OCO after confirming fill in TOS."
        } else {
            $changes = Get-ChangedFields $oldOptionPositions[$key] $p @("stock_stop","stock_target","stock_second_target","contracts","t1_taken")
            if ($changes.Count -eq 0) { continue }
            $changeNote = $changes -join "; "
        }
        $rows.Add([pscustomobject]@{
            Action = "OCO_REVIEW_REQUIRED"
            Priority = "OCO_UPDATE"
            Account = $OptionAccount
            Portfolio = "options"
            AssetType = "option"
            Key = $key
            Ticker = [string]$p.ticker
            Structure = [string]$p.structure
            ContractLabel = [string]$p.contract_label
            Direction = [string]$p.direction
            TriggerSymbol = [string]$p.ticker
            TriggerOperator = ""
            TriggerPrice = ""
            EntryOrderIntent = ""
            Quantity = $p.contracts
            MaxCapital = ""
            EstimatedCost = ""
            Stop = $p.stock_stop
            T1 = $p.stock_target
            T2 = $p.stock_second_target
            DaysRemaining = ""
            NeedsBuyingPowerCheck = $false
            ReconcileAfterSend = $false
            ChangeNote = $changeNote
        })
    }
}

$stamp = $today.scan_date -replace "-", ""
$csvPath = Join-Path $OutDir "squeeze-action-queue-$stamp.csv"
$jsonPath = Join-Path $OutDir "squeeze-action-queue-$stamp.json"
$mdPath = Join-Path $OutDir "squeeze-action-queue-$stamp.md"

$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation
$rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$entryRows = @($rows | Where-Object Action -eq "PENDING_ENTRY_TRIGGER")
$activeRows = @($rows | Where-Object Action -eq "EXPECTED_ACTIVE_OCO")
$reviewRows = @($rows | Where-Object Action -eq "OCO_REVIEW_REQUIRED")

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Squeeze Action Queue $($today.scan_date)")
$md.Add("")
$md.Add("Generated from ``$TodayPath``.")
if ($PreviousPath) { $md.Add("Compared against ``$PreviousPath``.") }
$md.Add("")
$md.Add("## Summary")
$md.Add("- Pending entry triggers: $($entryRows.Count)")
$md.Add("- Expected active OCOs to reconcile in TOS: $($activeRows.Count)")
$md.Add("- OCO updates required from JSON diff: $($reviewRows.Count)")
$md.Add("")
$md.Add("## Pending Entry Triggers")
$md.Add(($entryRows | Select-Object Account,Portfolio,Ticker,Structure,ContractLabel,Direction,TriggerOperator,TriggerPrice,Quantity,MaxCapital,EstimatedCost,DaysRemaining | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
$md.Add("")
$md.Add("## OCO Updates Required")
if ($reviewRows.Count) {
    $md.Add(($reviewRows | Select-Object Account,Portfolio,Ticker,Structure,ContractLabel,Stop,T1,T2,ChangeNote | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
} else {
    $md.Add("No active OCO level updates were detected from the supplied JSON comparison.")
}
$md.Add("")
$md.Add("## Expected Active OCO Inventory")
$md.Add(($activeRows | Select-Object Account,Portfolio,Ticker,Structure,ContractLabel,Direction,Quantity,Stop,T1,T2,ChangeNote | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())

Set-Content -LiteralPath $mdPath -Value ($md -join [Environment]::NewLine) -Encoding UTF8

[pscustomobject]@{
    CsvPath = (Resolve-Path -LiteralPath $csvPath).Path
    JsonPath = (Resolve-Path -LiteralPath $jsonPath).Path
    MarkdownPath = (Resolve-Path -LiteralPath $mdPath).Path
    PendingEntryTriggers = $entryRows.Count
    ExpectedActiveOcos = $activeRows.Count
    OcoUpdatesRequired = $reviewRows.Count
}
