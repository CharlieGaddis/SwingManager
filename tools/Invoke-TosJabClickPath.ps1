param(
    [string]$WindowTitle = "Order Rules",
    [string]$Path,
    [string]$ExpectedRole = "",
    [string]$ExpectedName = "",
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-click-path-test.csv"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Path is required."
}

$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) {
    throw "Java Access Bridge DLL not found at $bridgeDll"
}

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosJabClickPath {
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

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

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

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

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
}
"@

Add-Type -TypeDefinition $code

[TosJabClickPath]::Windows_run()
[TosJabClickPath]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosJabClickPath+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosJabClickPath]::IsWindowVisible($hwnd)) {
        $title = [TosJabClickPath]::GetTitle($hwnd)
        if ($title -like "*$WindowTitle*") {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosJabClickPath]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
if ($matches.Count -eq 0) {
    throw "No visible window found with title containing '$WindowTitle'."
}

$target = $matches[0]
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosJabClickPath]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get root context for '$($target.Title)'."
}

function Get-Info {
    param([IntPtr]$Ac)
    $info = New-Object TosJabClickPath+AccessibleContextInfo
    if (-not [TosJabClickPath]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) {
        return $null
    }
    return $info
}

$current = $rootAc
$owned = New-Object System.Collections.Generic.List[IntPtr]
foreach ($part in ($Path -split "/")) {
    $idx = 0
    if (-not [int]::TryParse($part, [ref]$idx)) {
        throw "Bad path segment '$part'"
    }
    $parentInfo = Get-Info -Ac $current
    if ($idx -lt 0 -or $idx -ge $parentInfo.childrenCount) {
        throw "Index $idx out of range; parent has $($parentInfo.childrenCount) children."
    }
    $child = [TosJabClickPath]::getAccessibleChildFromContext($vmID, $current, $idx)
    if ($child -eq [IntPtr]::Zero) {
        throw "Child $idx returned null."
    }
    $owned.Add($child) | Out-Null
    $current = $child
}

$info = Get-Info -Ac $current
if ($null -eq $info) {
    throw "Target path resolved but context info could not be read."
}
if ($ExpectedRole -ne "" -and $info.role_en_US -ne $ExpectedRole) {
    throw "Refusing to click. Expected role '$ExpectedRole' but found '$($info.role_en_US)'."
}
if ($ExpectedName -ne "" -and $info.name -ne $ExpectedName) {
    throw "Refusing to click. Expected name '$ExpectedName' but found '$($info.name)'."
}
if ($info.x -lt 0 -or $info.y -lt 0 -or $info.width -le 0 -or $info.height -le 0) {
    throw "Refusing to click. Target has invalid bounds $($info.x),$($info.y),$($info.width),$($info.height)."
}

$clickX = [int]($info.x + ($info.width / 2))
$clickY = [int]($info.y + ($info.height / 2))
[TosJabClickPath]::SetCursorPos($clickX, $clickY) | Out-Null
Start-Sleep -Milliseconds 100
[TosJabClickPath]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[TosJabClickPath]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
[TosJabClickPath]::PumpMessages(700)

$after = Get-Info -Ac $current
$row = [pscustomobject]@{
    Window = $target.Title
    Path = $Path
    Role = $info.role_en_US
    Name = $info.name
    BeforeStates = $info.states_en_US
    Bounds = "$($info.x),$($info.y),$($info.width),$($info.height)"
    ClickX = $clickX
    ClickY = $clickY
    AfterStates = if ($null -eq $after) { "" } else { $after.states_en_US }
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$row | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$row | Format-List
Write-Host "Wrote click-path result to $OutFile"

foreach ($child in $owned) {
    [TosJabClickPath]::ReleaseJavaObject($vmID, $child)
}
