param(
    [Parameter(Mandatory=$true)][string]$NameRegex,
    [string]$WindowTitle = "Main@thinkorswim [build 1992]",
    [switch]$OpenContextMenu,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
    $OutDir = Join-Path $repoRoot.ProviderPath "Analysis"
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$findScript = Join-Path $PSScriptRoot "Find-TosJabNodeByName.ps1"
$clickScript = Join-Path $PSScriptRoot "Click-ScreenAbsolute.ahk"
$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
foreach ($required in @($findScript, $clickScript, $ahk)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing required file: $required" }
}

$matchPath = Join-Path $OutDir "tos-oco-desktop-match-$stamp.csv"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $findScript -WindowTitle $WindowTitle -NameRegex $NameRegex -OutFile $matchPath | Out-Host
$match = Import-Csv -LiteralPath $matchPath | Select-Object -First 1
if (-not $match -or [string]::IsNullOrWhiteSpace($match.Name)) {
    throw "No TOS row matched regex: $NameRegex"
}

$viewport = $null
foreach ($part in ($match.Ancestors -split ' \|\| ')) {
    $fields = @($part -split '\|', 4 | ForEach-Object { $_.Trim() })
    if ($fields.Count -ge 4 -and $fields[1] -eq 'viewport') {
        $nums = @($fields[3] -split ',' | ForEach-Object { $_.Trim() })
        if ($nums.Count -eq 4) {
            $viewport = [pscustomobject]@{ X=[int]$nums[0]; Y=[int]$nums[1]; W=[int]$nums[2]; H=[int]$nums[3] }
        }
    }
}
if ($null -eq $viewport) {
    throw "Could not determine visible viewport from JAB ancestors. Match: $matchPath"
}

$clickX = [int]$match.ClickX
$clickY = [int]$match.ClickY
$inViewport = $clickX -ge $viewport.X -and $clickX -le ($viewport.X + $viewport.W) -and $clickY -ge $viewport.Y -and $clickY -le ($viewport.Y + $viewport.H)
$status = if ($inViewport) { "VISIBLE_MATCH" } else { "MATCHED_BUT_NOT_VISIBLE" }
$result = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    Status = $status
    Regex = $NameRegex
    MatchedName = $match.Name
    Path = $match.Path
    ClickX = $clickX
    ClickY = $clickY
    Viewport = "$($viewport.X),$($viewport.Y),$($viewport.W),$($viewport.H)"
    MatchCsv = $matchPath
    ContextMenuOpened = $false
    ContextMenuCsv = ""
}

if (-not $inViewport) {
    $result | Format-List
    $resultPath = Join-Path $OutDir "tos-oco-desktop-update-$stamp.csv"
    $result | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
    throw "Refusing desktop action: matched row is outside visible viewport. Click=$clickX,$clickY viewport=$($result.Viewport). Scroll TOS until the row is visible, then rerun."
}

if ($OpenContextMenu) {
    $clickOut = Join-Path $OutDir "tos-oco-context-click-$stamp.csv"
    & $ahk /ErrorStdOut $clickScript $clickX $clickY "oco-context-$stamp" $clickOut 1 Right
    $result.ContextMenuOpened = $true
    $result.ContextMenuCsv = $clickOut
}

$resultPath = Join-Path $OutDir "tos-oco-desktop-update-$stamp.csv"
$result | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
$result | Format-List
Write-Host "Wrote desktop OCO update stage result to $resultPath"