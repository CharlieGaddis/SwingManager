param(
    [ValidateSet("Move", "Click", "RightClick", "DoubleClick", "Wheel", "Keys")]
    [string]$Action = "Move",
    [int]$X = 0,
    [int]$Y = 0,
    [int]$WheelDelta = 0,
    [string]$Keys = "",
    [switch]$AllowInput,
    [string]$OutFile = "$PSScriptRoot\..\TosAutomation\Diagnostics\tos-native-input-result.csv"
)

$ErrorActionPreference = "Stop"

$code = @"
using System;
using System.Runtime.InteropServices;

public static class TosNativeInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void LeftClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(70);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(70);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Wheel(int x, int y, int delta) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(0x0800, 0, 0, unchecked((uint)delta), UIntPtr.Zero);
        System.Threading.Thread.Sleep(160);
    }
}
"@
Add-Type -TypeDefinition $code
Add-Type -AssemblyName System.Windows.Forms

if (-not $AllowInput) {
    $result = [pscustomobject]@{
        Action = $Action
        X = $X
        Y = $Y
        Keys = $Keys
        AllowInput = $false
        Executed = $false
        Message = "Dry run only. Re-run with -AllowInput to send native input."
    }
} else {
    switch ($Action) {
        "Move" { [TosNativeInput]::SetCursorPos($X, $Y) | Out-Null }
        "Click" { [TosNativeInput]::LeftClick($X, $Y) }
        "RightClick" { [TosNativeInput]::RightClick($X, $Y) }
        "DoubleClick" { [TosNativeInput]::LeftClick($X, $Y); Start-Sleep -Milliseconds 120; [TosNativeInput]::LeftClick($X, $Y) }
        "Wheel" {
            if ($WheelDelta -eq 0) { throw "WheelDelta is required for Action=Wheel." }
            [TosNativeInput]::Wheel($X, $Y, $WheelDelta)
        }
        "Keys" {
            if ([string]::IsNullOrWhiteSpace($Keys)) { throw "Keys is required for Action=Keys." }
            [System.Windows.Forms.SendKeys]::SendWait($Keys)
        }
    }
    $result = [pscustomobject]@{
        Action = $Action
        X = $X
        Y = $Y
        WheelDelta = $WheelDelta
        Keys = $Keys
        AllowInput = $true
        Executed = $true
        Message = "Native input sent. Caller must rediscover and verify state before continuing."
    }
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$result | Format-List
