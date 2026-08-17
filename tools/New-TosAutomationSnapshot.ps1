param(
    [string]$WindowTitle = "Main@thinkorswim [build 1992]",
    [string]$Hwnd = "",
    [string]$Label = "snapshot",
    [string]$OutDir = "$PSScriptRoot\..\TosAutomation\Discovery",
    [int]$MaxDepth = 35,
    [int]$MaxChildrenPerNode = 200
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TosPrivacyRedactor.psm1") -Force
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeLabel = ($Label -replace "[^A-Za-z0-9_.-]+", "-").Trim("-")
if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = "snapshot" }
$base = Join-Path $OutDir "tos-$safeLabel-$stamp"
$treePath = "$base-tree.txt"
$jsonTreePath = "$base-tree.json"
$metaPath = "$base-meta.json"
$screenshotPath = "$base.png"
$screenshotError = ""

if ([string]::IsNullOrWhiteSpace($Hwnd)) {
    & "$PSScriptRoot\Dump-TosJabTree.ps1" -WindowTitle $WindowTitle -OutFile $treePath -MaxDepth $MaxDepth -MaxChildrenPerNode $MaxChildrenPerNode | Out-Null
} else {
    & "$PSScriptRoot\Dump-TosJabTree.ps1" -Hwnd $Hwnd -OutFile $treePath -MaxDepth $MaxDepth -MaxChildrenPerNode $MaxChildrenPerNode | Out-Null
}

& "$PSScriptRoot\Convert-TosJabTreeTextToJson.ps1" -TreePath $treePath -OutFile $jsonTreePath | Out-Null

$privacyRedactionRects = @(Get-TosAccountRedactionRectsFromTreePath -TreePath $treePath)
$privacyRedactionSource = "snapshot_tree"
if ($privacyRedactionRects.Count -eq 0) {
    $privacyTempTree = Join-Path $env:TEMP "tos-main-account-redaction-$stamp.txt"
    try {
        & "$PSScriptRoot\Dump-TosJabTree.ps1" -WindowTitle "Main@thinkorswim" -OutFile $privacyTempTree -MaxDepth 12 -MaxChildrenPerNode 120 | Out-Null
        $privacyRedactionRects = @(Get-TosAccountRedactionRectsFromTreePath -TreePath $privacyTempTree)
        if ($privacyRedactionRects.Count -gt 0) { $privacyRedactionSource = "main_window_fallback_tree" }
    } catch {
        $screenshotError = "Account redaction locator fallback failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $privacyTempTree -Force -ErrorAction SilentlyContinue
    }
}

try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    } finally {
        if ($graphics) { $graphics.Dispose() }
    }
    try {
        Save-TosRedactedBitmap -Bitmap $bitmap -OutFile $screenshotPath -Rects $privacyRedactionRects
    } finally {
        if ($bitmap) { $bitmap.Dispose() }
    }
} catch {
    $screenshotError = $_.Exception.Message
    Write-Warning "Screenshot capture/redaction failed, but tree/JSON snapshot was written: $screenshotError"
}

$treeText = Get-Content -LiteralPath $treePath -Raw
$anchors = [ordered]@{
    hasOrderRules = $treeText -match "Order Rules"
    hasWorkingOrders = $treeText -match "Working Orders|WORKING|WAIT COND"
    hasSubmitAt = $treeText -match "Submit at"
    hasSubmitWhen = $treeText -match "Submit when"
    hasCancel = $treeText -match "Cancel"
    hasSave = $treeText -match "Save"
}
$state = if ($anchors.hasOrderRules -and $anchors.hasSubmitWhen) {
    "OrderRulesDialog"
} elseif ($anchors.hasWorkingOrders) {
    "MonitorOrWorkingOrders"
} else {
    "Unknown"
}
$meta = [pscustomobject]@{
    capturedAt = (Get-Date).ToString("o")
    label = $Label
    windowTitle = $WindowTitle
    hwnd = $Hwnd
    maxDepth = $MaxDepth
    maxChildrenPerNode = $MaxChildrenPerNode
    inferredScreenState = $state
    anchors = $anchors
    treePath = $treePath
    jsonTreePath = $jsonTreePath
    screenshotPath = $screenshotPath
    screenshotCaptured = (Test-Path -LiteralPath $screenshotPath)
    screenshotError = ConvertTo-TosSanitizedText $screenshotError
    privacyRedaction = [pscustomobject]@{ accountNumberMasked = $true; rectCount = $privacyRedactionRects.Count; source = $privacyRedactionSource; method = "solid_opaque_block" }
}
$meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding UTF8
$meta | Format-List
Write-Host "Wrote snapshot metadata to $metaPath"
Write-Host "Wrote tree to $treePath"
Write-Host "Wrote JSON tree to $jsonTreePath"
Write-Host "Wrote screenshot to $screenshotPath"

