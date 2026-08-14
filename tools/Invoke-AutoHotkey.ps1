param(
    [Parameter(Mandatory=$true)][string]$ScriptPath,
    [string]$ArgumentsJson = "[]"
)

$ErrorActionPreference = "Stop"
$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path -LiteralPath $ahk)) {
    throw "AutoHotkey v2 not found at $ahk"
}
$resolvedScript = Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop
$argumentList = @()
if (-not [string]::IsNullOrWhiteSpace($ArgumentsJson)) {
    $parsed = ConvertFrom-Json -InputObject $ArgumentsJson
    if ($null -ne $parsed) { $argumentList = @($parsed | ForEach-Object { [string]$_ }) }
}
& $ahk /ErrorStdOut $resolvedScript.ProviderPath @argumentList
if ($LASTEXITCODE) {
    throw "AutoHotkey exited with code $LASTEXITCODE for $($resolvedScript.ProviderPath)"
}