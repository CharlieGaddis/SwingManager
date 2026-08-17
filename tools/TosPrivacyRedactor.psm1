function ConvertTo-TosSanitizedText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $value = [string]$Text
    $value = [regex]::Replace($value, '\b\d{8}(?=SCHW\b)', 'ACCOUNT_REDACTED')
    $value = [regex]::Replace($value, '(?i)(account\s+)(\d{8})(?=SCHW|\b)', '${1}ACCOUNT_REDACTED')
    $value = [regex]::Replace($value, '(?i)(TOS Account:\s*)(\d{8})(?=SCHW|\b)', '${1}ACCOUNT_REDACTED')
    return $value
}

function ConvertTo-TosSanitizedLines {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$Lines)
    foreach ($line in $Lines) { ConvertTo-TosSanitizedText $line }
}

function Get-TosAccountRedactionRectsFromLines {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$Lines,
        [int]$Expand = 4
    )

    $rects = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Lines) {
        $isAccountSelector = (
            $line -match 'role="label"' -and
            $line -match '(ACCOUNT_REDACTED|\d{8})SCHW\s+\([^)]+\)' -and
            $line -match 'states="[^"]*showing[^"]*"' -and
            $line -match 'bounds=(?<x>-?\d+),(?<y>-?\d+),(?<w>-?\d+),(?<h>-?\d+)'
        )
        if (-not $isAccountSelector) { continue }

        $x = [int]$matches.x
        $y = [int]$matches.y
        $w = [int]$matches.w
        $h = [int]$matches.h
        if ($x -lt 0 -or $y -lt 0 -or $w -le 0 -or $h -le 0) { continue }

        $rects.Add([pscustomobject]@{
            X = [Math]::Max(0, $x - $Expand)
            Y = [Math]::Max(0, $y - $Expand)
            Width = $w + ($Expand * 2)
            Height = $h + ($Expand * 2)
            Source = 'jab_account_label'
        }) | Out-Null
    }

    # Remove duplicate visible account labels.
    $unique = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($rect in $rects) {
        $key = "$($rect.X),$($rect.Y),$($rect.Width),$($rect.Height)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($rect) | Out-Null
        }
    }
    return @($unique.ToArray())
}

function Get-TosAccountRedactionRectsFromTreePath {
    param(
        [Parameter(Mandatory=$true)][string]$TreePath,
        [int]$Expand = 4
    )
    if (-not (Test-Path -LiteralPath $TreePath)) { return @() }
    $lines = [string[]](Get-Content -LiteralPath $TreePath)
    return @(Get-TosAccountRedactionRectsFromLines -Lines $lines -Expand $Expand)
}

function Protect-TosBitmapAccountNumbers {
    param(
        [Parameter(Mandatory=$true)]$Bitmap,
        [Parameter(Mandatory=$true)][object[]]$Rects,
        [string]$MaskColor = 'Black'
    )

    Add-Type -AssemblyName System.Drawing
    $graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::$MaskColor)
    try {
        foreach ($rect in @($Rects)) {
            $x = [Math]::Max(0, [int]$rect.X)
            $y = [Math]::Max(0, [int]$rect.Y)
            $w = [Math]::Min([int]$rect.Width, $Bitmap.Width - $x)
            $h = [Math]::Min([int]$rect.Height, $Bitmap.Height - $y)
            if ($w -gt 0 -and $h -gt 0) {
                $graphics.FillRectangle($brush, $x, $y, $w, $h)
            }
        }
    } finally {
        if ($brush) { $brush.Dispose() }
        if ($graphics) { $graphics.Dispose() }
    }
}

function Save-TosRedactedBitmap {
    param(
        [Parameter(Mandatory=$true)]$Bitmap,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [object[]]$Rects = @()
    )

    Add-Type -AssemblyName System.Drawing
    if ($Rects -and $Rects.Count -gt 0) {
        Protect-TosBitmapAccountNumbers -Bitmap $Bitmap -Rects $Rects
    }
    $Bitmap.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
}

Export-ModuleMember -Function ConvertTo-TosSanitizedText,ConvertTo-TosSanitizedLines,Get-TosAccountRedactionRectsFromLines,Get-TosAccountRedactionRectsFromTreePath,Protect-TosBitmapAccountNumbers,Save-TosRedactedBitmap



