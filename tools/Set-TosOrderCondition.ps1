param(
    [string]$WindowTitle = "Order Rules",
    [Parameter(Mandatory = $true)]
    [ValidateSet("Target", "Stop")]
    [string]$ConditionType,
    [Parameter(Mandatory = $true)]
    [decimal]$Threshold,
    [string]$Method = "MARK",
    [switch]$LeaveOpen,
    [switch]$AllowSave,
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-order-condition-result.csv"
)

$ErrorActionPreference = "Stop"

$submitConditionScript = Join-Path $PSScriptRoot "Set-TosSubmitCondition.ps1"
if (-not (Test-Path -LiteralPath $submitConditionScript)) {
    throw "Required script not found: $submitConditionScript"
}

$trigger = switch ($ConditionType) {
    "Target" { ">=" }
    "Stop" { "<=" }
}

$invokeParams = @{
    WindowTitle = $WindowTitle
    Trigger = $trigger
    Threshold = $Threshold
    Method = $Method
    OutFile = $OutFile
}

if ($LeaveOpen) {
    $invokeParams.LeaveOpen = $true
}

if ($AllowSave) {
    # The called script currently rejects this too. Keep it explicit here so the
    # wrapper cannot accidentally become a saving path before we approve it.
    $invokeParams.AllowSave = $true
}

Write-Host "Setting TOS $ConditionType condition as: $Method $trigger $Threshold"
& $submitConditionScript @invokeParams
