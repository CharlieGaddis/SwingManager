param(
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-java-windows.csv"
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

public static class TosJavaWindows {
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
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);

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

[TosJavaWindows]::Windows_run()
[TosJavaWindows]::PumpMessages(3000)

$rows = New-Object System.Collections.Generic.List[object]
$callback = [TosJavaWindows+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    $title = [TosJavaWindows]::GetTitle($hwnd)
    $isVisible = [TosJavaWindows]::IsWindowVisible($hwnd)
    $isJava = [TosJavaWindows]::isJavaWindow($hwnd)
    $vmID = 0
    $rootAc = [IntPtr]::Zero
    $rootName = ""
    $rootRole = ""
    $bounds = ""
    $children = ""
    $hasContext = $false
    if ($isJava) {
        $hasContext = [TosJavaWindows]::getAccessibleContextFromHWND($hwnd, [ref]$vmID, [ref]$rootAc)
        if ($hasContext) {
            $info = New-Object TosJavaWindows+AccessibleContextInfo
            if ([TosJavaWindows]::getAccessibleContextInfo($vmID, $rootAc, [ref]$info)) {
                $rootName = $info.name
                $rootRole = $info.role_en_US
                $bounds = "$($info.x),$($info.y),$($info.width),$($info.height)"
                $children = [string]$info.childrenCount
            }
        }
    }
    if ($isJava -or $title -match "think|tos|Order|Schwab") {
        $rows.Add([pscustomobject]@{
            Hwnd = [string]$hwnd
            Visible = $isVisible
            IsJava = $isJava
            HasContext = $hasContext
            Title = $title
            VmId = $vmID
            RootName = $rootName
            RootRole = $rootRole
            Bounds = $bounds
            Children = $children
        }) | Out-Null
    }
    return $true
}
[TosJavaWindows]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation
$rows | Format-Table -AutoSize
