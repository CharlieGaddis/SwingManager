param(
    [Parameter(Mandatory=$true)][string]$BeforeTree,
    [Parameter(Mandatory=$true)][string]$AfterTree,
    [string]$OutFile = "$PSScriptRoot\..\TosAutomation\Diagnostics\tos-snapshot-diff.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $BeforeTree)) { throw "BeforeTree not found: $BeforeTree" }
if (-not (Test-Path -LiteralPath $AfterTree)) { throw "AfterTree not found: $AfterTree" }

$before = Get-Content -LiteralPath $BeforeTree
$after = Get-Content -LiteralPath $AfterTree
$beforeSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$afterSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in $before) { [void]$beforeSet.Add($line.Trim()) }
foreach ($line in $after) { [void]$afterSet.Add($line.Trim()) }

$added = New-Object System.Collections.Generic.List[string]
$removed = New-Object System.Collections.Generic.List[string]
foreach ($line in $afterSet) { if (-not $beforeSet.Contains($line)) { $added.Add($line) | Out-Null } }
foreach ($line in $beforeSet) { if (-not $afterSet.Contains($line)) { $removed.Add($line) | Out-Null } }

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$report = New-Object System.Collections.Generic.List[string]
$report.Add("TOS Snapshot Diff") | Out-Null
$report.Add("Generated: $(Get-Date -Format o)") | Out-Null
$report.Add("Before: $BeforeTree") | Out-Null
$report.Add("After:  $AfterTree") | Out-Null
$report.Add("Before lines: $($before.Count)") | Out-Null
$report.Add("After lines:  $($after.Count)") | Out-Null
$report.Add("Added unique lines: $($added.Count)") | Out-Null
$report.Add("Removed unique lines: $($removed.Count)") | Out-Null
$report.Add("") | Out-Null
$report.Add("== Added, first 200 ==") | Out-Null
$added | Select-Object -First 200 | ForEach-Object { $report.Add($_) | Out-Null }
$report.Add("") | Out-Null
$report.Add("== Removed, first 200 ==") | Out-Null
$removed | Select-Object -First 200 | ForEach-Object { $report.Add($_) | Out-Null }
$report | Set-Content -LiteralPath $OutFile -Encoding UTF8
[pscustomobject]@{
    BeforeTree = $BeforeTree
    AfterTree = $AfterTree
    Added = $added.Count
    Removed = $removed.Count
    OutFile = $OutFile
} | Format-List
