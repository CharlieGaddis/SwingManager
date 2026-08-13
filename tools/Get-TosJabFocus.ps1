param(
    [string]$WindowTitle = "Order Rules",
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-focus.csv"
)

$ErrorActionPreference = "Stop"

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosJabFocus {
    private const string Bridge = @"C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll";
    public const int MAX_STRING_SIZE = 1024;
    public const int SHORT_STRING_SIZE = 256;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleContextInfo {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MAX_STRING_SIZE)] public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MAX_STRING_SIZE)] public string description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)] public string role;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)] public string role_en_US;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)] public string states;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)] public string states_en_US;
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
    public struct AccessibleTextInfo {
        public int charCount;
        public int caretIndex;
        public int indexAtPoint;
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);

    [DllImport(Bridge, EntryPoint = "Windows_run", CallingConvention = CallingConvention.Cdecl)]
    public static extern void Windows_run();

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleContextWithFocus", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleContextWithFocus(IntPtr hWnd, out int vmID, out IntPtr ac);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleContextInfo", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleContextInfo(int vmID, IntPtr ac, ref AccessibleContextInfo info);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleTextInfo", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleTextInfo(int vmID, IntPtr ac, ref AccessibleTextInfo info, int x, int y);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleTextRange", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    public static extern bool getAccessibleTextRange(int vmID, IntPtr ac, int start, int end, StringBuilder text, short len);

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

[TosJabFocus]::Windows_run()
[TosJabFocus]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosJabFocus+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosJabFocus]::IsWindowVisible($hwnd)) {
        $title = [TosJabFocus]::GetTitle($hwnd)
        if ($title -like "*$WindowTitle*") {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosJabFocus]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
if ($matches.Count -eq 0) {
    throw "No visible window found with title containing '$WindowTitle'."
}

$target = $matches[0]
$vmID = 0
$ac = [IntPtr]::Zero
if (-not [TosJabFocus]::getAccessibleContextWithFocus($target.Hwnd, [ref]$vmID, [ref]$ac)) {
    throw "Could not get focused Java accessible context for '$($target.Title)'."
}

$info = New-Object TosJabFocus+AccessibleContextInfo
if (-not [TosJabFocus]::getAccessibleContextInfo($vmID, $ac, [ref]$info)) {
    throw "Focused context was returned but info could not be read."
}

$textValue = ""
if ($info.accessibleText -ne 0) {
    $textInfo = New-Object TosJabFocus+AccessibleTextInfo
    if ([TosJabFocus]::getAccessibleTextInfo($vmID, $ac, [ref]$textInfo, 0, 0) -and $textInfo.charCount -gt 0) {
        $buffer = New-Object System.Text.StringBuilder 1024
        $len = [Math]::Min($textInfo.charCount, 1023)
        if ([TosJabFocus]::getAccessibleTextRange($vmID, $ac, 0, $len, $buffer, [int16]1024)) {
            $textValue = $buffer.ToString()
        }
    }
}

$row = [pscustomobject]@{
    Window = $target.Title
    Role = $info.role_en_US
    Name = $info.name
    Description = $info.description
    States = $info.states_en_US
    Bounds = "$($info.x),$($info.y),$($info.width),$($info.height)"
    Children = $info.childrenCount
    Action = $info.accessibleAction
    Text = $info.accessibleText
    TextValue = $textValue
    Value = $info.accessibleValue
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$row | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$row | Format-List
Write-Host "Wrote focus result to $OutFile"
