param(
    [string]$WindowTitle = "Main@thinkorswim",
    [string]$Path,
    [string]$ExpectedRole = "",
    [string]$ExpectedName = "",
    [string]$ActionName = "",
    [switch]$AllowAction,
    [string]$OutFile = "$PSScriptRoot\..\TosAutomation\Diagnostics\tos-jab-action-path.json"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Path)) { throw "Path is required." }

$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) {
    throw "Java Access Bridge DLL not found at $bridgeDll"
}

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosJabActionPath {
    private const string Bridge = @"C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll";
    public const int MAX_STRING_SIZE = 1024;
    public const int SHORT_STRING_SIZE = 256;
    public const int MAX_ACTION_INFO = 256;
    public const int MAX_ACTIONS_TO_DO = 32;

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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleActionInfo {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = SHORT_STRING_SIZE)]
        public string name;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleActions {
        public int actionsCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = MAX_ACTION_INFO)]
        public AccessibleActionInfo[] actionInfo;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleActionsToDo {
        public int actionsCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = MAX_ACTIONS_TO_DO)]
        public AccessibleActionInfo[] actions;
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
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

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "getAccessibleActions", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool getAccessibleActions(int vmID, IntPtr ac, ref AccessibleActions actions);

    [return: MarshalAs(UnmanagedType.U1)]
    [DllImport(Bridge, EntryPoint = "doAccessibleActions", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool doAccessibleActions(int vmID, IntPtr ac, ref AccessibleActionsToDo actionsToDo, out int failure);

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

[TosJabActionPath]::Windows_run()
[TosJabActionPath]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosJabActionPath+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosJabActionPath]::IsWindowVisible($hwnd)) {
        $title = [TosJabActionPath]::GetTitle($hwnd)
        if ($title -like "*$WindowTitle*") {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosJabActionPath]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
if ($matches.Count -eq 0) { throw "No visible window found with title containing '$WindowTitle'." }

$target = $matches[0]
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosJabActionPath]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get root context for '$($target.Title)'."
}

function Get-Info {
    param([IntPtr]$Ac)
    $info = New-Object TosJabActionPath+AccessibleContextInfo
    if (-not [TosJabActionPath]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) { return $null }
    return $info
}

$segments = @($Path -split "[./]" | Where-Object { $_ -ne "" })
if ($segments.Count -gt 1 -and $segments[0] -eq "0") {
    $segments = @($segments | Select-Object -Skip 1)
}

$current = $rootAc
$owned = New-Object System.Collections.Generic.List[IntPtr]
foreach ($part in $segments) {
    $idx = 0
    if (-not [int]::TryParse($part, [ref]$idx)) { throw "Bad path segment '$part'." }
    $parentInfo = Get-Info -Ac $current
    if ($null -eq $parentInfo) { throw "Unreadable parent while resolving '$Path'." }
    if ($idx -lt 0 -or $idx -ge $parentInfo.childrenCount) {
        throw "Index $idx out of range while resolving '$Path'; parent has $($parentInfo.childrenCount) children."
    }
    $child = [TosJabActionPath]::getAccessibleChildFromContext($vmID, $current, $idx)
    if ($child -eq [IntPtr]::Zero) { throw "Child $idx returned null while resolving '$Path'." }
    $owned.Add($child) | Out-Null
    $current = $child
}

$info = Get-Info -Ac $current
if ($null -eq $info) { throw "Target path resolved but context info could not be read." }
if ($ExpectedRole -ne "" -and $info.role_en_US -ne $ExpectedRole) {
    throw "Refusing action. Expected role '$ExpectedRole' but found '$($info.role_en_US)'."
}
if ($ExpectedName -ne "" -and $info.name -ne $ExpectedName) {
    throw "Refusing action. Expected name '$ExpectedName' but found '$($info.name)'."
}

$actions = New-Object TosJabActionPath+AccessibleActions
$actions.actionInfo = New-Object 'TosJabActionPath+AccessibleActionInfo[]' ([TosJabActionPath]::MAX_ACTION_INFO)
$gotActions = $false
$actionsError = ""
$available = @()
try {
    $gotActions = [TosJabActionPath]::getAccessibleActions($vmID, $current, [ref]$actions)
    if ($gotActions) {
        for ($i = 0; $i -lt $actions.actionsCount -and $i -lt [TosJabActionPath]::MAX_ACTION_INFO; $i++) {
            if (-not [string]::IsNullOrWhiteSpace($actions.actionInfo[$i].name)) { $available += $actions.actionInfo[$i].name }
        }
    }
} catch {
    $actionsError = $_.Exception.Message
}

$selectedAction = $ActionName
if ([string]::IsNullOrWhiteSpace($selectedAction) -and $available.Count -gt 0) {
    $preferred = @("toggle expand", "click")
    $selectedAction = @($preferred | Where-Object { $available -contains $_ } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($selectedAction)) { $selectedAction = $available[0] }
}

$actionResult = $false
$failureIndex = -1
if ($AllowAction) {
    if ([string]::IsNullOrWhiteSpace($selectedAction)) { throw "No AccessibleAction is available for target '$($info.name)'." }
    $todo = New-Object TosJabActionPath+AccessibleActionsToDo
    $todo.actionsCount = 1
    $todo.actions = New-Object 'TosJabActionPath+AccessibleActionInfo[]' ([TosJabActionPath]::MAX_ACTIONS_TO_DO)
    $todo.actions[0].name = $selectedAction
    $actionResult = [TosJabActionPath]::doAccessibleActions($vmID, $current, [ref]$todo, [ref]$failureIndex)
    [TosJabActionPath]::PumpMessages(1000)
}

$after = Get-Info -Ac $current
$result = [ordered]@{
    createdAt = (Get-Date).ToString("o")
    window = $target.Title
    path = $Path
    resolvedSegments = $segments
    expectedRole = $ExpectedRole
    expectedName = $ExpectedName
    role = $info.role_en_US
    name = $info.name
    beforeStates = $info.states_en_US
    bounds = [ordered]@{ x = $info.x; y = $info.y; width = $info.width; height = $info.height }
    gotActions = [bool]$gotActions
    actionsError = $actionsError
    availableActions = @($available)
    selectedAction = $selectedAction
    allowAction = [bool]$AllowAction
    actionResult = [bool]$actionResult
    failureIndex = $failureIndex
    afterStates = if ($null -eq $after) { "" } else { $after.states_en_US }
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 8
Write-Host "Wrote JAB action result to $OutFile"

foreach ($child in $owned) {
    [TosJabActionPath]::ReleaseJavaObject($vmID, $child)
}
