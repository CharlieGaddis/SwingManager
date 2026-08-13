param(
    [string]$WindowTitle = "Main@thinkorswim [build 1992]",
    [string]$ExpectedSymbol = "ETSY",
    [string]$ExpectedSide = "SELL",
    [string]$ExpectedQuantity = "-3",
    [string]$RowTablePath = "0/0/1/2/0/1/1/0/0/1/1/0/0/1/0/1/0/0/0/0/0/0/0",
    [int]$MaxSearchDepth = 35,
    [int]$MaxSearchNodes = 90000,
    [int]$OrderRulesOffsetX = 754,
    [switch]$DryRun,
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-open-order-rules-result.csv"
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

public static class TosOpenOrderRules {
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
        System.Threading.Thread.Sleep(120);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        PumpMessages(900);
    }
}
"@

Add-Type -TypeDefinition $code

[TosOpenOrderRules]::Windows_run()
[TosOpenOrderRules]::PumpMessages(3000)

$matches = New-Object System.Collections.Generic.List[object]
$callback = [TosOpenOrderRules+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    if ([TosOpenOrderRules]::IsWindowVisible($hwnd)) {
        $title = [TosOpenOrderRules]::GetTitle($hwnd)
        if ($title -eq $WindowTitle) {
            $matches.Add([pscustomobject]@{ Hwnd = $hwnd; Title = $title }) | Out-Null
        }
    }
    return $true
}
[TosOpenOrderRules]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

if ($matches.Count -eq 0) {
    throw "No exact visible TOS window found with title '$WindowTitle'."
}

$target = $matches[0]
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosOpenOrderRules]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Java Access Bridge could not get root context for '$($target.Title)'."
}

function Get-Info {
    param([IntPtr]$Ac)
    $info = New-Object TosOpenOrderRules+AccessibleContextInfo
    if (-not [TosOpenOrderRules]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) {
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
        if ($null -eq $parentInfo) {
            throw "Unreadable parent while resolving '$JabPath'."
        }
        if ($idx -lt 0 -or $idx -ge $parentInfo.childrenCount) {
            throw "Index $idx out of range while resolving '$JabPath'; parent has $($parentInfo.childrenCount) children."
        }
        $child = [TosOpenOrderRules]::getAccessibleChildFromContext($vmID, $current, $idx)
        if ($child -eq [IntPtr]::Zero) {
            throw "Child $idx returned null while resolving '$JabPath'."
        }
        $owned.Add($child) | Out-Null
        $current = $child
    }
    return [pscustomobject]@{ Ac = $current; Owned = $owned }
}

function Find-NameInSubtree {
    param(
        [IntPtr]$Ac,
        [string]$Name,
        [int]$Depth = 0,
        [int]$MaxDepth = 12
    )

    if ($Depth -gt $MaxDepth -or $Ac -eq [IntPtr]::Zero) { return $false }
    $info = Get-Info -Ac $Ac
    if ($null -eq $info) { return $false }
    if ($info.name -eq $Name) { return $true }
    for ($i = 0; $i -lt $info.childrenCount; $i++) {
        $child = [TosOpenOrderRules]::getAccessibleChildFromContext($vmID, $Ac, $i)
        if ($child -ne [IntPtr]::Zero) {
            $found = Find-NameInSubtree -Ac $child -Name $Name -Depth ($Depth + 1) -MaxDepth $MaxDepth
            [TosOpenOrderRules]::ReleaseJavaObject($vmID, $child)
            if ($found) { return $true }
        }
    }
    return $false
}

$visitedNodes = 0
function Find-MatchingOrderRowTable {
    param(
        [IntPtr]$Ac,
        [int]$Depth = 0
    )

    if ($Depth -gt $MaxSearchDepth -or $Ac -eq [IntPtr]::Zero) { return $null }
    $script:visitedNodes++
    if ($script:visitedNodes -gt $MaxSearchNodes) {
        throw "Search exceeded MaxSearchNodes=$MaxSearchNodes."
    }

    $info = Get-Info -Ac $Ac
    if ($null -eq $info) { return $null }

    if (
        $info.role_en_US -eq "table" -and
        $info.x -ge 0 -and $info.y -ge 0 -and $info.width -gt 300 -and $info.height -gt 0 -and
        (Find-NameInSubtree -Ac $Ac -Name $ExpectedSymbol) -and
        (Find-NameInSubtree -Ac $Ac -Name $ExpectedSide) -and
        ([string]::IsNullOrWhiteSpace($ExpectedQuantity) -or (Find-NameInSubtree -Ac $Ac -Name $ExpectedQuantity))
    ) {
        return [pscustomobject]@{ Ac = $Ac; Info = $info; Owned = $null; Source = "SemanticSearch"; Path = "" }
    }

    for ($i = 0; $i -lt $info.childrenCount; $i++) {
        $child = [TosOpenOrderRules]::getAccessibleChildFromContext($vmID, $Ac, $i)
        if ($child -ne [IntPtr]::Zero) {
            $found = Find-MatchingOrderRowTable -Ac $child -Depth ($Depth + 1)
            if ($null -ne $found) {
                return $found
            }
            [TosOpenOrderRules]::ReleaseJavaObject($vmID, $child)
        }
    }

    return $null
}

function Test-OrderRulesOpen {
    $found = $false
    $cb = [TosOpenOrderRules+EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$lparam)
        if ([TosOpenOrderRules]::IsWindowVisible($hwnd)) {
            $title = [TosOpenOrderRules]::GetTitle($hwnd)
            if ($title -eq "Order Rules") { $script:found = $true }
        }
        return $true
    }
    [TosOpenOrderRules]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $found
}

$resolved = $null
try {
    $resolved = Resolve-Path -JabPath $RowTablePath
    $resolved | Add-Member -NotePropertyName Source -NotePropertyValue "Path" -Force
    $resolved | Add-Member -NotePropertyName Path -NotePropertyValue $RowTablePath -Force
} catch {
    Write-Host "Saved row path did not resolve; falling back to semantic search. $($_.Exception.Message)"
    $resolved = Find-MatchingOrderRowTable -Ac $rootAc
    if ($null -eq $resolved) {
        $quantityPart = if ([string]::IsNullOrWhiteSpace($ExpectedQuantity)) { "any quantity" } else { $ExpectedQuantity }
        throw "Could not locate a visible order-entry table containing $ExpectedSide $quantityPart $ExpectedSymbol."
    }
}

$rowInfo = if ($null -ne $resolved.Info) { $resolved.Info } else { Get-Info -Ac $resolved.Ac }
if ($null -eq $rowInfo) {
    throw "Resolved row table path but could not read node info."
}
if ($rowInfo.role_en_US -ne "table") {
    throw "Expected row path to resolve to role 'table', got '$($rowInfo.role_en_US)'."
}
if ($rowInfo.x -lt 0 -or $rowInfo.y -lt 0 -or $rowInfo.width -le 0 -or $rowInfo.height -le 0) {
    throw "Order-entry row table has invalid bounds $($rowInfo.x),$($rowInfo.y),$($rowInfo.width),$($rowInfo.height)."
}

$symbolOk = Find-NameInSubtree -Ac $resolved.Ac -Name $ExpectedSymbol
$sideOk = Find-NameInSubtree -Ac $resolved.Ac -Name $ExpectedSide
$quantityOk = [string]::IsNullOrWhiteSpace($ExpectedQuantity) -or (Find-NameInSubtree -Ac $resolved.Ac -Name $ExpectedQuantity)
if (-not $symbolOk -or -not $sideOk -or -not $quantityOk) {
    throw "Refusing to open rules. Expected row verification failed. Symbol=$symbolOk Side=$sideOk Quantity=$quantityOk."
}

$clickX = [int]($rowInfo.x + $OrderRulesOffsetX)
$clickY = [int]($rowInfo.y + ($rowInfo.height / 2))
$beforeOpen = Test-OrderRulesOpen
$clicked = $false

if (-not $DryRun) {
    [TosOpenOrderRules]::Click($clickX, $clickY)
    $clicked = $true
}

[TosOpenOrderRules]::PumpMessages(1000)
$afterOpen = Test-OrderRulesOpen

$row = [pscustomobject]@{
    Window = $target.Title
    RowTablePath = $resolved.Path
    LocateSource = $resolved.Source
    VisitedNodes = $visitedNodes
    RowBounds = "$($rowInfo.x),$($rowInfo.y),$($rowInfo.width),$($rowInfo.height)"
    ExpectedSymbol = $ExpectedSymbol
    ExpectedSide = $ExpectedSide
    ExpectedQuantity = $ExpectedQuantity
    SymbolVerified = $symbolOk
    SideVerified = $sideOk
    QuantityVerified = $quantityOk
    OrderRulesOffsetX = $OrderRulesOffsetX
    ClickX = $clickX
    ClickY = $clickY
    DryRun = [bool]$DryRun
    Clicked = $clicked
    OrderRulesOpenBefore = $beforeOpen
    OrderRulesOpenAfter = $afterOpen
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$row | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$row | Format-List
Write-Host "Wrote open-order-rules result to $OutFile"

if ($null -ne $resolved.Owned) {
    foreach ($child in $resolved.Owned) {
        [TosOpenOrderRules]::ReleaseJavaObject($vmID, $child)
    }
}
