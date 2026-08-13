param(
    [Parameter(Mandatory=$true)][string]$UpdateLevelsPath,
    [string]$OutDir = ".\Analysis",
    [switch]$DryRun,
    [switch]$AllowSave
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $UpdateLevelsPath)) {
    throw "Update levels file not found: $UpdateLevelsPath"
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$rows = @(Import-Csv -LiteralPath $UpdateLevelsPath)
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resultPath = Join-Path $OutDir "tos-oco-update-run-$stamp.csv"
$script:results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        $Row,
        [string]$ExecutionStatus,
        [string]$Message
    )

    $script:results.Add([pscustomobject]@{
        RunStamp = $stamp
        Account = $Row.Account
        Portfolio = $Row.Portfolio
        Ticker = $Row.Ticker
        ContractLabel = $Row.ContractLabel
        Direction = $Row.Direction
        Level = $Row.Level
        ConditionType = $Row.ConditionType
        ExpectedThreshold = $Row.ExpectedThreshold
        SourceStatus = $Row.SourceStatus
        ExecutionStatus = $ExecutionStatus
        Message = $Message
        RecordedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }) | Out-Null
}

foreach ($row in $rows) {
    if ($DryRun) {
        Add-Result $row "DryRun" "Would update $($row.Account) $($row.Ticker) $($row.ContractLabel) $($row.Level) to $($row.ExpectedThreshold)."
        continue
    }

    Add-Result $row "NeedsOrderRulesWindow" "Open the exact TOS Order Rules window for $($row.Account) $($row.Ticker) $($row.ContractLabel) $($row.Level), then run tools\\Set-TosOrderCondition.ps1 -ConditionType $($row.ConditionType) -Threshold $($row.ExpectedThreshold) -LeaveOpen. Saving remains manual unless AllowSave is implemented after final confirmation."
}

$results | Export-Csv -LiteralPath $resultPath -NoTypeInformation

[pscustomobject]@{
    ResultPath = (Resolve-Path -LiteralPath $resultPath).Path
    InputRows = $rows.Count
    Results = $results.Count
    DryRun = [bool]$DryRun
    AllowSave = [bool]$AllowSave
}
