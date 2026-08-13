param(
    [string]$WindowTitle = "Order Rules",
    [string[]]$Path = @(
        "0/1/0/0/0/0/0/0/0/0/0/0/0",
        "0/1/0/0/0/0/0/0/0/1/0/0/3/1/0/0",
        "0/1/0/0/0/0/0/1/0/0/0/0",
        "0/1/0/0/0/0/0/1/1/0/0/12/0/2/0",
        "0/1/0/1/1/0",
        "0/1/0/1/1/1"
    ),
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-path-test.csv"
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

public static class TosJabPathTest {
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

[TosJabPathTest]::Windows_run()
[TosJabPathTest]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosJabPathTest+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosJabPathTest]::IsWindowVisible($hwnd)) {
        $title = [TosJabPathTest]::GetTitle($hwnd)
        if ($title -like "*$WindowTitle*") {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosJabPathTest]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

if ($matches.Count -eq 0) {
    throw "No visible window found with title containing '$WindowTitle'."
}

$target = $matches[0]
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosJabPathTest]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get the root accessible context for '$($target.Title)'."
}

function Get-Info {
    param([IntPtr]$Ac)
    $info = New-Object TosJabPathTest+AccessibleContextInfo
    if (-not [TosJabPathTest]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) {
        return $null
    }
    return $info
}

function Resolve-Path {
    param([string]$JabPath)

    $current = $rootAc
    $ownedChildren = New-Object System.Collections.Generic.List[IntPtr]
    $status = "OK"

    if (-not [string]::IsNullOrWhiteSpace($JabPath)) {
        foreach ($part in ($JabPath -split "/")) {
            $idx = 0
            if (-not [int]::TryParse($part, [ref]$idx)) {
                $status = "Bad path segment '$part'"
                break
            }

            $info = Get-Info -Ac $current
            if ($null -eq $info) {
                $status = "Unreadable parent"
                break
            }
            if ($idx -lt 0 -or $idx -ge $info.childrenCount) {
                $status = "Index $idx out of range; parent has $($info.childrenCount) children"
                break
            }

            $child = [TosJabPathTest]::getAccessibleChildFromContext($vmID, $current, $idx)
            if ($child -eq [IntPtr]::Zero) {
                $status = "Child $idx returned null"
                break
            }
            $ownedChildren.Add($child) | Out-Null
            $current = $child
        }
    }

    $finalInfo = if ($status -eq "OK") { Get-Info -Ac $current } else { $null }
    $row = if ($null -ne $finalInfo) {
        [pscustomobject]@{
            Window = $target.Title
            Path = $JabPath
            Status = $status
            Role = $finalInfo.role_en_US
            Name = $finalInfo.name
            Description = $finalInfo.description
            States = $finalInfo.states_en_US
            Bounds = "$($finalInfo.x),$($finalInfo.y),$($finalInfo.width),$($finalInfo.height)"
            Children = $finalInfo.childrenCount
            Action = $finalInfo.accessibleAction
            Text = $finalInfo.accessibleText
            Value = $finalInfo.accessibleValue
        }
    } else {
        [pscustomobject]@{
            Window = $target.Title
            Path = $JabPath
            Status = $status
            Role = ""
            Name = ""
            Description = ""
            States = ""
            Bounds = ""
            Children = ""
            Action = ""
            Text = ""
            Value = ""
        }
    }

    foreach ($child in $ownedChildren) {
        [TosJabPathTest]::ReleaseJavaObject($vmID, $child)
    }
    return $row
}

$rows = foreach ($p in $Path) { Resolve-Path -JabPath $p }

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$rows | Format-Table -AutoSize
Write-Host "Wrote path test results to $OutFile"
