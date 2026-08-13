param(
    [string]$WindowTitle = "Order Rules",
    [ValidateSet(">=", "<=")]
    [string]$Trigger = ">=",
    [Parameter(Mandatory = $true)]
    [decimal]$Threshold,
    [string]$Method = "MARK",
    [switch]$LeaveOpen,
    [switch]$AllowSave,
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-submit-condition-result.csv"
)

$ErrorActionPreference = "Stop"


$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) {
    throw "Java Access Bridge DLL not found at $bridgeDll"
}

$paths = @{
    SubmitAtCheckbox = "0/1/0/0/0/0/0/1/1/0/0/0"
    SubmitTable = "0/1/0/0/0/0/0/1/1/0/0/12/0/2/0"
    Save = "0/1/0/1/1/0"
    Cancel = "0/1/0/1/1/1"
}

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class TosSubmitCondition {
    private const string Bridge = @"C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll";
    public const int MAX_STRING_SIZE = 1024;
    public const int SHORT_STRING_SIZE = 256;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleContextInfo {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MAX_STRING_SIZE)]
        public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MAX_STRING_SIZE)]
        public string description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)]
        public string role;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)]
        public string role_en_US;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)]
        public string states;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)]
        public string states_en_US;
        public int indexInParent;
        public int childrenCount;
        public int x;
        public int y;
        public int width;
        public int height;
        public int accessibleComponent;
        public int accessibleAction;
        public int accessibleSelection;
        public int accessibleText;
        public int accessibleValue;
        public int accessibleInterfaces;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);

    [DllImport(Bridge, EntryPoint = "Windows_run", CallingConvention = CallingConvention.Cdecl)]
    public static extern void Windows_run();

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleContextFromHWND", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleContextFromHWND(IntPtr hWnd, out int vmID, out IntPtr ac);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleContextInfo", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleContextInfo(int vmID, IntPtr ac, ref AccessibleContextInfo info);

    [DllImport(Bridge, EntryPoint = "getAccessibleChildFromContext", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr getAccessibleChildFromContext(int vmID, IntPtr ac, int childIndex);

    [DllImport(Bridge, EntryPoint = "releaseJavaObject", CallingConvention = CallingConvention.Cdecl)]
    public static extern void ReleaseJavaObject(int vmID, IntPtr javaObject);

    public static string GetTitle(IntPtr hwnd) {
        var sb = new StringBuilder(512);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static void PumpMessages(int milliseconds) {
        var until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        MSG msg;
        while (DateTime.UtcNow < until) {
            while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
            System.Threading.Thread.Sleep(15);
        }
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        PumpMessages(400);
    }

    public static void TypeText(string text) {
        SendKeys.SendWait("^a");
        System.Threading.Thread.Sleep(100);
        SendKeys.SendWait(text);
        PumpMessages(500);
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms

[TosSubmitCondition]::Windows_run()
[TosSubmitCondition]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosSubmitCondition+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosSubmitCondition]::IsWindowVisible($hwnd)) {
        $title = [TosSubmitCondition]::GetTitle($hwnd)
        if ($title -like "*$WindowTitle*") {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosSubmitCondition]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
if ($matches.Count -eq 0) {
    throw "No visible '$WindowTitle' window found. Open a TOS Order Rules dialog before running this script."
}

$target = $matches[0]
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosSubmitCondition]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get root context for '$($target.Title)'."
}

function Get-Info {
    param([IntPtr]$Ac)
    $info = New-Object TosSubmitCondition+AccessibleContextInfo
    if (-not [TosSubmitCondition]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) {
        return $null
    }
    return $info
}

function Resolve-Path {
    param([string]$JabPath)

    $current = $rootAc
    $owned = New-Object System.Collections.Generic.List[IntPtr]
    foreach ($part in ($JabPath -split "/")) {
        $idx = 0
        if (-not [int]::TryParse($part, [ref]$idx)) {
            throw "Bad JAB path segment '$part'."
        }
        $parentInfo = Get-Info -Ac $current
        if ($null -eq $parentInfo -or $idx -lt 0 -or $idx -ge $parentInfo.childrenCount) {
            throw "Could not resolve '$JabPath' at segment '$idx'."
        }
        $child = [TosSubmitCondition]::getAccessibleChildFromContext($vmID, $current, $idx)
        if ($child -eq [IntPtr]::Zero) {
            throw "Child '$idx' returned null while resolving '$JabPath'."
        }
        $owned.Add($child) | Out-Null
        $current = $child
    }
    return [pscustomobject]@{ Ac = $current; Owned = $owned }
}

function Click-Resolved {
    param(
        [string]$JabPath,
        [string]$ExpectedRole = "",
        [string]$ExpectedName = ""
    )

    $resolved = Resolve-Path -JabPath $JabPath
    $info = Get-Info -Ac $resolved.Ac
    if ($ExpectedRole -ne "" -and $info.role_en_US -ne $ExpectedRole) {
        throw "Refusing click for '$JabPath'. Expected role '$ExpectedRole' but got '$($info.role_en_US)'."
    }
    if ($ExpectedName -ne "" -and $info.name -ne $ExpectedName) {
        throw "Refusing click for '$JabPath'. Expected name '$ExpectedName' but got '$($info.name)'."
    }
    if ($info.x -lt 0 -or $info.y -lt 0 -or $info.width -le 0 -or $info.height -le 0) {
        throw "Refusing click for '$JabPath'. Invalid bounds $($info.x),$($info.y),$($info.width),$($info.height)."
    }

    $x = [int]($info.x + ($info.width / 2))
    $y = [int]($info.y + ($info.height / 2))
    [TosSubmitCondition]::Click($x, $y)
    foreach ($child in $resolved.Owned) {
        [TosSubmitCondition]::ReleaseJavaObject($vmID, $child)
    }
    return [pscustomobject]@{ Path = $JabPath; Role = $info.role_en_US; Name = $info.name; Bounds = "$($info.x),$($info.y),$($info.width),$($info.height)"; ClickX = $x; ClickY = $y }
}

function Find-NodeByName {
    param(
        [IntPtr]$Ac,
        [string]$Name,
        [string]$Role = "",
        [int]$Depth = 0,
        [int]$MaxDepth = 30
    )

    if ($Depth -gt $MaxDepth -or $Ac -eq [IntPtr]::Zero) { return $null }
    $info = Get-Info -Ac $Ac
    if ($null -eq $info) { return $null }
    if ($info.name -eq $Name -and ($Role -eq "" -or $info.role_en_US -eq $Role)) {
        return [pscustomobject]@{ Ac = $Ac; Info = $info }
    }

    for ($i = 0; $i -lt $info.childrenCount; $i++) {
        $child = [TosSubmitCondition]::getAccessibleChildFromContext($vmID, $Ac, $i)
        if ($child -ne [IntPtr]::Zero) {
            $found = Find-NodeByName -Ac $child -Name $Name -Role $Role -Depth ($Depth + 1) -MaxDepth $MaxDepth
            if ($null -ne $found) { return $found }
            [TosSubmitCondition]::ReleaseJavaObject($vmID, $child)
        }
    }
    return $null
}

$steps = New-Object System.Collections.Generic.List[object]

$submitAt = Resolve-Path -JabPath $paths.SubmitAtCheckbox
$submitAtInfo = Get-Info -Ac $submitAt.Ac
if ($submitAtInfo.role_en_US -ne "check box") {
    throw "Refusing to continue. Submit-at guard resolved to '$($submitAtInfo.role_en_US)' instead of check box."
}
if ($submitAtInfo.states_en_US -like "*checked*") {
    # This is the date/time gate. It must stay off for OCO conditional stop/target updates.
    $x = [int]($submitAtInfo.x + ($submitAtInfo.width / 2))
    $y = [int]($submitAtInfo.y + ($submitAtInfo.height / 2))
    [TosSubmitCondition]::Click($x, $y)
    [TosSubmitCondition]::PumpMessages(500)
    $steps.Add([pscustomobject]@{ Step = "DisableSubmitAt"; Detail = "Unchecked Submit at at $x,$y" }) | Out-Null
} else {
    $steps.Add([pscustomobject]@{ Step = "VerifySubmitAtOff"; Detail = "Submit at is already unchecked." }) | Out-Null
}
foreach ($child in $submitAt.Owned) {
    [TosSubmitCondition]::ReleaseJavaObject($vmID, $child)
}

# The symbol cell is the first cell in the visible submit-condition table. Opening it lets TOS populate the order's underlying symbol.
$table = Resolve-Path -JabPath $paths.SubmitTable
$tableInfo = Get-Info -Ac $table.Ac
if ($tableInfo.x -lt 0 -or $tableInfo.y -lt 0 -or $tableInfo.width -le 0 -or $tableInfo.height -le 0) {
    throw "Submit condition table has invalid bounds."
}
$symbolX = [int]($tableInfo.x + 54)
$rowY = [int]($tableInfo.y + 8)
[TosSubmitCondition]::Click($symbolX, $rowY)
[TosSubmitCondition]::PumpMessages(500)
[System.Windows.Forms.SendKeys]::SendWait("{TAB}")
[TosSubmitCondition]::PumpMessages(800)
$steps.Add([pscustomobject]@{ Step = "OpenSymbolAndTab"; Detail = "Clicked $symbolX,$rowY then Tab" }) | Out-Null

# Re-resolve after the row has been created. The table expands from five empty labels to rich controls.
$table2 = Resolve-Path -JabPath $paths.SubmitTable
$table2Info = Get-Info -Ac $table2.Ac
$methodX = [int]($table2Info.x + 160)
$triggerX = [int]($table2Info.x + 270)
$thresholdX = [int]($table2Info.x + 395)
$rowY2 = [int]($table2Info.y + 8)

if ($Method -ne "MARK") {
    throw "Only Method=MARK is supported by this first routine. Requested '$Method'."
}

[TosSubmitCondition]::Click($triggerX, $rowY2)
[TosSubmitCondition]::PumpMessages(600)
$triggerOption = Find-NodeByName -Ac $rootAc -Name $Trigger -Role "label"
if ($null -eq $triggerOption) {
    throw "Could not find expanded trigger option '$Trigger'."
}
$triggerInfo = $triggerOption.Info
if ($triggerInfo.x -lt 0 -or $triggerInfo.y -lt 0 -or $triggerInfo.width -le 0 -or $triggerInfo.height -le 0) {
    throw "Trigger option '$Trigger' has invalid bounds."
}
[TosSubmitCondition]::Click(([int]($triggerInfo.x + ($triggerInfo.width / 2))), ([int]($triggerInfo.y + ($triggerInfo.height / 2))))
$steps.Add([pscustomobject]@{ Step = "SetTrigger"; Detail = "$Trigger via $($triggerInfo.x),$($triggerInfo.y),$($triggerInfo.width),$($triggerInfo.height)" }) | Out-Null

[TosSubmitCondition]::Click($thresholdX, $rowY2)
[TosSubmitCondition]::TypeText($Threshold.ToString("0.##", [Globalization.CultureInfo]::InvariantCulture))
$steps.Add([pscustomobject]@{ Step = "SetThreshold"; Detail = "$Threshold at $thresholdX,$rowY2" }) | Out-Null

if ($AllowSave) {
    $saveClick = Click-Resolved -JabPath $paths.Save -ExpectedRole "push button" -ExpectedName "Save"
    $steps.Add([pscustomobject]@{ Step = "Save"; Detail = ($saveClick | ConvertTo-Json -Compress) }) | Out-Null
} elseif (-not $LeaveOpen) {
    $cancelClick = Click-Resolved -JabPath $paths.Cancel -ExpectedRole "push button" -ExpectedName "Cancel"
    $steps.Add([pscustomobject]@{ Step = "Cancel"; Detail = ($cancelClick | ConvertTo-Json -Compress) }) | Out-Null
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$steps | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$steps | Format-Table -AutoSize
Write-Host "Wrote submit-condition result to $OutFile"
