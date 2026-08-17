param(
    [string]$WindowTitle = "Order Rules",
    [string]$Path = "0/1/0/0/0/0/0/0/0/1/0/0/3/1/0/0",
    [string]$Text = "-6",
    [string]$ExpectedRole = "text",
    [switch]$DryRun,
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-set-text-test.csv"
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

public static class TosJabSetText {
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
    public struct AccessibleTextInfo {
        public int charCount;
        public int caretIndex;
        public int indexAtPoint;
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
    [DllImport(Bridge, EntryPoint = "getAccessibleContextFromHWND", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleContextFromHWND(IntPtr hWnd, out int vmID, out IntPtr ac);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleContextInfo", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleContextInfo(int vmID, IntPtr ac, ref AccessibleContextInfo info);

    [DllImport(Bridge, EntryPoint = "getAccessibleChildFromContext", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr getAccessibleChildFromContext(int vmID, IntPtr ac, int childIndex);

    [DllImport(Bridge, EntryPoint = "releaseJavaObject", CallingConvention = CallingConvention.Cdecl)]
    public static extern void ReleaseJavaObject(int vmID, IntPtr javaObject);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "requestFocus", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool requestFocus(int vmID, IntPtr ac);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "setTextContents", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    public static extern bool setTextContents(int vmID, IntPtr ac, string text);

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

[TosJabSetText]::Windows_run()
[TosJabSetText]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosJabSetText+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosJabSetText]::IsWindowVisible($hwnd)) {
        $title = [TosJabSetText]::GetTitle($hwnd)
        if ($title.IndexOf($WindowTitle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosJabSetText]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
if ($matches.Count -eq 0) {
    throw "No visible window found with title containing '$WindowTitle'."
}

$target = $matches[0]
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosJabSetText]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get root context for '$($target.Title)'."
}

function Get-Info {
    param([IntPtr]$Ac)
    $info = New-Object TosJabSetText+AccessibleContextInfo
    if (-not [TosJabSetText]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) {
        return $null
    }
    return $info
}

function Resolve-Path {
    param([string]$JabPath)

    $current = $rootAc
    $ownedChildren = New-Object System.Collections.Generic.List[IntPtr]
    foreach ($part in ($JabPath -split "/")) {
        $idx = 0
        if (-not [int]::TryParse($part, [ref]$idx)) {
            throw "Bad path segment '$part'"
        }
        $parentInfo = Get-Info -Ac $current
        if ($null -eq $parentInfo) {
            throw "Unreadable parent while resolving '$JabPath'"
        }
        if ($idx -lt 0 -or $idx -ge $parentInfo.childrenCount) {
            throw "Index $idx out of range while resolving '$JabPath'; parent has $($parentInfo.childrenCount) children."
        }
        $child = [TosJabSetText]::getAccessibleChildFromContext($vmID, $current, $idx)
        if ($child -eq [IntPtr]::Zero) {
            throw "Child $idx returned null while resolving '$JabPath'."
        }
        $ownedChildren.Add($child) | Out-Null
        $current = $child
    }
    return [pscustomobject]@{ Ac = $current; Owned = $ownedChildren }
}

function Get-TextValue {
    param([IntPtr]$Ac)

    $textInfo = New-Object TosJabSetText+AccessibleTextInfo
    if (-not [TosJabSetText]::getAccessibleTextInfo($vmID, $Ac, [ref]$textInfo, 0, 0)) {
        return ""
    }
    if ($textInfo.charCount -le 0) {
        return ""
    }
    $len = [Math]::Min($textInfo.charCount, 1023)
    $buffer = New-Object System.Text.StringBuilder 1024
    if (-not [TosJabSetText]::getAccessibleTextRange($vmID, $Ac, 0, $len, $buffer, [int16]1024)) {
        return ""
    }
    return $buffer.ToString()
}

$resolved = Resolve-Path -JabPath $Path
$infoBefore = Get-Info -Ac $resolved.Ac
if ($null -eq $infoBefore) {
    throw "Target path resolved but context info could not be read."
}
if ($infoBefore.role_en_US -ne $ExpectedRole) {
    throw "Refusing to set text. Expected role '$ExpectedRole' but found '$($infoBefore.role_en_US)'."
}
if ($infoBefore.accessibleText -eq 0) {
    throw "Refusing to set text. Target role '$($infoBefore.role_en_US)' is not marked accessibleText."
}
if ($infoBefore.states_en_US -notmatch "editable") {
    throw "Refusing to set text. Target states do not include editable: '$($infoBefore.states_en_US)'."
}

$beforeText = Get-TextValue -Ac $resolved.Ac
$focusOk = $false
$setOk = $false
if (-not $DryRun) {
    $focusOk = [TosJabSetText]::requestFocus($vmID, $resolved.Ac)
    [TosJabSetText]::PumpMessages(500)
    $setOk = [TosJabSetText]::setTextContents($vmID, $resolved.Ac, $Text)
    [TosJabSetText]::PumpMessages(500)
}
$afterText = Get-TextValue -Ac $resolved.Ac
$infoAfter = Get-Info -Ac $resolved.Ac

$row = [pscustomobject]@{
    Window = $target.Title
    Path = $Path
    DryRun = [bool]$DryRun
    Role = $infoBefore.role_en_US
    Name = $infoBefore.name
    BeforeStates = $infoBefore.states_en_US
    BeforeBounds = "$($infoBefore.x),$($infoBefore.y),$($infoBefore.width),$($infoBefore.height)"
    BeforeText = $beforeText
    RequestedText = $Text
    FocusOk = $focusOk
    SetTextOk = $setOk
    AfterText = $afterText
    AfterStates = if ($null -eq $infoAfter) { "" } else { $infoAfter.states_en_US }
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$row | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$row | Format-List
Write-Host "Wrote set-text test result to $OutFile"

foreach ($child in $resolved.Owned) {
    [TosJabSetText]::ReleaseJavaObject($vmID, $child)
}
