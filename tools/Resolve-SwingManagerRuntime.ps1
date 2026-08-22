param(
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$settingsPath = Join-Path $ProjectRoot "Config\machine.local.json"
$runtimeRoot = $env:SWING_MANAGER_RUNTIME_ROOT

if ([string]::IsNullOrWhiteSpace($runtimeRoot) -and (Test-Path -LiteralPath $settingsPath)) {
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    $runtimeRoot = [string]$settings.runtimeRoot
}

if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
    # Preserve the existing desktop layout until a machine profile is added.
    $runtimeRoot = $ProjectRoot
}

$runtimeRoot = [Environment]::ExpandEnvironmentVariables($runtimeRoot)
if (-not [System.IO.Path]::IsPathRooted($runtimeRoot)) {
    $runtimeRoot = Join-Path $ProjectRoot $runtimeRoot
}
$runtimeRoot = [System.IO.Path]::GetFullPath($runtimeRoot)

[pscustomobject]@{
    ProjectRoot = $ProjectRoot
    RuntimeRoot = $runtimeRoot
    DataPath = (Join-Path $runtimeRoot "Data")
    AnalysisPath = (Join-Path $runtimeRoot "Analysis")
}
