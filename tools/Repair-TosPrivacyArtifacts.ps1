param(
    [string[]]$Roots = @("Analysis", "TosAutomation", "Wiki"),
    [switch]$RedactImages
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TosPrivacyRedactor.psm1") -Force

$textExtensions = @(".txt", ".json", ".csv", ".md", ".log")
$textChanged = 0
$imageChanged = 0

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
        if ($textExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $raw) { continue }
        $sanitized = ConvertTo-TosSanitizedText $raw
        $sanitized = [regex]::Replace($sanitized, '(?i)((?:"?(?:CurrentTosAccountNumber|ExpectedAccountNumber|accountNumber|AccountNumber)"?|TOS Account|Statement for account)\s*[:=,]?\s*"?)(\d{8})(?=SCHW|\b)', '${1}ACCOUNT_REDACTED')
        if ($file.Extension.ToLowerInvariant() -eq ".json") {
            $sanitized = [regex]::Replace($sanitized, '(?i)("(?:accountNumber|AccountNumber|ExpectedAccountNumber|CurrentTosAccountNumber)"\s*:\s*)ACCOUNT_REDACTED', '${1}"ACCOUNT_REDACTED"')
        }        if ($file.Name -like 'schwab-working-orders-api-*' -or $file.Name -like 'swing-nightly-worklist-*') {
            $sanitized = [regex]::Replace($sanitized, '(?<!\d)\d{8}(?!\d)', 'ACCOUNT_REDACTED')
        }
        if ($sanitized -ne $raw) {
            Set-Content -LiteralPath $file.FullName -Value $sanitized -Encoding UTF8
            $textChanged++
        }
    }
}

if ($RedactImages) {
    Add-Type -AssemblyName System.Drawing
    foreach ($png in Get-ChildItem -LiteralPath "TosAutomation" -Recurse -File -Filter "*.png" -ErrorAction SilentlyContinue) {
        $stem = [System.IO.Path]::Combine($png.DirectoryName, [System.IO.Path]::GetFileNameWithoutExtension($png.Name))
        $treePath = "$stem-tree.txt"
        $jsonPath = "$stem.json"
        $isCrop = $false
        if ($stem.EndsWith('-crop')) {
            $isCrop = $true
            $baseStem = $stem.Substring(0, $stem.Length - 5)
            $treePath = "$baseStem-tree.txt"
            $jsonPath = "$baseStem.json"
        }
        if (-not (Test-Path -LiteralPath $treePath)) { continue }
        $rects = @(Get-TosAccountRedactionRectsFromTreePath -TreePath $treePath)
        if ($rects.Count -eq 0) { continue }

        $bitmap = [System.Drawing.Bitmap]::FromFile($png.FullName)
        try {
            $targetRects = $rects
            if ($isCrop -and (Test-Path -LiteralPath $jsonPath)) {
                $capture = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
                $cropSize = 260
                $screenW = 0
                $screenH = 0
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                    $screenW = $bounds.Width
                    $screenH = $bounds.Height
                } catch {}
                if ($screenW -le 0) { $screenW = 99999 }
                if ($screenH -le 0) { $screenH = 99999 }
                $cropX = [Math]::Max(0, [Math]::Min([int]$capture.mouse.x - [int]($cropSize / 2), $screenW - $cropSize))
                $cropY = [Math]::Max(0, [Math]::Min([int]$capture.mouse.y - [int]($cropSize / 2), $screenH - $cropSize))
                $translated = New-Object System.Collections.Generic.List[object]
                foreach ($rect in $rects) {
                    $x1 = [Math]::Max([int]$rect.X, $cropX)
                    $y1 = [Math]::Max([int]$rect.Y, $cropY)
                    $x2 = [Math]::Min([int]$rect.X + [int]$rect.Width, $cropX + $bitmap.Width)
                    $y2 = [Math]::Min([int]$rect.Y + [int]$rect.Height, $cropY + $bitmap.Height)
                    if ($x2 -gt $x1 -and $y2 -gt $y1) {
                        $translated.Add([pscustomobject]@{ X = $x1 - $cropX; Y = $y1 - $cropY; Width = $x2 - $x1; Height = $y2 - $y1; Source = 'crop_translated_jab_account_label' }) | Out-Null
                    }
                }
                $targetRects = @($translated.ToArray())
            }
            if ($targetRects.Count -gt 0) {
                Protect-TosBitmapAccountNumbers -Bitmap $bitmap -Rects $targetRects
                $tempPng = "$($png.FullName).redacted.tmp.png"
                $bitmap.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)
                $bitmap.Dispose()
                Move-Item -LiteralPath $tempPng -Destination $png.FullName -Force
                $bitmap = $null
                $imageChanged++
            }
        } finally {
            if ($bitmap) { $bitmap.Dispose() }
        }
    }
}

[pscustomobject]@{
    TextArtifactsSanitized = $textChanged
    ImagesRedacted = $imageChanged
    Roots = ($Roots -join '; ')
}





