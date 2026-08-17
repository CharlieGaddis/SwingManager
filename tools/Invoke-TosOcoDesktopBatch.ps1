param(
    [string]$BatchPath = "",
    [string]$Symbol = "",
    [ValidateSet("", "Stop", "T1", "T2")]
    [string]$Phase = "",
    [string]$OcoId = "",
    [string]$ReplacingOrderId = "",
    [ValidateSet("Plan", "ApplyOpenOrderRules")]
    [string]$Mode = "Plan",
    [switch]$AllowInput,
    [switch]$AllowSave,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
$analysisDir = Join-Path $projectRoot "Analysis"
$diagnosticsDir = Join-Path $projectRoot "TosAutomation\Diagnostics"

if ([string]::IsNullOrWhiteSpace($BatchPath)) {
    $latest = Get-ChildItem -LiteralPath $analysisDir -Filter "tos-oco-desktop-update-batch-*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) { throw "No desktop OCO batch JSON found in $analysisDir. Run the nightly OCO worklist first." }
    $BatchPath = $latest.FullName
}
if (-not (Test-Path -LiteralPath $BatchPath)) { throw "BatchPath not found: $BatchPath" }
if (-not (Test-Path -LiteralPath $diagnosticsDir)) { New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null }

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = if ($Symbol) { $Symbol.ToUpperInvariant() -replace '[^A-Z0-9_.-]+', '-' } else { 'selected' }
    $OutFile = Join-Path $diagnosticsDir "tos-oco-desktop-batch-$safeSymbol-$stamp.json"
}

$batch = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json
$items = @($batch.items | Where-Object {
    $_.Action -eq 'update_condition_threshold' -and
    $_.ReadyForDesktopAutomation -eq $true -and
    $_.AccountVerified -eq $true
})

if (-not [string]::IsNullOrWhiteSpace($Symbol)) {
    $want = $Symbol.Trim().ToUpperInvariant()
    $items = @($items | Where-Object { ([string]$_.Symbol).Trim().ToUpperInvariant() -eq $want })
}
if (-not [string]::IsNullOrWhiteSpace($Phase)) {
    $items = @($items | Where-Object { $_.Phase -eq $Phase })
}
if (-not [string]::IsNullOrWhiteSpace($OcoId)) {
    $items = @($items | Where-Object { [string]$_.OcoId -eq [string]$OcoId })
}
if (-not [string]::IsNullOrWhiteSpace($ReplacingOrderId)) {
    $items = @($items | Where-Object { [string]$_.ReplacingOrderId -eq [string]$ReplacingOrderId })
}

$errors = New-Object System.Collections.Generic.List[string]
if ($items.Count -eq 0) {
    $errors.Add("No verified ready desktop OCO update item matched the requested filters.") | Out-Null
}
if ($items.Count -gt 1) {
    $errors.Add("More than one ready item matched. Add -Symbol, -Phase, -OcoId, or -ReplacingOrderId before allowing desktop automation.") | Out-Null
}
if ($AllowSave -and -not $AllowInput) {
    $errors.Add("AllowSave requires AllowInput.") | Out-Null
}

$item = $items | Select-Object -First 1
$operator = ""
if ($item) {
    $side = ([string]$item.CurrentConditionSide).Trim().ToUpperInvariant()
    if ($side -eq "BELOW") { $operator = "<=" }
    elseif ($side -eq "ABOVE") { $operator = ">=" }
    else { $errors.Add("Could not derive condition operator from CurrentConditionSide '$($item.CurrentConditionSide)'.") | Out-Null }

    if ([string]::IsNullOrWhiteSpace([string]$item.ExpectedThreshold)) {
        $errors.Add("Selected item does not have an ExpectedThreshold.") | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.OcoId)) {
        $errors.Add("Selected item does not have an OCO id.") | Out-Null
    }
}

$result = [ordered]@{
    createdAt = (Get-Date).ToString("o")
    mode = $Mode
    batchPath = $BatchPath
    currentTosAccount = $batch.currentTosAccount
    requested = [ordered]@{
        symbol = $Symbol
        phase = $Phase
        ocoId = $OcoId
        replacingOrderId = $ReplacingOrderId
        allowInput = [bool]$AllowInput
        allowSave = [bool]$AllowSave
    }
    matchedCount = $items.Count
    selectedItem = $item
    allowedToProceed = ($errors.Count -eq 0)
    nextOperatorStep = $null
    thresholdEditResult = $null
    errors = @()
}

if ($errors.Count -eq 0) {
    $result.nextOperatorStep = [pscustomobject]@{
        account = $item.CurrentTosAccountAlias
        accountEnding = $item.CurrentTosAccountEnding
        symbol = $item.Symbol
        phase = $item.Phase
        ocoId = $item.OcoId
        replacingOrderId = $item.ReplacingOrderId
        currentThreshold = $item.CurrentThreshold
        expectedThreshold = $item.ExpectedThreshold
        operator = $operator
        instruction = "Open cancel/replace for this exact TOS row, open Order Rules, verify Submit at is unchecked, then run this command with -Mode ApplyOpenOrderRules."
        applyCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptDir\Invoke-TosOcoDesktopBatch.ps1`" -BatchPath `"$BatchPath`" -Symbol $($item.Symbol) -Phase $($item.Phase) -OcoId $($item.OcoId) -ReplacingOrderId $($item.ReplacingOrderId) -Mode ApplyOpenOrderRules -AllowInput"
    }
}

if ($errors.Count -eq 0 -and $Mode -eq "ApplyOpenOrderRules") {
    $editScript = Join-Path $scriptDir "Invoke-TosOrderRulesThresholdEdit.ps1"
    if (-not (Test-Path -LiteralPath $editScript)) { throw "Missing threshold edit script: $editScript" }
    $editOut = Join-Path $diagnosticsDir ("tos-oco-open-order-rules-edit-{0}-{1}-{2}.json" -f $item.Symbol, $item.Phase, (Get-Date -Format "yyyyMMdd-HHmmss"))
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $editScript,
        "-ExpectedSymbol", [string]$item.Symbol,
        "-ExpectedMethod", "MARK",
        "-ExpectedOperator", $operator,
        "-NewThreshold", [string]$item.ExpectedThreshold,
        "-OutFile", $editOut
    )
    if ($AllowInput) { $args += "-AllowInput" }
    if ($AllowSave) { $args += "-AllowSave" }
    $proc = & powershell.exe @args
    $result.thresholdEditResultPath = $editOut
    $result.thresholdEditOutput = ($proc | Out-String).Trim()
}

$result.errors = @($errors)
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 18
Write-Host "Wrote desktop OCO batch result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }
