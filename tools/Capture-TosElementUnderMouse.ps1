param(
    [string]$WindowTitleRegex = "Main@thinkorswim|Order Rules",
    [string]$OutDir = "$PSScriptRoot\..\TosAutomation\Discovery",
    [int]$ChildDepth = 2
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TosPrivacyRedactor.psm1") -Force
$bridgeDll = "C:\Program Files\thinkorswim2\jre\bin\windowsaccessbridge-64.dll"
if (-not (Test-Path -LiteralPath $bridgeDll)) {
    throw "Java Access Bridge DLL not found at $bridgeDll"
}

$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class TosCaptureMouse {
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

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);

    [DllImport(Bridge, EntryPoint="Windows_run", CallingConvention=CallingConvention.Cdecl)] public static extern void Windows_run();
    [return: MarshalAs(UnmanagedType.U1)] [DllImport(Bridge, EntryPoint="getAccessibleContextFromHWND", CallingConvention=CallingConvention.Cdecl)] public static extern bool getAccessibleContextFromHWND(IntPtr hWnd, out int vmID, out IntPtr ac);
    [return: MarshalAs(UnmanagedType.U1)] [DllImport(Bridge, EntryPoint="getAccessibleContextInfo", CallingConvention=CallingConvention.Cdecl)] public static extern bool getAccessibleContextInfo(int vmID, IntPtr ac, ref AccessibleContextInfo info);
    [return: MarshalAs(UnmanagedType.U1)] [DllImport(Bridge, EntryPoint="getAccessibleContextAt", CallingConvention=CallingConvention.Cdecl)] public static extern bool getAccessibleContextAt(int vmID, IntPtr parent, int x, int y, out IntPtr ac);
    [DllImport(Bridge, EntryPoint="getAccessibleChildFromContext", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr getAccessibleChildFromContext(int vmID, IntPtr ac, int childIndex);
    [DllImport(Bridge, EntryPoint="releaseJavaObject", CallingConvention=CallingConvention.Cdecl)] public static extern void ReleaseJavaObject(int vmID, IntPtr javaObject);

    public static string Title(IntPtr hwnd) { var sb = new StringBuilder(512); GetWindowText(hwnd, sb, sb.Capacity); return sb.ToString(); }
    public static void Pump(int ms) { var until=DateTime.UtcNow.AddMilliseconds(ms); MSG msg; while(DateTime.UtcNow<until){ while(PeekMessage(out msg, IntPtr.Zero,0,0,1)){ TranslateMessage(ref msg); DispatchMessage(ref msg);} System.Threading.Thread.Sleep(15);} }
}
"@

Add-Type -TypeDefinition $code
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

[TosCaptureMouse]::Windows_run()
[TosCaptureMouse]::Pump(1800)

$point = New-Object TosCaptureMouse+POINT
if (-not [TosCaptureMouse]::GetCursorPos([ref]$point)) { throw "Could not read mouse position." }

$windows = New-Object System.Collections.Generic.List[object]
$callback = [TosCaptureMouse+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lp)
    if ([TosCaptureMouse]::IsWindowVisible($hwnd)) {
        $title = [TosCaptureMouse]::Title($hwnd)
        if ($title -match $WindowTitleRegex) {
            $rect = New-Object TosCaptureMouse+RECT
            [void][TosCaptureMouse]::GetWindowRect($hwnd, [ref]$rect)
            if ($point.X -ge $rect.Left -and $point.X -le $rect.Right -and $point.Y -ge $rect.Top -and $point.Y -le $rect.Bottom) {
                $windows.Add([pscustomobject]@{ Hwnd=$hwnd; Title=$title; Rect=$rect }) | Out-Null
            }
        }
    }
    return $true
}
[TosCaptureMouse]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
if ($windows.Count -eq 0) {
    throw "Mouse is not over a visible TOS/Order Rules window matching '$WindowTitleRegex'. Mouse=$($point.X),$($point.Y)"
}

$target = $windows | Sort-Object { ($_.Rect.Right - $_.Rect.Left) * ($_.Rect.Bottom - $_.Rect.Top) } | Select-Object -First 1
$vmID = 0
$rootAc = [IntPtr]::Zero
if (-not [TosCaptureMouse]::getAccessibleContextFromHWND($target.Hwnd, [ref]$vmID, [ref]$rootAc)) {
    throw "Could not get JAB root for '$($target.Title)'."
}
$hitAc = [IntPtr]::Zero
if (-not [TosCaptureMouse]::getAccessibleContextAt($vmID, $rootAc, $point.X, $point.Y, [ref]$hitAc) -or $hitAc -eq [IntPtr]::Zero) {
    throw "JAB did not return an accessible context at $($point.X),$($point.Y)."
}

function Get-Info([IntPtr]$Ac) {
    $info = New-Object TosCaptureMouse+AccessibleContextInfo
    if ([TosCaptureMouse]::getAccessibleContextInfo($vmID, $Ac, [ref]$info)) { return $info }
    return $null
}

function Node-Object([IntPtr]$Ac, [string]$Path, [int]$Depth) {
    $info = Get-Info $Ac
    if ($null -eq $info) { return $null }
    [pscustomobject]@{
        path = $Path
        depth = $Depth
        role = $info.role_en_US
        name = ConvertTo-TosSanitizedText $info.name
        description = ConvertTo-TosSanitizedText $info.description
        states = $info.states_en_US
        bounds = [pscustomobject]@{ x=$info.x; y=$info.y; width=$info.width; height=$info.height }
        childCount = $info.childrenCount
        accessible = [pscustomobject]@{
            component = [bool]$info.accessibleComponent
            action = [bool]$info.accessibleAction
            selection = [bool]$info.accessibleSelection
            text = [bool]$info.accessibleText
            value = [bool]$info.accessibleValue
            interfaces = $info.accessibleInterfaces
        }
    }
}

$children = New-Object System.Collections.Generic.List[object]
function Walk-Children([IntPtr]$Ac, [string]$Path, [int]$Depth) {
    if ($Depth -gt $ChildDepth) { return }
    $info = Get-Info $Ac
    if ($null -eq $info) { return }
    for ($i = 0; $i -lt $info.childrenCount; $i++) {
        $child = [TosCaptureMouse]::getAccessibleChildFromContext($vmID, $Ac, $i)
        if ($child -ne [IntPtr]::Zero) {
            $childPath = if ($Path) { "$Path/$i" } else { "$i" }
            $node = Node-Object $child $childPath $Depth
            if ($null -ne $node) { $children.Add($node) | Out-Null }
            Walk-Children $child $childPath ($Depth + 1)
            [TosCaptureMouse]::ReleaseJavaObject($vmID, $child)
        }
    }
}

$hit = Node-Object $hitAc "hit" 0
Walk-Children $hitAc "hit" 1

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$base = Join-Path $OutDir "tos-element-under-mouse-$stamp"
$jsonPath = "$base.json"
$pngPath = "$base.png"
$cropPath = "$base-crop.png"

$privacyRedactionRects = @()
$privacyTreePath = Join-Path $env:TEMP "tos-capture-account-redaction-$stamp.txt"
try {
    & "$PSScriptRoot\Dump-TosJabTree.ps1" -WindowTitle "Main@thinkorswim" -OutFile $privacyTreePath -MaxDepth 12 -MaxChildrenPerNode 120 | Out-Null
    $privacyRedactionRects = @(Get-TosAccountRedactionRectsFromTreePath -TreePath $privacyTreePath)
} finally {
    Remove-Item -LiteralPath $privacyTreePath -Force -ErrorAction SilentlyContinue
}

$screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap $screenBounds.Width, $screenBounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($screenBounds.Location, [System.Drawing.Point]::Empty, $screenBounds.Size)
} finally {
    $graphics.Dispose()
}
Protect-TosBitmapAccountNumbers -Bitmap $bitmap -Rects $privacyRedactionRects
$bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

$cropSize = 260
$cropX = [Math]::Max(0, [Math]::Min($point.X - [int]($cropSize / 2), $screenBounds.Width - $cropSize))
$cropY = [Math]::Max(0, [Math]::Min($point.Y - [int]($cropSize / 2), $screenBounds.Height - $cropSize))
$crop = $bitmap.Clone([System.Drawing.Rectangle]::new($cropX, $cropY, $cropSize, $cropSize), $bitmap.PixelFormat)
$crop.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose(); $crop.Dispose()

$result = [pscustomobject]@{
    capturedAt = (Get-Date).ToString("o")
    window = [pscustomobject]@{ title=(ConvertTo-TosSanitizedText $target.Title); hwnd=[int64]$target.Hwnd; bounds=[pscustomobject]@{ left=$target.Rect.Left; top=$target.Rect.Top; right=$target.Rect.Right; bottom=$target.Rect.Bottom } }
    mouse = [pscustomobject]@{ x=$point.X; y=$point.Y }
    hit = $hit
    children = $children
    screenshot = $pngPath
    crop = $cropPath
    privacyRedaction = [pscustomobject]@{ accountNumberMasked = $true; rectCount = $privacyRedactionRects.Count; method = "solid_opaque_block" }
}
$sanitizedJson = ConvertTo-TosSanitizedText ($result | ConvertTo-Json -Depth 12)
$sanitizedJson | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$result | Format-List
Write-Host "Wrote capture JSON to $jsonPath"
Write-Host "Wrote screenshot to $pngPath"
Write-Host "Wrote crop to $cropPath"

