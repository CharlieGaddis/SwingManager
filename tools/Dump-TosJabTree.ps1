param(
    [string]$WindowTitle = "Order Rules",
    [string]$Hwnd = "",
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-tree.txt",
    [int]$MaxDepth = 40,
    [int]$MaxChildrenPerNode = 200
)

$ErrorActionPreference = "Stop"

$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) {
    throw "Java Access Bridge DLL not found at $bridgeDll"
}

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosJab {
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

    [DllImport(Bridge, EntryPoint = "Windows_run", CallingConvention = CallingConvention.Cdecl)]
    public static extern void Windows_run();

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "isJavaWindow", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool isJavaWindow(IntPtr hWnd);

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

[TosJab]::Windows_run()
[TosJab]::PumpMessages(3000)

$target = $null
if (-not [string]::IsNullOrWhiteSpace($Hwnd)) {
    $targetHwnd = [IntPtr]([int64]$Hwnd)
    $target = [pscustomobject]@{ Hwnd = $targetHwnd; Title = [TosJab]::GetTitle($targetHwnd) }
} else {
    $matches = New-Object System.Collections.Generic.List[object]
    $callback = [TosJab+EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$lparam)
        if ([TosJab]::IsWindowVisible($hwnd)) {
            $title = [TosJab]::GetTitle($hwnd)
            if ($title -like "*$WindowTitle*") {
                $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
            }
        }
        return $true
    }
    [TosJab]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

    if ($matches.Count -eq 0) {
        throw "No visible window found with title containing '$WindowTitle'."
    }

    $target = $matches[0]
}
$isJava = [TosJab]::isJavaWindow($target.Hwnd)
Write-Host "Matched window '$($target.Title)' HWND=$($target.Hwnd) IsJavaWindow=$isJava"
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosJab]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get the root accessible context for '$($target.Title)'."
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Window: $($target.Title)") | Out-Null
$lines.Add("HWND: $($target.Hwnd)  VMID: $vmID  RootAC: $rootAc") | Out-Null
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
$lines.Add("") | Out-Null

function Add-Node {
    param(
        [int]$Depth,
        [IntPtr]$Ac
    )

    if ($Depth -gt $MaxDepth -or $Ac -eq [IntPtr]::Zero) { return }

    $info = New-Object TosJab+AccessibleContextInfo
    if (-not [TosJab]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) {
        $lines.Add(("{0}- <unreadable ac={1}>" -f ("  " * $Depth), $Ac)) | Out-Null
        return
    }

    $name = if ([string]::IsNullOrWhiteSpace($info.name)) { "" } else { " name=`"$($info.name)`"" }
    $desc = if ([string]::IsNullOrWhiteSpace($info.description)) { "" } else { " desc=`"$($info.description)`"" }
    $states = if ([string]::IsNullOrWhiteSpace($info.states_en_US)) { "" } else { " states=`"$($info.states_en_US)`"" }
    $bounds = " bounds=$($info.x),$($info.y),$($info.width),$($info.height)"
    $flags = " comp=$($info.accessibleComponent) act=$($info.accessibleAction) text=$($info.accessibleText) value=$($info.accessibleValue)"
    $lines.Add(("{0}- role=`"{1}`"{2}{3} children={4}{5}{6}" -f ("  " * $Depth), $info.role_en_US, $name, $desc, $info.childrenCount, $bounds, $states + $flags)) | Out-Null

    $childCount = [Math]::Min($info.childrenCount, $MaxChildrenPerNode)
    for ($i = 0; $i -lt $childCount; $i++) {
        $child = [TosJab]::getAccessibleChildFromContext($vmID, $Ac, $i)
        if ($child -ne [IntPtr]::Zero) {
            Add-Node -Depth ($Depth + 1) -Ac $child
            [TosJab]::ReleaseJavaObject($vmID, $child)
        }
    }
    if ($info.childrenCount -gt $MaxChildrenPerNode) {
        $lines.Add(("{0}- ... skipped {1} more children" -f ("  " * ($Depth + 1)), ($info.childrenCount - $MaxChildrenPerNode))) | Out-Null
    }
}

Add-Node -Depth 0 -Ac $rootAc

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "Wrote Java Access Bridge tree to $OutFile"
