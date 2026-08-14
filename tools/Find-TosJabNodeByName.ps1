param(
    [string]$WindowTitle = "Main@thinkorswim [build 1992]",
    [Parameter(Mandatory=$true)][string]$NameRegex,
    [int]$MaxDepth = 45,
    [int]$MaxNodes = 80000,
    [string]$OutFile = "$PSScriptRoot\..\Analysis\tos-jab-node-match.csv"
)

$ErrorActionPreference = "Stop"
$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) { throw "Java Access Bridge DLL not found at $bridgeDll" }

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosJabFindNode {
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
[TosJabFindNode]::Windows_run(); [TosJabFindNode]::PumpMessages(2500)
$script:hwnd = [IntPtr]::Zero; $script:title = ""
$cb = [TosJabFindNode+EnumWindowsProc]{ param([IntPtr]$hwnd,[IntPtr]$lp) if([TosJabFindNode]::IsWindowVisible($hwnd)){ $t=[TosJabFindNode]::GetTitle($hwnd); if($t -eq $WindowTitle){ $script:hwnd=$hwnd; $script:title=$t } }; return $true }
[TosJabFindNode]::EnumWindows($cb,[IntPtr]::Zero)|Out-Null
if($script:hwnd -eq [IntPtr]::Zero){ throw "No visible TOS window '$WindowTitle'." }
$vmID=0; $root=[IntPtr]::Zero
if(-not [TosJabFindNode]::getAccessibleContextFromHWND($script:hwnd,[ref]$vmID,[ref]$root)){ throw "Could not get JAB root." }
function Info([IntPtr]$ac){ $i=New-Object TosJabFindNode+AccessibleContextInfo; if([TosJabFindNode]::getAccessibleContextInfo($vmID,$ac,[ref]$i)){ $i } else { $null } }
function BoundsText($i){ if($null -eq $i){ return "" }; "$($i.x),$($i.y),$($i.width),$($i.height)" }
$script:nodes = 0
$script:found = $null
function Walk([IntPtr]$ac,[string]$path,[int]$depth,[object[]]$ancestors){
    if($script:found -ne $null -or $ac -eq [IntPtr]::Zero -or $depth -gt $MaxDepth){ return }
    $script:nodes++; if($script:nodes -gt $MaxNodes){ return }
    $i=Info $ac; if($null -eq $i){ return }
    $text = (($i.name, $i.description) -join " ").Trim()
    if($text -match $NameRegex){
        $visibleAncestors = @($ancestors | Where-Object { $_.X -ge 0 -and $_.Y -ge 0 -and $_.W -gt 0 -and $_.H -gt 0 } | Select-Object -Last 6)
        $click = $null
        if($i.x -ge 0 -and $i.y -ge 0 -and $i.width -gt 0 -and $i.height -gt 0){ $click = @{X=[int]($i.x+$i.width/2);Y=[int]($i.y+$i.height/2);Source="self"} }
        elseif($visibleAncestors.Count -gt 0){ $a=$visibleAncestors[-1]; $click=@{X=[int]($a.X+$a.W/2);Y=[int]($a.Y+$a.H/2);Source="ancestor:$($a.Role)"} }
        $script:found = [pscustomobject]@{
            Window=$script:title; Path=$path; Role=$i.role_en_US; Name=$i.name; Description=$i.description; States=$i.states_en_US; Bounds=(BoundsText $i); NodesVisited=$script:nodes;
            ClickX=if($click){$click.X}else{""}; ClickY=if($click){$click.Y}else{""}; ClickSource=if($click){$click.Source}else{""};
            Ancestors=(($visibleAncestors | ForEach-Object { "$($_.Path)|$($_.Role)|$($_.Name)|$($_.X),$($_.Y),$($_.W),$($_.H)" }) -join " || ")
        }
        return
    }
    $nextAncestors = $ancestors + [pscustomobject]@{Path=$path;Role=$i.role_en_US;Name=$i.name;X=$i.x;Y=$i.y;W=$i.width;H=$i.height}
    for($c=0;$c -lt $i.childrenCount;$c++){
        if($script:found -ne $null){ break }
        $child=[TosJabFindNode]::getAccessibleChildFromContext($vmID,$ac,$c)
        if($child -ne [IntPtr]::Zero){ $childPath = if($path){ "$path/$c" } else { "$c" }; Walk $child $childPath ($depth+1) $nextAncestors; [TosJabFindNode]::ReleaseJavaObject($vmID,$child) }
    }
}
Walk $root "" 0 @()
if($null -eq $script:found){ $script:found = [pscustomobject]@{Window=$script:title; Path=""; Role=""; Name=""; Description=""; States=""; Bounds=""; NodesVisited=$script:nodes; ClickX=""; ClickY=""; ClickSource=""; Ancestors=""} }
$outDir=Split-Path -Parent $OutFile; if(-not(Test-Path -LiteralPath $outDir)){ New-Item -ItemType Directory -Path $outDir | Out-Null }
$script:found | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8
$script:found | Format-List