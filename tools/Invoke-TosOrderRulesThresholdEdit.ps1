param(
    [string]$SnapshotJson = "",
    [string]$Hwnd = "",
    [string]$WindowTitle = "Order Rules",
    [Parameter(Mandatory=$true)][string]$ExpectedSymbol,
    [Parameter(Mandatory=$true)][string]$ExpectedMethod,
    [Parameter(Mandatory=$true)][string]$ExpectedOperator,
    [Parameter(Mandatory=$true)][decimal]$NewThreshold,
    [switch]$AllowInput,
    [switch]$AllowSave,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = ($ExpectedSymbol -replace '[^A-Za-z0-9_.-]+', '-')
    $OutFile = Join-Path $projectRoot "TosAutomation\Diagnostics\tos-threshold-edit-result-$safeSymbol-$stamp.json"
}

if ([string]::IsNullOrWhiteSpace($SnapshotJson)) {
    $label = "OrderRulesFresh-$($ExpectedSymbol -replace '[^A-Za-z0-9_.-]+', '-')"
    $discoveryDir = Join-Path $projectRoot 'TosAutomation\Discovery'
    if ([string]::IsNullOrWhiteSpace($Hwnd)) {
        & (Join-Path $scriptDir 'New-TosAutomationSnapshot.ps1') -WindowTitle $WindowTitle -Label $label -MaxDepth 32 -MaxChildrenPerNode 160 | Out-Null
    } else {
        & (Join-Path $scriptDir 'New-TosAutomationSnapshot.ps1') -Hwnd $Hwnd -WindowTitle $WindowTitle -Label $label -MaxDepth 32 -MaxChildrenPerNode 160 | Out-Null
    }
    $SnapshotJson = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-$label-*-tree.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($SnapshotJson)) { throw "Fresh snapshot JSON was not produced for label $label." }
}

$planPath = [System.IO.Path]::ChangeExtension($OutFile, ".plan.json")
& (Join-Path $scriptDir 'New-TosOrderRulesThresholdEditPlan.ps1') -SnapshotJson $SnapshotJson -ExpectedSymbol $ExpectedSymbol -ExpectedMethod $ExpectedMethod -ExpectedOperator $ExpectedOperator -NewThreshold $NewThreshold -OutFile $planPath | Out-Null
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]
foreach ($err in @($plan.errors)) { if (-not [string]::IsNullOrWhiteSpace($err)) { $errors.Add($err) | Out-Null } }
if ($plan.allowedToExecute -ne $true) { $errors.Add("Plan was not allowed to execute.") | Out-Null }
if (-not $plan.clickPoint) { $errors.Add("Plan did not produce a click point.") | Out-Null }

$result = [ordered]@{
    createdAt = (Get-Date).ToString("o")
    snapshot = $SnapshotJson
    hwnd = $Hwnd
    windowTitle = $WindowTitle
    planPath = $planPath
    expectedSymbol = $ExpectedSymbol
    expectedMethod = $ExpectedMethod
    expectedOperator = $ExpectedOperator
    newThreshold = [string]$NewThreshold
    allowInput = [bool]$AllowInput
    allowSave = [bool]$AllowSave
    executed = $false
    saveAttempted = $false
    saveClicked = $false
    postEditSnapshot = ""
    postEditVerified = $false
    saveClickPoint = $null
    clickPoint = $plan.clickPoint
    copiedValue = ""
    verifiedTypedValue = $false
    errors = @()
}

if ($AllowSave -and -not $AllowInput) { $errors.Add("AllowSave requires AllowInput.") | Out-Null }

if ($errors.Count -eq 0 -and $AllowInput) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TosNativeKeys {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const byte VK_CONTROL = 0x11;
    public const byte VK_A = 0x41;
    public const byte VK_C = 0x43;
    public const byte VK_V = 0x56;
    public const byte VK_TAB = 0x09;

    public static void LeftClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(70);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static void Press(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void Ctrl(byte vk) {
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
"@
    if (-not [string]::IsNullOrWhiteSpace($Hwnd)) {
        [TosNativeKeys]::SetForegroundWindow([IntPtr]([int64]$Hwnd)) | Out-Null
        Start-Sleep -Milliseconds 350
    }

    $previousClipboard = ""
    $hadClipboard = $false
    try {
        try {
            $previousClipboard = Get-Clipboard -Raw -ErrorAction Stop
            $hadClipboard = $true
        } catch {
            $hadClipboard = $false
        }

        $expectedText = ([string]$NewThreshold).Trim()
        $verifySentinel = "__TOS_VERIFY_EMPTY_$(Get-Date -Format yyyyMMddHHmmssfff)__"
        $x = [int]$plan.clickPoint.x
        $y = [int]$plan.clickPoint.y

        [TosNativeKeys]::LeftClick($x, $y)
        Start-Sleep -Milliseconds 200
        Set-Clipboard -Value $expectedText
        [TosNativeKeys]::Ctrl([TosNativeKeys]::VK_A)
        Start-Sleep -Milliseconds 100
        [TosNativeKeys]::Ctrl([TosNativeKeys]::VK_V)
        Start-Sleep -Milliseconds 150
        Set-Clipboard -Value $verifySentinel
        [TosNativeKeys]::Ctrl([TosNativeKeys]::VK_A)
        Start-Sleep -Milliseconds 100
        [TosNativeKeys]::Ctrl([TosNativeKeys]::VK_C)
        Start-Sleep -Milliseconds 200

        $copied = (Get-Clipboard -Raw).Trim()
        $result.copiedValue = $copied
        if ($copied -ne $expectedText) {
            $errors.Add("Typed value verification failed. Expected '$expectedText' but clipboard read '$copied'.") | Out-Null
        } else {
            $result.verifiedTypedValue = $true
            [TosNativeKeys]::Press([TosNativeKeys]::VK_TAB)
            Start-Sleep -Milliseconds 250
            $result.executed = $true

            if ($AllowSave) {
                $result.saveAttempted = $true
                $postLabel = "OrderRulesPostEdit-$($ExpectedSymbol -replace '[^A-Za-z0-9_.-]+', '-')"
                $discoveryDir = Join-Path $projectRoot 'TosAutomation\Discovery'
                if ([string]::IsNullOrWhiteSpace($Hwnd)) {
                    & (Join-Path $scriptDir 'New-TosAutomationSnapshot.ps1') -WindowTitle $WindowTitle -Label $postLabel -MaxDepth 32 -MaxChildrenPerNode 160 | Out-Null
                } else {
                    & (Join-Path $scriptDir 'New-TosAutomationSnapshot.ps1') -Hwnd $Hwnd -WindowTitle $WindowTitle -Label $postLabel -MaxDepth 32 -MaxChildrenPerNode 160 | Out-Null
                }
                $postJson = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-$postLabel-*-tree.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
                $result.postEditSnapshot = $postJson
                $postAnalysis = (& (Join-Path $scriptDir 'Read-TosOrderRulesSnapshot.ps1') -SnapshotJson $postJson) | ConvertFrom-Json
                if ($postAnalysis.inferred.submitAtChecked -eq $true) {
                    $errors.Add("Post-edit Submit at checkbox is checked; refusing Save click.") | Out-Null
                } elseif (-not $postAnalysis.inferred.hasSave) {
                    $errors.Add("Post-edit Save button was not found; refusing Save click.") | Out-Null
                } elseif ($postAnalysis.submitConditionRow.symbol -ne $ExpectedSymbol -or $postAnalysis.submitConditionRow.method -ne $ExpectedMethod -or $postAnalysis.submitConditionRow.operator -ne $ExpectedOperator) {
                    $errors.Add("Post-edit row verification failed before Save.") | Out-Null
                } else {
                    $result.postEditVerified = $true
                    $save = $postAnalysis.controls.saveButton
                    $saveX = [int]([int]$save.bounds.x + ([int]$save.bounds.width / 2))
                    $saveY = [int]([int]$save.bounds.y + ([int]$save.bounds.height / 2))
                    $result.saveClickPoint = [pscustomobject]@{ x = $saveX; y = $saveY }
                    [TosNativeKeys]::LeftClick($saveX, $saveY)
                    $result.saveClicked = $true
                }
            }
        }
    } finally {
        if ($hadClipboard) {
            try { Set-Clipboard -Value $previousClipboard } catch { }
        }
    }
} elseif ($errors.Count -eq 0) {
    $errors.Add("Dry run only. Re-run with -AllowInput to click/paste/verify, still without saving.") | Out-Null
}

$result.errors = @($errors)
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 12
Write-Host "Wrote threshold edit result to $OutFile"


