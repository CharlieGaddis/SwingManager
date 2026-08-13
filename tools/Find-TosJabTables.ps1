param(
    [string]$WindowTitle = "Main@thinkorswim [build 1992]",
    [string[]]$Names = @("USB", "ASB"),
    [int]$MaxDepth = 45,
    [int]$MaxNodes = 120000,
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-matching-tables.csv"
)

$ErrorActionPreference = "Stop"
$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) { throw "Java Access Bridge DLL not found at $bridgeDll" }

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosJabTableFind {
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
        public int indexInParent; public int childrenCount; public int x; public int y; public int width; public int height;
        public int accessibleComponent; public int accessibleAction; public int accessibleSelection; public int accessibleText; public int accessibleValue; public int accessibleInterfaces;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport(Bridge, EntryPoint="Windows_run", CallingConvention=CallingConvention.Cdecl)] public static extern void Windows_run();
    [return: MarshalAs(UnmanagedType.U1)] [DllImport(Bridge, EntryPoint="getAccessibleContextFromHWND", CallingConvention=CallingConvention.Cdecl)] public static extern bool getAccessibleContextFromHWND(IntPtr hWnd, out int vmID, out IntPtr ac);
    [return: MarshalAs(UnmanagedType.U1)] [DllImport(Bridge, EntryPoint="getAccessibleContextInfo", CallingConvention=CallingConvention.Cdecl)] public static extern bool getAccessibleContextInfo(int vmID, IntPtr ac, ref AccessibleContextInfo info);
    [DllImport(Bridge, EntryPoint="getAccessibleChildFromContext", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr getAccessibleChildFromContext(int vmID, IntPtr ac, int childIndex);
    [DllImport(Bridge, EntryPoint="releaseJavaObject", CallingConvention=CallingConvention.Cdecl)] public static extern void ReleaseJavaObject(int vmID, IntPtr javaObject);
    public static string GetTitle(IntPtr hwnd){ var sb = new StringBuilder(512); GetWindowText(hwnd, sb, sb.Capacity); return sb.ToString(); }
    public static void PumpMessages(int ms){ var until=DateTime.UtcNow.AddMilliseconds(ms); MSG msg; while(DateTime.UtcNow<until){ while(PeekMessage(out msg, IntPtr.Zero,0,0,1)){ TranslateMessage(ref msg); DispatchMessage(ref msg);} System.Threading.Thread.Sleep(15);} }
}
"@
Add-Type -TypeDefinition $code
[TosJabTableFind]::Windows_run(); [TosJabTableFind]::PumpMessages(2500)
$matches = New-Object System.Collections.Generic.List[object]
$cb = [TosJabTableFind+EnumWindowsProc]{ param([IntPtr]$hwnd,[IntPtr]$lp) if([TosJabTableFind]::IsWindowVisible($hwnd)){ $title=[TosJabTableFind]::GetTitle($hwnd); if($title -eq $WindowTitle){ $script:hwnd=$hwnd; $script:title=$title } }; return $true }
[TosJabTableFind]::EnumWindows($cb,[IntPtr]::Zero)|Out-Null
if(-not $script:hwnd){ throw "No visible TOS window '$WindowTitle'." }
$vmID=0; $root=[IntPtr]::Zero
if(-not [TosJabTableFind]::getAccessibleContextFromHWND($script:hwnd,[ref]$vmID,[ref]$root)){ throw "Could not get JAB root." }
function Info([IntPtr]$ac){ $i=New-Object TosJabTableFind+AccessibleContextInfo; if([TosJabTableFind]::getAccessibleContextInfo($vmID,$ac,[ref]$i)){ $i } else { $null } }
function NamesIn([IntPtr]$ac,[int]$depth=0,[int]$max=8){ if($ac -eq [IntPtr]::Zero -or $depth -gt $max){ return @() }; $i=Info $ac; if($null -eq $i){ return @() }; $list=@(); if($i.name){ $list += $i.name }; for($c=0;$c -lt $i.childrenCount;$c++){ $child=[TosJabTableFind]::getAccessibleChildFromContext($vmID,$ac,$c); if($child -ne [IntPtr]::Zero){ $list += NamesIn $child ($depth+1) $max; [TosJabTableFind]::ReleaseJavaObject($vmID,$child) } }; $list }
$results = New-Object System.Collections.Generic.List[object]
$nodes=0
function Walk([IntPtr]$ac,[string]$path,[int]$depth){
    if($ac -eq [IntPtr]::Zero -or $depth -gt $MaxDepth){ return }
    $script:nodes++; if($script:nodes -gt $MaxNodes){ throw "Exceeded MaxNodes $MaxNodes" }
    $i=Info $ac; if($null -eq $i){ return }
    if($i.role_en_US -eq 'table' -and $i.x -ge 0 -and $i.y -ge 0 -and $i.width -gt 0 -and $i.height -gt 0){
        $namesHere = @(NamesIn $ac 0 8)
        foreach($name in $Names){
            if($namesHere -contains $name){
                $results.Add([pscustomobject]@{ Name=$name; Path=$path; Bounds="$($i.x),$($i.y),$($i.width),$($i.height)"; Children=$i.childrenCount; Names=(($namesHere|Select-Object -First 40) -join ' | ') }) | Out-Null
            }
        }
    }
    for($c=0;$c -lt $i.childrenCount;$c++){
        $child=[TosJabTableFind]::getAccessibleChildFromContext($vmID,$ac,$c)
        if($child -ne [IntPtr]::Zero){ $childPath = if($path){ "$path/$c" } else { "$c" }; Walk $child $childPath ($depth+1); [TosJabTableFind]::ReleaseJavaObject($vmID,$child) }
    }
}
Walk $root '' 0
$outDir=Split-Path -Parent $OutFile; if(-not(Test-Path -LiteralPath $outDir)){ New-Item -ItemType Directory -Path $outDir | Out-Null }
$results | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$results | Sort-Object Name,Path | Format-Table -AutoSize | Out-String -Width 260
