param(
    [Parameter(Mandatory=$true)][string]$TodayPath,
    [string]$PreviousPath = "",
    [string]$TradingDashboardBaseUrl = "http://127.0.0.1:5080",
    [string]$OutDir = ".\Analysis",
    [string]$TosReconciliationPath = "",
    [string]$ExceptionRegistryPath = ".\Config\swing-oco-exceptions.csv",
    [decimal]$StockMaxCapital = 5000.00,
    [decimal]$DefaultOptionBudget = 2500.00,
    [string]$IraAccountNumber = "68885682",
    [string]$LivingTrustAccountNumber = "86119157"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Get-ScriptPath([string]$name) {
    return Join-Path $PSScriptRoot $name
}

function Import-CsvIfExists([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return @()
    }
    return @(Import-Csv -LiteralPath $path)
}

function Convert-NumberOrNull($value) {
    if ($null -eq $value -or [string]$value -eq "") { return $null }
    try { return [decimal]$value } catch { return $null }
}

function Test-ChangedLevel($expectedValue, $visibleValues, [decimal]$tolerance = 0.01) {
    $expected = Convert-NumberOrNull $expectedValue
    if ($null -eq $expected) { return $false }
    foreach ($value in @($visibleValues -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $actual = Convert-NumberOrNull $value
        if ($null -ne $actual -and [math]::Abs($actual - $expected) -le $tolerance) {
            return $false
        }
    }
    return $true
}

function Get-MissingLevelNames($tosStatus) {
    $names = @()
    $text = [string]$tosStatus
    if ($text -match "STOP") { $names += "Stop" }
    if ($text -match "T1") { $names += "T1" }
    if ($text -match "T2") { $names += "T2" }
    return $names
}

function Get-UpdateLevelRows($worklistRows) {
    foreach ($row in @($worklistRows | Where-Object { $_.Priority -in @("UPDATE_OCO", "BUILD_OCO", "JSON_CHANGED") })) {
        $levels = Get-MissingLevelNames $row.Status
        if ($levels.Count -eq 0 -or $row.Priority -in @("BUILD_OCO", "JSON_CHANGED")) {
            $levels = @("Stop", "T1", "T2")
        }
        foreach ($level in $levels) {
            $expected = switch ($level) {
                "Stop" { $row.Stop }
                "T1" { $row.T1 }
                "T2" { $row.T2 }
            }
            $conditionType = if ($level -eq "Stop") { "Stop" } else { "Target" }
            [pscustomobject]@{
                Account = $row.Account
                Portfolio = $row.Portfolio
                Ticker = $row.Ticker
                ContractLabel = $row.ContractLabel
                Direction = $row.Direction
                Quantity = $row.Quantity
                Level = $level
                ConditionType = $conditionType
                ExpectedThreshold = $expected
                SourcePriority = $row.Priority
                SourceStatus = $row.Status
                ExecutionStatus = "Ready"
                Notes = "Open the matching TOS Order Rules window for this $level leg, set underlying MARK condition to $expected, save only after visual verification."
            }
        }
    }
}

function Get-ExpectedAccountNumber([string]$accountName) {
    switch ($accountName) {
        "IRA" { return $IraAccountNumber }
        "Living Trust" { return $LivingTrustAccountNumber }
        default { return "" }
    }
}

function Get-ExceptionKey($row) {
    return "$($row.Account)|$($row.Portfolio)|$($row.Ticker)|$($row.ContractLabel)"
}

function Get-ExistingExceptionMap([string]$path) {
    $map = @{}
    foreach ($row in (Import-CsvIfExists $path)) {
        $map[(Get-ExceptionKey $row)] = $row
    }
    return $map
}

$queueArgs = @{
    TodayPath = $TodayPath
    OutDir = $OutDir
    StockMaxCapital = $StockMaxCapital
    DefaultOptionBudget = $DefaultOptionBudget
}
if ($PreviousPath) {
    $queueArgs.PreviousPath = $PreviousPath
}

$queueResult = & (Get-ScriptPath "Build-SqueezeActionQueue.ps1") @queueArgs

$schwabResult = & (Get-ScriptPath "Get-SchwabWorkingOrdersForSwingManager.ps1") `
    -TradingDashboardBaseUrl $TradingDashboardBaseUrl `
    -Status "WORKING" `
    -DaysBack 60 `
    -MaxResults 3000 `
    -ActionQueuePath $queueResult.CsvPath `
    -OutDir $OutDir `
    -IraAccountNumber $IraAccountNumber `
    -LivingTrustAccountNumber $LivingTrustAccountNumber

$queueRows = Import-CsvIfExists $queueResult.CsvPath
$apiReconRows = Import-CsvIfExists $schwabResult.ReconciliationPath
$tosReconRows = Import-CsvIfExists $TosReconciliationPath
$exceptionMap = Get-ExistingExceptionMap $ExceptionRegistryPath

$apiByKey = @{}
foreach ($row in $apiReconRows) {
    $apiByKey["$($row.Account)|$($row.Portfolio)|$($row.Ticker)|$($row.ContractLabel)"] = $row
}

$tosByKey = @{}
foreach ($row in $tosReconRows) {
    $tosByKey["$($row.Account)|$($row.Portfolio)|$($row.Ticker)|$($row.ContractLabel)"] = $row
}

$worklist = New-Object System.Collections.Generic.List[object]

foreach ($entry in @($queueRows | Where-Object { $_.Action -eq "PENDING_ENTRY_TRIGGER" })) {
    $worklist.Add([pscustomobject]@{
        Priority = "ENTRY_MONITOR"
        Action = "WATCH_AND_SUBMIT_ENTRY"
        Account = $entry.Account
        ExpectedAccountNumber = Get-ExpectedAccountNumber $entry.Account
        Portfolio = $entry.Portfolio
        Ticker = $entry.Ticker
        ContractLabel = $entry.ContractLabel
        Direction = $entry.Direction
        Trigger = "$($entry.TriggerSymbol) $($entry.TriggerOperator) $($entry.TriggerPrice)"
        Stop = $entry.Stop
        T1 = $entry.T1
        T2 = $entry.T2
        Quantity = $entry.Quantity
        Status = "MONITOR_IN_SWING_MANAGER"
        Detail = $entry.EntryOrderIntent
    }) | Out-Null
}

foreach ($expected in @($queueRows | Where-Object { $_.Action -eq "EXPECTED_ACTIVE_OCO" })) {
    $key = "$($expected.Account)|$($expected.Portfolio)|$($expected.Ticker)|$($expected.ContractLabel)"
    $api = $apiByKey[$key]
    $tos = $tosByKey[$key]

    $priority = "JAB_REVIEW"
    $action = "INSPECT_TOS_CONDITIONAL_LEVELS"
    $status = "API_NOT_CHECKED"
    $detail = "Use TOS/JAB to verify T1 $($expected.T1), T2 $($expected.T2), stop $($expected.Stop)."

    if ($api) {
        $status = $api.ApiInventoryStatus
        if ($api.ApiInventoryStatus -eq "NO_WORKING_ORDER_FOUND_BY_API") {
            $priority = "MISSING_OCO"
            $action = "LOCATE_OR_BUILD_OCO"
            $detail = "Schwab API did not find a working OCO inventory match. Confirm position/order state in TOS."
        } elseif ($api.ApiInventoryStatus -like "OCO_STRUCTURE_FOUND*") {
            $priority = "JAB_REVIEW"
            $action = "INSPECT_TOS_CONDITIONAL_LEVELS"
            $detail = "Schwab API found OCO structure, but conditional trigger levels are not returned by API."
        } else {
            $priority = "ORDER_STRUCTURE_REVIEW"
            $action = "REVIEW_OCO_STRUCTURE"
            $detail = "Schwab API found working orders but the OCO target/stop structure needs review."
        }
    }

    if ($tos) {
        $status = $tos.ReconcileStatus
        if ($tos.ReconcileStatus -eq "MATCHED_EXPECTED_LEVELS") {
            $priority = "OK"
            $action = "NO_CHANGE"
            $detail = "TOS/JAB visible conditional levels match the JSON targets and stop."
        } elseif ($tos.ReconcileStatus -like "REVIEW*") {
            $priority = "UPDATE_OCO"
            $action = "UPDATE_TOS_CONDITIONAL_LEVELS"
            $detail = "TOS/JAB found an OCO, but one or more visible conditional levels do not match the JSON."
        } elseif ($tos.ReconcileStatus -eq "NOT_VISIBLE_IN_CURRENT_VIEW") {
            $priority = "LOCATE_IN_TOS"
            $action = "OPEN_WORKING_ORDER_AND_INSPECT"
            $detail = "Not visible in current TOS/JAB tree. Expand or locate the order in TOS, then inspect condition levels."
        }
    }

    $worklist.Add([pscustomobject]@{
        Priority = $priority
        Action = $action
        Account = $expected.Account
        ExpectedAccountNumber = Get-ExpectedAccountNumber $expected.Account
        Portfolio = $expected.Portfolio
        Ticker = $expected.Ticker
        ContractLabel = $expected.ContractLabel
        Direction = $expected.Direction
        Trigger = ""
        Stop = $expected.Stop
        T1 = $expected.T1
        T2 = $expected.T2
        Quantity = $expected.Quantity
        Status = $status
        Detail = $detail
    }) | Out-Null
}

foreach ($update in @($queueRows | Where-Object { $_.Action -eq "OCO_REVIEW_REQUIRED" })) {
    $worklist.Add([pscustomobject]@{
        Priority = "JSON_CHANGED"
        Action = "QUEUE_OCO_UPDATE_FROM_JSON_DIFF"
        Account = $update.Account
        ExpectedAccountNumber = Get-ExpectedAccountNumber $update.Account
        Portfolio = $update.Portfolio
        Ticker = $update.Ticker
        ContractLabel = $update.ContractLabel
        Direction = $update.Direction
        Trigger = ""
        Stop = $update.Stop
        T1 = $update.T1
        T2 = $update.T2
        Quantity = $update.Quantity
        Status = "JSON_DIFF_REQUIRES_REVIEW"
        Detail = $update.ChangeNote
    }) | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$worklistCsv = Join-Path $OutDir "swing-nightly-worklist-$stamp.csv"
$worklistMd = Join-Path $OutDir "swing-nightly-worklist-$stamp.md"

$resolvedWorklist = foreach ($row in $worklist) {
    $existingException = $exceptionMap[(Get-ExceptionKey $row)]
    $exceptionDecision = if ($existingException) { [string]$existingException.Decision } else { "" }
    $effectivePriority = [string]$row.Priority
    $effectiveAction = [string]$row.Action
    $effectiveDetail = [string]$row.Detail

    if ($exceptionDecision -eq "Ignore" -and $row.Priority -in @("MISSING_OCO", "LOCATE_IN_TOS")) {
        $effectivePriority = "IGNORED_EXCEPTION"
        $effectiveAction = "NO_CHANGE"
        $effectiveDetail = "User exception registry marks this missing/locate item as Ignore. Original detail: $($row.Detail)"
    } elseif ($exceptionDecision -eq "Add" -and $row.Priority -in @("MISSING_OCO", "LOCATE_IN_TOS")) {
        $effectivePriority = "BUILD_OCO"
        $effectiveAction = "BUILD_MISSING_OCO_FROM_JSON"
        $effectiveDetail = "User exception registry marks this item as Add. Build or repair the TOS OCO from JSON levels."
    }

    [pscustomobject]@{
        Priority = $effectivePriority
        Action = $effectiveAction
        Account = $row.Account
        ExpectedAccountNumber = $row.ExpectedAccountNumber
        Portfolio = $row.Portfolio
        Ticker = $row.Ticker
        ContractLabel = $row.ContractLabel
        Direction = $row.Direction
        Trigger = $row.Trigger
        Stop = $row.Stop
        T1 = $row.T1
        T2 = $row.T2
        Quantity = $row.Quantity
        Status = $row.Status
        ExceptionDecision = $exceptionDecision
        Detail = $effectiveDetail
    }
}

$resolvedWorklist | Export-Csv -LiteralPath $worklistCsv -NoTypeInformation

$exceptionRows = @($resolvedWorklist | Where-Object { $_.Priority -in @("MISSING_OCO", "LOCATE_IN_TOS", "BUILD_OCO") })
$updateRows = @($resolvedWorklist | Where-Object { $_.Priority -in @("UPDATE_OCO", "BUILD_OCO", "JSON_CHANGED") })
$updateLevelRows = @(Get-UpdateLevelRows $resolvedWorklist)
$exceptionsCsv = Join-Path $OutDir "swing-oco-exceptions-review-$stamp.csv"
$updatesCsv = Join-Path $OutDir "swing-oco-update-queue-$stamp.csv"
$updateLevelsCsv = Join-Path $OutDir "swing-oco-update-levels-$stamp.csv"
$exceptionRows | Select-Object Account,Portfolio,Ticker,ContractLabel,Direction,Quantity,Stop,T1,T2,Priority,Action,Status,ExceptionDecision,Detail | Export-Csv -LiteralPath $exceptionsCsv -NoTypeInformation
$updateRows | Select-Object Account,Portfolio,Ticker,ContractLabel,Direction,Quantity,Stop,T1,T2,Priority,Action,Status,ExceptionDecision,Detail | Export-Csv -LiteralPath $updatesCsv -NoTypeInformation
$updateLevelRows | Export-Csv -LiteralPath $updateLevelsCsv -NoTypeInformation

if ($exceptionRows.Count -gt 0) {
    $registryDir = Split-Path -Parent $ExceptionRegistryPath
    if ($registryDir -and -not (Test-Path -LiteralPath $registryDir)) {
        New-Item -ItemType Directory -Path $registryDir | Out-Null
    }

    $registryRows = foreach ($row in $exceptionRows) {
        $existing = $exceptionMap[(Get-ExceptionKey $row)]
        [pscustomobject]@{
            Account = $row.Account
            Portfolio = $row.Portfolio
            Ticker = $row.Ticker
            ContractLabel = $row.ContractLabel
            Direction = $row.Direction
            Quantity = $row.Quantity
            Stop = $row.Stop
            T1 = $row.T1
            T2 = $row.T2
            Decision = if ($existing -and $existing.Decision) { $existing.Decision } else { "Review" }
            Notes = if ($existing) { $existing.Notes } else { "" }
            LastPriority = $row.Priority
            LastAction = $row.Action
            LastStatus = $row.Status
            LastSeen = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    $registryRows | Export-Csv -LiteralPath $ExceptionRegistryPath -NoTypeInformation
}

$priorityOrder = @{
    "MISSING_OCO" = 1
    "UPDATE_OCO" = 2
    "JSON_CHANGED" = 3
    "ORDER_STRUCTURE_REVIEW" = 4
    "LOCATE_IN_TOS" = 5
    "JAB_REVIEW" = 6
    "ENTRY_MONITOR" = 7
    "OK" = 8
}

$sortedWorklist = @($resolvedWorklist | Sort-Object @{ Expression = { if ($priorityOrder.ContainsKey($_.Priority)) { $priorityOrder[$_.Priority] } else { 99 } } }, Account, Ticker, ContractLabel)

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Swing Manager Nightly Worklist")
$md.Add("")
$md.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("")
$md.Add("## Inputs")
$md.Add("- Today JSON: ``$TodayPath``")
if ($PreviousPath) { $md.Add("- Previous JSON: ``$PreviousPath``") }
$md.Add("- Action queue: ``$($queueResult.CsvPath)``")
$md.Add("- Schwab API reconciliation: ``$($schwabResult.ReconciliationPath)``")
if ($TosReconciliationPath) { $md.Add("- TOS/JAB reconciliation: ``$TosReconciliationPath``") }
$md.Add("")
$md.Add("## Summary")
$md.Add("- Pending entry triggers: $($queueResult.PendingEntryTriggers)")
$md.Add("- Expected active OCOs: $($queueResult.ExpectedActiveOcos)")
$md.Add("- JSON diff OCO updates: $($queueResult.OcoUpdatesRequired)")
$md.Add("- Schwab parent working orders returned: $($schwabResult.ParentOrders)")
$md.Add("- Schwab flattened order rows returned: $($schwabResult.FlattenedRows)")
$md.Add("- Exception review rows: $($exceptionRows.Count)")
$md.Add("- OCO update queue rows: $($updateRows.Count)")
$md.Add("- Individual OCO level updates: $($updateLevelRows.Count)")
$md.Add("")
$md.Add("## Review Files")
$md.Add("- Missing/locate exceptions: ``$exceptionsCsv``")
$md.Add("- OCO update queue: ``$updatesCsv``")
$md.Add("- Individual OCO level updates: ``$updateLevelsCsv``")
$md.Add("- Exception registry: ``$ExceptionRegistryPath``")
$md.Add("")
$md.Add("## Prioritized Worklist")
$md.Add(($sortedWorklist | Select-Object Priority,Action,Account,Portfolio,Ticker,ContractLabel,Direction,Trigger,Stop,T1,T2,Quantity,Status,ExceptionDecision,Detail | Format-Table -AutoSize | Out-String -Width 340).TrimEnd())

Set-Content -LiteralPath $worklistMd -Value ($md -join [Environment]::NewLine) -Encoding UTF8

[pscustomobject]@{
    WorklistCsv = (Resolve-Path -LiteralPath $worklistCsv).Path
    WorklistMarkdown = (Resolve-Path -LiteralPath $worklistMd).Path
    ExceptionsReviewCsv = (Resolve-Path -LiteralPath $exceptionsCsv).Path
    OcoUpdateQueueCsv = (Resolve-Path -LiteralPath $updatesCsv).Path
    OcoUpdateLevelsCsv = (Resolve-Path -LiteralPath $updateLevelsCsv).Path
    ExceptionRegistry = if (Test-Path -LiteralPath $ExceptionRegistryPath) { (Resolve-Path -LiteralPath $ExceptionRegistryPath).Path } else { "" }
    ActionQueue = $queueResult.CsvPath
    SchwabApiReconciliation = $schwabResult.ReconciliationPath
    PendingEntryTriggers = $queueResult.PendingEntryTriggers
    ExpectedActiveOcos = $queueResult.ExpectedActiveOcos
    JsonDiffOcoUpdates = $queueResult.OcoUpdatesRequired
    SchwabParentOrders = $schwabResult.ParentOrders
    SchwabFlattenedRows = $schwabResult.FlattenedRows
    ExceptionReviewRows = $exceptionRows.Count
    OcoUpdateQueueRows = $updateRows.Count
    OcoUpdateLevelRows = $updateLevelRows.Count
}
