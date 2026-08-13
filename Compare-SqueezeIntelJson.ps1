param(
    [Parameter(Mandatory=$true)][string]$OldPath,
    [Parameter(Mandatory=$true)][string]$NewPath,
    [string]$OutPath = ""
)

$ErrorActionPreference = "Stop"

$old = Get-Content -Raw -LiteralPath $OldPath | ConvertFrom-Json
$new = Get-Content -Raw -LiteralPath $NewPath | ConvertFrom-Json

function Get-StockKey($x) {
    return [string]$x.ticker
}

function Get-OptionKey($x) {
    if ($x.leg_group_id) {
        return [string]$x.leg_group_id
    }
    return "$($x.ticker)|$($x.contract_label)|$($x.structure)"
}

function New-MapByKey($items, [scriptblock]$keyFn) {
    $map = @{}
    foreach ($item in @($items)) {
        $map[(& $keyFn $item)] = $item
    }
    return $map
}

function Compare-Set($oldItems, $newItems, [scriptblock]$keyFn) {
    $oldMap = New-MapByKey $oldItems $keyFn
    $newMap = New-MapByKey $newItems $keyFn
    return [pscustomobject]@{
        Added = @($newMap.Keys | Where-Object { -not $oldMap.ContainsKey($_) } | Sort-Object)
        Removed = @($oldMap.Keys | Where-Object { -not $newMap.ContainsKey($_) } | Sort-Object)
        Common = @($newMap.Keys | Where-Object { $oldMap.ContainsKey($_) } | Sort-Object)
        OldMap = $oldMap
        NewMap = $newMap
    }
}

function Get-ChangeRows($diff, [string[]]$fields, [string[]]$labelFields) {
    $rows = @()
    foreach ($key in $diff.Common) {
        $oldItem = $diff.OldMap[$key]
        $newItem = $diff.NewMap[$key]
        $changes = @()
        foreach ($field in $fields) {
            $oldValue = $oldItem.$field
            $newValue = $newItem.$field
            if ([string]$oldValue -ne [string]$newValue) {
                $changes += "${field}: $oldValue -> $newValue"
            }
        }
        if ($changes.Count -gt 0) {
            $row = [ordered]@{ Key = $key }
            foreach ($labelField in $labelFields) {
                $row[$labelField] = $newItem.$labelField
            }
            $row["Changes"] = $changes -join "; "
            $rows += [pscustomobject]$row
        }
    }
    return $rows
}

function Format-ListLine([string]$label, $values) {
    if (@($values).Count -eq 0) {
        return "- ${label}: none"
    }
    return "- ${label}: $(@($values) -join ', ')"
}

$stockActive = Compare-Set $old.portfolio.active $new.portfolio.active ${function:Get-StockKey}
$stockPending = Compare-Set $old.portfolio.pending $new.portfolio.pending ${function:Get-StockKey}
$optionPositions = Compare-Set $old.portfolio_options.positions $new.portfolio_options.positions ${function:Get-OptionKey}
$optionPending = Compare-Set $old.portfolio_options.pending $new.portfolio_options.pending ${function:Get-OptionKey}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Squeeze Intel JSON Diff $($old.scan_date) to $($new.scan_date)")
$lines.Add("")
$lines.Add("## Counts")
$lines.Add("- Stock active: $(@($old.portfolio.active).Count) -> $(@($new.portfolio.active).Count)")
$lines.Add("- Stock pending: $(@($old.portfolio.pending).Count) -> $(@($new.portfolio.pending).Count)")
$lines.Add("- Option positions: $(@($old.portfolio_options.positions).Count) -> $(@($new.portfolio_options.positions).Count)")
$lines.Add("- Option pending: $(@($old.portfolio_options.pending).Count) -> $(@($new.portfolio_options.pending).Count)")
$lines.Add("- Option closed: $(@($old.portfolio_options.closed).Count) -> $(@($new.portfolio_options.closed).Count)")
$lines.Add("")

$lines.Add("## Stock Active Changes")
$rows = Get-ChangeRows $stockActive @("stop","target","second_target","partial_taken","size_multiple","current_price","pct_return") @("ticker")
if ($rows.Count) { $lines.Add(($rows | Format-Table -AutoSize | Out-String).TrimEnd()) } else { $lines.Add("No active stock level changes.") }
$lines.Add("")

$lines.Add("## Stock Pending Adds/Removes")
$lines.Add((Format-ListLine "Added" $stockPending.Added))
$lines.Add((Format-ListLine "Removed" $stockPending.Removed))
$lines.Add("")

$lines.Add("## Stock Pending Changes")
$rows = Get-ChangeRows $stockPending @("limit_price","stop","target","second_target","days_remaining","current_close") @("ticker")
if ($rows.Count) { $lines.Add(($rows | Format-Table -AutoSize | Out-String).TrimEnd()) } else { $lines.Add("No common pending stock changes.") }
$lines.Add("")

$lines.Add("## Option Position Changes")
$rows = Get-ChangeRows $optionPositions @("stock_stop","stock_target","stock_second_target","t1_taken","contracts","current_premium","pnl_pct") @("ticker","contract_label","structure")
if ($rows.Count) { $lines.Add(($rows | Format-Table -AutoSize | Out-String).TrimEnd()) } else { $lines.Add("No active option position changes.") }
$lines.Add("")

$lines.Add("## Option Pending Adds/Removes")
$lines.Add((Format-ListLine "Added" $optionPending.Added))
$lines.Add((Format-ListLine "Removed" $optionPending.Removed))
$lines.Add("")

$lines.Add("## Option Pending Changes")
$rows = Get-ChangeRows $optionPending @("stock_limit","estimated_premium","contracts","days_remaining") @("ticker","contract_label","structure")
if ($rows.Count) { $lines.Add(($rows | Format-Table -AutoSize | Out-String).TrimEnd()) } else { $lines.Add("No common pending option changes.") }

$report = $lines -join [Environment]::NewLine
if ($OutPath) {
    Set-Content -LiteralPath $OutPath -Value $report -Encoding UTF8
}
$report
