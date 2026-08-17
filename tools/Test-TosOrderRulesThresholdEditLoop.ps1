param(
    [string]$Hwnd = "",
    [string]$WindowTitle = "Order Rules",
    [Parameter(Mandatory=$true)][string]$ExpectedSymbol,
    [Parameter(Mandatory=$true)][string]$ExpectedMethod,
    [Parameter(Mandatory=$true)][string]$ExpectedOperator,
    [Parameter(Mandatory=$true)][decimal]$NewThreshold,
    [int]$Iterations = 3,
    [switch]$AllowInput,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = ($ExpectedSymbol -replace '[^A-Za-z0-9_.-]+', '-')
    $OutFile = Join-Path $projectRoot "TosAutomation\Diagnostics\tos-threshold-edit-loop-$safeSymbol-$stamp.json"
}

$results = New-Object System.Collections.Generic.List[object]
for ($i = 1; $i -le $Iterations; $i++) {
    $iterPath = [System.IO.Path]::ChangeExtension($OutFile, ".iteration-$i.json")
    $invokeArgs = @{
        WindowTitle = $WindowTitle
        ExpectedSymbol = $ExpectedSymbol
        ExpectedMethod = $ExpectedMethod
        ExpectedOperator = $ExpectedOperator
        NewThreshold = $NewThreshold
        OutFile = $iterPath
    }
    if (-not [string]::IsNullOrWhiteSpace($Hwnd)) { $invokeArgs.Hwnd = $Hwnd }
    if ($AllowInput) { $invokeArgs.AllowInput = $true }
    & (Join-Path $scriptDir 'Invoke-TosOrderRulesThresholdEdit.ps1') @invokeArgs | Out-Null
    $result = Get-Content -LiteralPath $iterPath -Raw | ConvertFrom-Json
    $results.Add($result) | Out-Null
    if ($result.errors.Count -gt 0) { break }
    Start-Sleep -Milliseconds 250
}

$summary = [pscustomobject]@{
    createdAt = (Get-Date).ToString("o")
    hwnd = $Hwnd
    windowTitle = $WindowTitle
    expectedSymbol = $ExpectedSymbol
    expectedMethod = $ExpectedMethod
    expectedOperator = $ExpectedOperator
    newThreshold = [string]$NewThreshold
    iterationsRequested = $Iterations
    iterationsRun = $results.Count
    allowInput = [bool]$AllowInput
    successes = @($results | Where-Object { $_.verifiedTypedValue -eq $true -and $_.errors.Count -eq 0 }).Count
    failures = @($results | Where-Object { $_.errors.Count -gt 0 }).Count
    saveAttempted = @($results | Where-Object { $_.saveAttempted -eq $true }).Count -gt 0
    results = $results
}
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$summary | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$summary | Format-List createdAt,iterationsRequested,iterationsRun,successes,failures,saveAttempted,allowInput
Write-Host "Wrote loop summary to $OutFile"

