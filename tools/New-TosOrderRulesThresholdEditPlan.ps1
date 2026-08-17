param(
    [Parameter(Mandatory=$true)][string]$SnapshotJson,
    [Parameter(Mandatory=$true)][string]$ExpectedSymbol,
    [Parameter(Mandatory=$true)][string]$ExpectedMethod,
    [Parameter(Mandatory=$true)][string]$ExpectedOperator,
    [Parameter(Mandatory=$true)][decimal]$NewThreshold,
    [string]$LocatorJson = "",
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($LocatorJson)) { $LocatorJson = Join-Path (Split-Path -Parent $scriptDir) 'TosAutomation\Locators\OrderRules.ConditionTriggerPrice.v1.json' }
if (-not (Test-Path -LiteralPath $SnapshotJson)) { throw "SnapshotJson not found: $SnapshotJson" }
if (-not (Test-Path -LiteralPath $LocatorJson)) { throw "LocatorJson not found: $LocatorJson" }
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = ($ExpectedSymbol -replace '[^A-Za-z0-9_.-]+', '-')
    $OutFile = "$(Join-Path (Split-Path -Parent $scriptDir) 'TosAutomation\Diagnostics')\tos-threshold-edit-plan-$safeSymbol-$stamp.json"
}

$analysisJson = & (Join-Path $scriptDir 'Read-TosOrderRulesSnapshot.ps1') -SnapshotJson $SnapshotJson
$analysis = $analysisJson | ConvertFrom-Json
$locator = Get-Content -LiteralPath $LocatorJson -Raw | ConvertFrom-Json
$row = $analysis.submitConditionRow
$errors = New-Object System.Collections.Generic.List[string]

if (-not $analysis.inferred.hasSubmitAt) { $errors.Add("Submit at checkbox was not found.") | Out-Null }
if ($analysis.inferred.submitAtChecked -eq $true) { $errors.Add("Submit at checkbox is checked; refusing to plan save-capable edit.") | Out-Null }
if (-not $analysis.inferred.hasSubmitWhen) { $errors.Add("Submit when section was not found.") | Out-Null }
if (-not $analysis.inferred.hasSubmitConditionTable) { $errors.Add("Submit condition table was not found.") | Out-Null }
if (-not $analysis.inferred.hasSave) { $errors.Add("Save button was not found.") | Out-Null }
if ($row.symbol -ne $ExpectedSymbol) { $errors.Add("Expected symbol '$ExpectedSymbol' but saw '$($row.symbol)'.") | Out-Null }
if ($row.method -ne $ExpectedMethod) { $errors.Add("Expected method '$ExpectedMethod' but saw '$($row.method)'.") | Out-Null }
if ($row.operator -ne $ExpectedOperator) { $errors.Add("Expected operator '$ExpectedOperator' but saw '$($row.operator)'.") | Out-Null }

$table = $row.tableBounds
$geo = $locator.geometry.thresholdClick
$click = $null
if ($table -and $geo) {
    $click = [pscustomobject]@{
        x = [int]([int]$table.x + ([double]$geo.xRatioFromTableLeft * [int]$table.width))
        y = [int]([int]$table.y + [int]$geo.yOffsetFromTableTop)
    }
} else {
    $errors.Add("Missing table bounds or locator geometry.") | Out-Null
}

$plan = [pscustomobject]@{
    createdAt = (Get-Date).ToString("o")
    dryRun = $true
    snapshot = $SnapshotJson
    locator = $LocatorJson
    expected = [ordered]@{
        symbol = $ExpectedSymbol
        method = $ExpectedMethod
        operator = $ExpectedOperator
        newThreshold = $NewThreshold
    }
    observed = $analysis.inferred
    row = $row
    clickPoint = $click
    actions = @(
        "Verify current Order Rules screen state from fresh snapshot",
        "Verify Submit at remains unchecked",
        "Native click threshold field at computed table-relative point",
        "Send Ctrl+A",
        "Type $NewThreshold",
        "Send Tab",
        "Rediscover Order Rules dialog",
        "Verify row contains $NewThreshold before Save"
    )
    allowedToExecute = ($errors.Count -eq 0)
    errors = @($errors)
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$plan | Format-List
Write-Host "Wrote edit plan to $OutFile"

