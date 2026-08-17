param(
    [string]$VisibleOrdersCsv = "$PSScriptRoot\..\Analysis\tos-visible-working-orders-20260814-085707.csv",
    [string]$ReconciliationCsv = "$PSScriptRoot\..\Analysis\tos-oco-reconciliation-20260814-085707.csv",
    [string]$SnapshotJson = "",
    [string]$Symbol = "",
    [string]$TargetAccount = "",
    [decimal]$Tolerance = 0.005,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TosPrivacyRedactor.psm1") -Force

if (-not (Test-Path -LiteralPath $VisibleOrdersCsv)) { throw "Visible orders CSV not found: $VisibleOrdersCsv" }
if (-not (Test-Path -LiteralPath $ReconciliationCsv)) { throw "Reconciliation CSV not found: $ReconciliationCsv" }
if (-not [string]::IsNullOrWhiteSpace($SnapshotJson) -and -not (Test-Path -LiteralPath $SnapshotJson)) { throw "Snapshot JSON not found: $SnapshotJson" }

$visible = @(Import-Csv -LiteralPath $VisibleOrdersCsv)
$recon = @(Import-Csv -LiteralPath $ReconciliationCsv)
$snapshotNodes = @()
if (-not [string]::IsNullOrWhiteSpace($SnapshotJson)) {
    $snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
    $snapshotNodes = @($snapshot.nodes)
}

function To-NullableDecimal {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $parsed = [decimal]0
    if ([decimal]::TryParse($text, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Normalize-TosAccountAlias {
    param([string]$Alias)
    $text = ([string]$Alias).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    if ($text -match '(?i)\bIRA\b|Rollover IRA') { return "IRA" }
    if ($text -match '(?i)Living Trust') { return "Living Trust" }
    return $text
}

function Get-ExpectedAccountEnding {
    param([string]$Alias)
    $normalized = Normalize-TosAccountAlias $Alias
    if ($normalized -eq "IRA") { return "5682" }
    if ($normalized -eq "Living Trust") { return "9157" }
    return ""
}

function Get-ReplacingOrderId {
    param([string]$RawOrder)
    if ([string]::IsNullOrWhiteSpace($RawOrder)) { return "" }
    $m = [regex]::Match($RawOrder, '\(Replacing #(?<id>\d+)\)')
    if ($m.Success) { return $m.Groups['id'].Value }
    return ""
}

function Get-InstrumentLabel {
    param([string]$RawOrder, [string]$ConditionSymbol)
    if ([string]::IsNullOrWhiteSpace($RawOrder) -or [string]::IsNullOrWhiteSpace($ConditionSymbol)) { return "" }
    $pattern = "\b" + [regex]::Escape($ConditionSymbol) + "\b\s+100\s+(?<exp>\d{1,2}\s+[A-Z]{3}\s+\d{2})\s+(?<strike>[0-9.]+(?:/[0-9.]+)?)\s+(?<type>CALL|PUT)"
    $m = [regex]::Match($RawOrder, $pattern)
    if ($m.Success) {
        $exp = $m.Groups['exp'].Value
        $strike = $m.Groups['strike'].Value
        $type = if ($m.Groups['type'].Value -eq 'CALL') { 'C' } else { 'P' }
        return "$strike$type $exp"
    }
    return ""
}
function Get-TosAccountContext {
    if ($snapshotNodes.Count -eq 0) {
        return [pscustomobject]@{ Number = ''; Ending = ''; Alias = ''; Label = ''; Source = 'no_snapshot' }
    }

    $accountNodes = @($snapshotNodes | Where-Object {
        $_.role -eq 'label' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
        [string]$_.name -match '^(?<number>\d{8}|ACCOUNT_REDACTED)SCHW\s+\((?<alias>[^)]+)\)' -and
        [int]$_.bounds.x -ge 0 -and [int]$_.bounds.y -ge 0 -and
        ([string]$_.states -match 'showing')
    } | Sort-Object @{ Expression = { [int]$_.bounds.y } }, @{ Expression = { [int]$_.bounds.x } })

    $node = $accountNodes | Select-Object -First 1
    if (-not $node) {
        return [pscustomobject]@{ Number = ''; Ending = ''; Alias = ''; Label = ''; Source = 'not_found' }
    }

    $m = [regex]::Match([string]$node.name, '^(?<number>\d{8}|ACCOUNT_REDACTED)SCHW\s+\((?<alias>[^)]+)\)')
    $alias = Normalize-TosAccountAlias $m.Groups['alias'].Value
    if ($m.Groups['number'].Value.EndsWith('9157')) { $alias = 'Living Trust' }
    elseif ($m.Groups['number'].Value.EndsWith('5682')) { $alias = 'IRA' }

    return [pscustomobject]@{
        Number = 'ACCOUNT_REDACTED'
        Ending = if ($m.Groups['number'].Value -eq 'ACCOUNT_REDACTED') { Get-ExpectedAccountEnding $alias } else { $m.Groups['number'].Value.Substring($m.Groups['number'].Value.Length - 4) }
        Alias = $alias
        Label = ConvertTo-TosSanitizedText ([string]$node.name)
        Source = 'main_header_visible_account_label'
    }
}

function Test-AccountCandidateMatches {
    param(
        [string]$Candidates,
        [string]$Alias
    )
    if ([string]::IsNullOrWhiteSpace($Alias) -or [string]::IsNullOrWhiteSpace($Candidates)) { return $false }
    $normalized = Normalize-TosAccountAlias $Alias
    return $Candidates -match "(^|;\s*)$([regex]::Escape($normalized))(\s*/|;|$)"
}


function Find-SnapshotOrderRow {
    param(
        [string]$Symbol,
        [string]$ReplacingOrderId,
        [string]$OcoId,
        [string]$Threshold
    )

    if ($snapshotNodes.Count -eq 0) {
        return [pscustomobject]@{ MatchCount = 0; UniqueMatch = $false; CurrentOrderId = ''; Status = ''; Path = ''; Text = '' }
    }

    $snapshotRowMatches = New-Object System.Collections.Generic.List[object]
    foreach ($node in $snapshotNodes) {
        if ($node.role -ne 'label' -or [string]::IsNullOrWhiteSpace([string]$node.name)) { continue }
        $name = [string]$node.name
        if ($name -notmatch "\b$([regex]::Escape($Symbol))\b") { continue }
        if ($ReplacingOrderId -and $name -notmatch "Replacing #$([regex]::Escape($ReplacingOrderId))") { continue }
        if ($OcoId -and $name -notmatch "OCO #$([regex]::Escape($OcoId))") { continue }
        if ($Threshold -and $name -notmatch [regex]::Escape($Threshold)) { continue }

        $siblings = @($snapshotNodes | Where-Object { $_.parentId -eq $node.parentId } | Sort-Object id)
        $idx = [Array]::IndexOf([object[]]$siblings, $node)
        $window = @()
        if ($idx -ge 0) {
            $start = [Math]::Max(0, $idx - 4)
            $end = [Math]::Min($siblings.Count - 1, $idx + 4)
            $window = $siblings[$start..$end]
        }
        $status = $window | Where-Object { $_.role -eq 'label' -and $_.name -match 'WAIT COND|WORKING|CANCELED|FILLED' } | Select-Object -First 1
        $orderId = $window | Where-Object { $_.role -eq 'label' -and $_.name -match '^\d{10,}$' } | Select-Object -Last 1
        $currentOrderIdValue = ''
        if ($orderId) { $currentOrderIdValue = $orderId.name }
        $statusValue = ''
        if ($status) { $statusValue = $status.name }
        $snapshotRowMatches.Add([pscustomobject]@{
            CurrentOrderId = $currentOrderIdValue
            Status = $statusValue
            Path = $node.path
            Text = $name
        }) | Out-Null
    }

    $first = $snapshotRowMatches | Select-Object -First 1
    $firstOrderId = ''
    $firstStatus = ''
    $firstPath = ''
    $firstText = ''
    if ($first) {
        $firstOrderId = $first.CurrentOrderId
        $firstStatus = $first.Status
        $firstPath = $first.Path
        $firstText = $first.Text
    }
    return [pscustomobject]@{
        MatchCount = $snapshotRowMatches.Count
        UniqueMatch = ($snapshotRowMatches.Count -eq 1)
        CurrentOrderId = $firstOrderId
        Status = $firstStatus
        Path = $firstPath
        Text = $firstText
    }
}

function Get-ExpectedLevelForOrder {
    param(
        [object]$VisibleOrder,
        [object]$ExpectedLevels
    )

    $conditionSide = ([string]$VisibleOrder.ConditionSide).Trim().ToUpperInvariant()
    $orderType = ([string]$VisibleOrder.OrderType).Trim().ToUpperInvariant()
    $current = To-NullableDecimal $VisibleOrder.ConditionThreshold
    $expectedStop = To-NullableDecimal $ExpectedLevels.ExpectedStop
    $expectedT1 = To-NullableDecimal $ExpectedLevels.ExpectedT1
    $expectedT2 = To-NullableDecimal $ExpectedLevels.ExpectedT2

    if ($orderType -eq 'STP' -or $conditionSide -eq 'BELOW') {
        return [pscustomobject]@{ Role = 'StopLoss'; Phase = 'Stop'; ExpectedThreshold = $expectedStop; ExpectedField = 'ExpectedStop' }
    }

    if ($conditionSide -eq 'ABOVE') {
        $candidates = @(
            [pscustomobject]@{ Role = 'ProfitTarget'; Phase = 'T1'; ExpectedThreshold = $expectedT1; ExpectedField = 'ExpectedT1' },
            [pscustomobject]@{ Role = 'ProfitTarget'; Phase = 'T2'; ExpectedThreshold = $expectedT2; ExpectedField = 'ExpectedT2' }
        ) | Where-Object { $null -ne $_.ExpectedThreshold }

        if ($null -ne $current -and $candidates.Count -gt 0) {
            return $candidates | Sort-Object { [math]::Abs([double]($_.ExpectedThreshold - $current)) } | Select-Object -First 1
        }
        return $candidates | Select-Object -First 1
    }

    return [pscustomobject]@{ Role = 'Unknown'; Phase = ''; ExpectedThreshold = $null; ExpectedField = '' }
}

$tosAccountContext = Get-TosAccountContext
$targetAccountAlias = Normalize-TosAccountAlias $TargetAccount
if ([string]::IsNullOrWhiteSpace($targetAccountAlias) -and -not [string]::IsNullOrWhiteSpace([string]$tosAccountContext.Alias)) {
    $targetAccountAlias = Normalize-TosAccountAlias $tosAccountContext.Alias
}
$targetAccountEnding = Get-ExpectedAccountEnding $targetAccountAlias

$levelsBySymbol = @{}
foreach ($r in $recon) {
    $ticker = ([string]$r.Ticker).Trim().ToUpperInvariant()
    if ($ticker.Length -eq 0) { continue }
    if ($Symbol -and $ticker -ne $Symbol.ToUpperInvariant()) { continue }
    $rowAccount = Normalize-TosAccountAlias ([string]$r.Account)
    if (-not [string]::IsNullOrWhiteSpace($targetAccountAlias) -and $rowAccount -ne $targetAccountAlias) { continue }

    if (-not $levelsBySymbol.ContainsKey($ticker)) {
        $levelsBySymbol[$ticker] = [ordered]@{
            Ticker = $ticker
            TargetAccountAlias = $rowAccount
            TargetAccountEnding = if (-not [string]::IsNullOrWhiteSpace([string]$r.ExpectedAccountEnding)) { [string]$r.ExpectedAccountEnding } else { Get-ExpectedAccountEnding $rowAccount }
            ExpectedStop = $r.ExpectedStop
            ExpectedT1 = $r.ExpectedT1
            ExpectedT2 = $r.ExpectedT2
            Accounts = New-Object System.Collections.Generic.List[string]
            ReconciliationRows = New-Object System.Collections.Generic.List[object]
        }
    }

    $accountLabel = ((@($r.Account, $r.Portfolio, $r.ContractLabel) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' / ')
    if ($accountLabel -and -not $levelsBySymbol[$ticker].Accounts.Contains($accountLabel)) {
        $levelsBySymbol[$ticker].Accounts.Add($accountLabel) | Out-Null
    }
    $levelsBySymbol[$ticker].ReconciliationRows.Add($r) | Out-Null
}

$items = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[object]

$filteredVisible = $visible | Where-Object {
    $conditionSymbol = ([string]$_.ConditionSymbol).Trim().ToUpperInvariant()
    $conditionSymbol.Length -gt 0 -and
    (-not $Symbol -or $conditionSymbol -eq $Symbol.ToUpperInvariant()) -and
    $_.ToClose -eq 'True'
}

foreach ($order in $filteredVisible) {
    $conditionSymbol = ([string]$order.ConditionSymbol).Trim().ToUpperInvariant()
    if (-not $levelsBySymbol.ContainsKey($conditionSymbol)) { continue }

    $expected = [pscustomobject]$levelsBySymbol[$conditionSymbol]
    $mapping = Get-ExpectedLevelForOrder -VisibleOrder $order -ExpectedLevels $expected
    $current = To-NullableDecimal $order.ConditionThreshold
    $target = $mapping.ExpectedThreshold
    $delta = if ($null -ne $current -and $null -ne $target) { [decimal]($target - $current) } else { $null }
    $needsUpdate = $false
    if ($null -ne $delta) { $needsUpdate = ([math]::Abs([double]$delta) -gt [double]$Tolerance) }
    $replacingOrderId = Get-ReplacingOrderId $order.RawOrder
    $snapshotMatch = Find-SnapshotOrderRow -Symbol $conditionSymbol -ReplacingOrderId $replacingOrderId -OcoId $order.OcoId -Threshold $order.ConditionThreshold
    $visibleStatus = ([string]$order.Status).Trim().ToUpperInvariant()
    $snapshotStatus = ([string]$snapshotMatch.Status).Trim().ToUpperInvariant()
    $visibleRowIsActive = ([string]::IsNullOrWhiteSpace($visibleStatus) -or $visibleStatus -notmatch 'CANCELED|FILLED')
    $snapshotRowIsActive = ($snapshotNodes.Count -eq 0 -or [string]::IsNullOrWhiteSpace($snapshotStatus) -or $snapshotStatus -notmatch 'CANCELED|FILLED')
    $rowIsActive = ($visibleRowIsActive -and $snapshotRowIsActive)
    $accountCandidatesText = ($expected.Accounts -join '; ')
    $expectedAccountAlias = Normalize-TosAccountAlias ([string]$expected.TargetAccountAlias)
    $expectedAccountEnding = [string]$expected.TargetAccountEnding
    $currentAccountAlias = Normalize-TosAccountAlias ([string]$tosAccountContext.Alias)
    $accountVerifiedValue = (
        -not [string]::IsNullOrWhiteSpace($expectedAccountAlias) -and
        $currentAccountAlias -eq $expectedAccountAlias -and
        (
            [string]::IsNullOrWhiteSpace($expectedAccountEnding) -or
            [string]::IsNullOrWhiteSpace([string]$tosAccountContext.Ending) -or
            [string]$tosAccountContext.Ending -eq $expectedAccountEnding
        )
    )
    $actionValue = 'no_change'
    if ($needsUpdate) { $actionValue = 'update_condition_threshold' }
    if ($needsUpdate -and -not $rowIsActive) { $actionValue = 'skip_inactive_snapshot_row' }

    $items.Add([pscustomobject]@{
        Action = $actionValue
        ReadyForDesktopAutomation = [bool]($needsUpdate -and $rowIsActive -and $accountVerifiedValue -and -not [string]::IsNullOrWhiteSpace([string]$order.OcoId) -and $null -ne $target -and ($snapshotNodes.Count -eq 0 -or $snapshotMatch.UniqueMatch))
        Symbol = $conditionSymbol
        AccountCandidates = $accountCandidatesText
        TargetAccountAlias = $expectedAccountAlias
        TargetAccountEnding = $expectedAccountEnding
        CurrentTosAccountNumber = $tosAccountContext.Number
        CurrentTosAccountEnding = $tosAccountContext.Ending
        CurrentTosAccountAlias = $currentAccountAlias
        CurrentTosAccountLabel = $tosAccountContext.Label
        AccountContextSource = $tosAccountContext.Source
        AccountVerified = $accountVerifiedValue
        OrderRole = $mapping.Role
        Phase = $mapping.Phase
        OrderType = $order.OrderType
        Side = $order.Side
        Quantity = $order.Quantity
        OcoId = $order.OcoId
        ReplacingOrderId = $replacingOrderId
        CurrentOrderId = $snapshotMatch.CurrentOrderId
        SnapshotMatchCount = $snapshotMatch.MatchCount
        SnapshotUniqueMatch = $snapshotMatch.UniqueMatch
        SnapshotStatus = $snapshotMatch.Status
        SnapshotPath = $snapshotMatch.Path
        InstrumentLabel = Get-InstrumentLabel -RawOrder $order.RawOrder -ConditionSymbol $conditionSymbol
        CurrentConditionSide = $order.ConditionSide
        CurrentThreshold = if ($null -ne $current) { [string]$current } else { '' }
        ExpectedField = $mapping.ExpectedField
        ExpectedThreshold = if ($null -ne $target) { [string]$target } else { '' }
        Delta = if ($null -ne $delta) { [string]$delta } else { '' }
        TosConditionText = if ($null -ne $target) { "$conditionSymbol MARK AT OR $($order.ConditionSide) $target" } else { '' }
        RawOrder = $order.RawOrder
    }) | Out-Null
}

foreach ($ticker in $levelsBySymbol.Keys) {
    $expected = [pscustomobject]$levelsBySymbol[$ticker]
    $symbolOrders = @($filteredVisible | Where-Object { ([string]$_.ConditionSymbol).Trim().ToUpperInvariant() -eq $ticker })
    $stopOrders = @($symbolOrders | Where-Object { $_.OrderType -eq 'STP' -or $_.ConditionSide -eq 'BELOW' })
    $targetOrders = @($symbolOrders | Where-Object { $_.ConditionSide -eq 'ABOVE' })
    if ($stopOrders.Count -eq 0) {
        $missing.Add([pscustomobject]@{ Symbol = $ticker; TargetAccountAlias = $expected.TargetAccountAlias; TargetAccountEnding = $expected.TargetAccountEnding; Missing = 'Stop'; ExpectedThreshold = $expected.ExpectedStop; AccountCandidates = ($expected.Accounts -join '; '); Note = 'No visible stop row in current TOS working-order snapshot.' }) | Out-Null
    }
    foreach ($targetInfo in @([pscustomobject]@{ Name='T1'; Value=$expected.ExpectedT1 }, [pscustomobject]@{ Name='T2'; Value=$expected.ExpectedT2 })) {
        $value = To-NullableDecimal $targetInfo.Value
        if ($null -eq $value) { continue }
        $hasTarget = $false
        foreach ($order in $targetOrders) {
            $current = To-NullableDecimal $order.ConditionThreshold
            if ($null -ne $current -and [math]::Abs([double]($current - $value)) -le [double]$Tolerance) { $hasTarget = $true; break }
        }
        if (-not $hasTarget) {
            $missing.Add([pscustomobject]@{ Symbol = $ticker; TargetAccountAlias = $expected.TargetAccountAlias; TargetAccountEnding = $expected.TargetAccountEnding; Missing = $targetInfo.Name; ExpectedThreshold = [string]$value; AccountCandidates = ($expected.Accounts -join '; '); Note = 'Expected target is not visible as an active close row in current TOS working-order snapshot.' }) | Out-Null
        }
    }
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $symbolPart = if ($Symbol) { '-' + $Symbol.ToUpperInvariant() } else { '' }
    $OutFile = Join-Path $PSScriptRoot "..\TosAutomation\Diagnostics\tos-oco-update-batch$symbolPart-$stamp.json"
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$result = [pscustomobject]@{
    createdUtc = (Get-Date).ToUniversalTime().ToString('o')
    visibleOrdersCsv = $VisibleOrdersCsv
    reconciliationCsv = $ReconciliationCsv
    snapshotJson = $SnapshotJson
    symbol = $Symbol
    targetAccount = [pscustomobject]@{ Alias = $targetAccountAlias; Ending = $targetAccountEnding }
    currentTosAccount = $tosAccountContext
    rule = 'One visible TOS OCO/order row creates one work item. Target account must match current TOS account before desktop automation is allowed.'
    itemCount = $items.Count
    updateCount = @($items | Where-Object { $_.Action -eq 'update_condition_threshold' }).Count
    readyCount = @($items | Where-Object { $_.ReadyForDesktopAutomation }).Count
    missingProtectionCount = $missing.Count
    items = $items
    missingProtection = $missing
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 12
Write-Host "Wrote OCO update batch plan to $OutFile"








