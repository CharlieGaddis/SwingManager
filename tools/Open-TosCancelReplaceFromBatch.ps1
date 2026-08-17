param(
    [string]$BatchPath = "",
    [string]$Symbol = "",
    [ValidateSet("", "Stop", "T1", "T2")]
    [string]$Phase = "",
    [string]$OcoId = "",
    [string]$ReplacingOrderId = "",
    [string]$WindowTitle = "Main@thinkorswim",
    [string]$SnapshotJson = "",
    [int]$CellsPerRow = 8,
    [ValidateSet("OrderEntry", "WorkingOrders")]
    [string]$MatchScope = "WorkingOrders",
    [int]$WorkingOrdersCellsPerRow = 17,
    [ValidateSet("Plan", "OpenContextMenu", "ClickCancelReplace")]
    [string]$Stage = "Plan",
    [int]$MaxScrollAttempts = 10,
    [switch]$AllowInput,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:currentScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
$analysisDir = Join-Path $projectRoot "Analysis"
$diagnosticsDir = Join-Path $projectRoot "TosAutomation\Diagnostics"
$discoveryDir = Join-Path $projectRoot "TosAutomation\Discovery"
if (-not (Test-Path -LiteralPath $diagnosticsDir)) { New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null }

if ([string]::IsNullOrWhiteSpace($BatchPath)) {
    $latest = Get-ChildItem -LiteralPath $analysisDir -Filter "tos-oco-desktop-update-batch-*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) { throw "No desktop OCO batch JSON found in $analysisDir. Build the OCO worklist first." }
    $BatchPath = $latest.FullName
}
if (-not (Test-Path -LiteralPath $BatchPath)) { throw "BatchPath not found: $BatchPath" }

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = if ($Symbol) { $Symbol.ToUpperInvariant() -replace '[^A-Z0-9_.-]+', '-' } else { 'selected' }
    $OutFile = Join-Path $diagnosticsDir "tos-cancel-replace-open-$safeSymbol-$stamp.json"
}

function Add-NativeInputType {
    if ("TosCancelReplaceNativeInput" -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TosCancelReplaceNativeInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    public const uint GA_ROOT = 2;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public static string GetTitle(IntPtr hWnd) {
        var sb = new StringBuilder(512);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string GetForegroundTitle() {
        return GetTitle(GetForegroundWindow());
    }
    public static string GetWindowTitleAtPoint(int x, int y) {
        POINT p;
        p.X = x;
        p.Y = y;
        var hWnd = WindowFromPoint(p);
        var root = GetAncestor(hWnd, GA_ROOT);
        if (root == IntPtr.Zero) root = hWnd;
        return GetTitle(root);
    }
    public static bool ActivateWindow(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return false;
        ShowWindow(hWnd, 9);
        System.Threading.Thread.Sleep(180);
        return SetForegroundWindow(hWnd);
    }
    public static void PulseToFront(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return;
        ShowWindow(hWnd, 9);
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        System.Threading.Thread.Sleep(180);
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        System.Threading.Thread.Sleep(180);
        SetForegroundWindow(hWnd);
    }
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);
    }
    public static void LeftClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Wheel(int x, int y, int delta) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        mouse_event(0x0800, 0, 0, unchecked((uint)delta), UIntPtr.Zero);
        System.Threading.Thread.Sleep(260);
    }
}
"@
}

function Set-TosForegroundWindow {
    param([int]$VerifyX = -1, [int]$VerifyY = -1)
    Add-NativeInputType
    $needle = if ([string]::IsNullOrWhiteSpace($WindowTitle)) { 'thinkorswim' } else { $WindowTitle }
    $candidates = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) -and
        ($_.MainWindowTitle -like "*$needle*" -or $_.MainWindowTitle -like '*thinkorswim*' -or $_.ProcessName -like '*thinkorswim*')
    } | Sort-Object @{ Expression = { if ($_.MainWindowTitle -like "*$needle*") { 0 } else { 1 } } }, ProcessName, Id)
    if ($candidates.Count -lt 1) { throw "No visible Thinkorswim window found for WindowTitle '$WindowTitle'." }
    $target = $candidates | Select-Object -First 1
    if ($target.MainWindowHandle -eq 0) { throw "Thinkorswim process $($target.Id) has no main window handle." }
    [TosCancelReplaceNativeInput]::ActivateWindow($target.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 450
    $foregroundTitle = [TosCancelReplaceNativeInput]::GetForegroundTitle()
    if ($foregroundTitle -notlike '*thinkorswim*' -and $foregroundTitle -notlike "*$needle*") {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shell.AppActivate([int]$target.Id) | Out-Null
            Start-Sleep -Milliseconds 450
            [TosCancelReplaceNativeInput]::PulseToFront($target.MainWindowHandle)
            Start-Sleep -Milliseconds 250
            [TosCancelReplaceNativeInput]::ActivateWindow($target.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 350
            $foregroundTitle = [TosCancelReplaceNativeInput]::GetForegroundTitle()
        } catch {
            # Keep the explicit foreground verification below as the safety gate.
        }
    }
    if ($foregroundTitle -notlike '*thinkorswim*' -and $foregroundTitle -notlike "*$needle*") {
        $pointTitle = ""
        if ($VerifyX -ge 0 -and $VerifyY -ge 0) {
            $pointTitle = [TosCancelReplaceNativeInput]::GetWindowTitleAtPoint($VerifyX, $VerifyY)
            if ($pointTitle -like '*thinkorswim*' -or $pointTitle -like "*$needle*") {
                return [pscustomobject]@{ processId = $target.Id; title = $target.MainWindowTitle; foregroundTitle = $foregroundTitle; pointWindowTitle = $pointTitle; verifiedByPoint = $true }
            }
        }
        throw "Refusing native input: foreground window is '$foregroundTitle', expected Thinkorswim ('$needle')."
    }
    return [pscustomobject]@{ processId = $target.Id; title = $target.MainWindowTitle; foregroundTitle = $foregroundTitle; pointWindowTitle = ""; verifiedByPoint = $false }
}

function Get-LatestSnapshotJson([string]$Label) {
    $snapshotScript = Join-Path $scriptDir "New-TosAutomationSnapshot.ps1"
    if (-not (Test-Path -LiteralPath $snapshotScript)) { throw "Missing snapshot script: $snapshotScript" }
    $started = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $snapshotScript -WindowTitle $WindowTitle -Label $Label -MaxDepth 35 -MaxChildrenPerNode 1000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Snapshot command failed for label $Label with exit code $LASTEXITCODE." }
    $snapshot = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-$Label-*-tree.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $snapshot) { throw "Fresh snapshot JSON was not produced for label $Label." }
    return $snapshot.FullName
}

function Get-LatestElementUnderMouseJson {
    $captureScript = Join-Path $scriptDir "Capture-TosElementUnderMouse.ps1"
    if (-not (Test-Path -LiteralPath $captureScript)) { throw "Missing capture script: $captureScript" }
    $started = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $captureScript -WindowTitleRegex $WindowTitle -ChildDepth 2 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Element-under-mouse capture failed with exit code $LASTEXITCODE." }
    $capture = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-element-under-mouse-*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $capture) { throw "Fresh element-under-mouse capture JSON was not produced." }
    return $capture.FullName
}


function Get-AncestorNodes($NodesById, $Node) {
    $ancestors = New-Object System.Collections.Generic.List[object]
    $current = $Node
    while ($current -and $null -ne $current.parentId) {
        $parent = $NodesById[[string]$current.parentId]
        if (-not $parent) { break }
        $ancestors.Insert(0, $parent)
        $current = $parent
    }
    return @($ancestors.ToArray())
}

function Get-LastPathIndex([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return -1 }
    $last = ($Path -split '[./]')[-1]
    $value = 0
    if ([int]::TryParse($last, [ref]$value)) { return $value }
    return -1
}

function Find-SelectedBatchItem($Batch) {
    $items = @($Batch.items | Where-Object {
        $_.Action -eq 'update_condition_threshold' -and
        $_.ReadyForDesktopAutomation -eq $true -and
        $_.AccountVerified -eq $true -and
        ([string]$_.SnapshotStatus).Trim().ToUpperInvariant() -notmatch 'CANCELED|FILLED'
    })
    if (-not [string]::IsNullOrWhiteSpace($Symbol)) {
        $want = $Symbol.Trim().ToUpperInvariant()
        $items = @($items | Where-Object { ([string]$_.Symbol).Trim().ToUpperInvariant() -eq $want })
    }
    if (-not [string]::IsNullOrWhiteSpace($Phase)) { $items = @($items | Where-Object { $_.Phase -eq $Phase }) }
    if (-not [string]::IsNullOrWhiteSpace($OcoId)) { $items = @($items | Where-Object { [string]$_.OcoId -eq [string]$OcoId }) }
    if (-not [string]::IsNullOrWhiteSpace($ReplacingOrderId)) { $items = @($items | Where-Object { [string]$_.ReplacingOrderId -eq [string]$ReplacingOrderId }) }
    return @($items)
}

function Test-OnlyViewportErrors {
    param([object[]]$ErrorList)
    $remaining = @($ErrorList | Where-Object { ([string]$_) -notmatch 'not inside the visible TOS viewport|outside visible viewport|Scroll .* rerun' })
    return ($remaining.Count -eq 0)
}

function Invoke-PlanProbe {
    param([string]$ProbeSnapshotJson, [int]$Attempt)
    $probeOut = Join-Path $diagnosticsDir ("tos-cancel-replace-scroll-probe-{0}-{1}-{2}.json" -f ($item.Symbol -replace '[^A-Za-z0-9_.-]+','-'), (Get-Date -Format "yyyyMMdd-HHmmss"), $Attempt)
    $args = @(
        "-BatchPath", $BatchPath,
        "-Symbol", [string]$item.Symbol,
        "-Phase", [string]$item.Phase,
        "-OcoId", [string]$item.OcoId,
        "-ReplacingOrderId", [string]$item.ReplacingOrderId,
        "-WindowTitle", $WindowTitle,
        "-SnapshotJson", $ProbeSnapshotJson,
        "-CellsPerRow", [string]$CellsPerRow,
        "-MatchScope", $MatchScope,
        "-WorkingOrdersCellsPerRow", [string]$WorkingOrdersCellsPerRow,
        "-Stage", "Plan",
        "-OutFile", $probeOut
    )
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:currentScriptPath @args | Out-Null
    if (-not (Test-Path -LiteralPath $probeOut)) { throw "Scroll probe did not write result file: $probeOut" }
    return Get-Content -LiteralPath $probeOut -Raw | ConvertFrom-Json
}

$batch = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json
$items = @(Find-SelectedBatchItem $batch)
$errors = New-Object System.Collections.Generic.List[string]
if ($items.Count -eq 0) { $errors.Add("No verified ready desktop OCO update item matched the requested filters.") | Out-Null }
if ($items.Count -gt 1) { $errors.Add("More than one ready item matched. Add Symbol, Phase, OcoId, or ReplacingOrderId.") | Out-Null }
if ($Stage -ne 'Plan' -and -not $AllowInput) { $errors.Add("$Stage requires -AllowInput.") | Out-Null }
$item = $items | Select-Object -First 1

if ($errors.Count -eq 0 -and [string]::IsNullOrWhiteSpace($SnapshotJson)) {
    $safeSymbol = $item.Symbol -replace '[^A-Za-z0-9_.-]+', '-'
    $SnapshotJson = Get-LatestSnapshotJson "CancelReplacePreflight-$safeSymbol"
}
if ($errors.Count -eq 0 -and -not (Test-Path -LiteralPath $SnapshotJson)) { $errors.Add("SnapshotJson not found: $SnapshotJson") | Out-Null }

$rowPlan = $null
$scrollTrace = New-Object System.Collections.Generic.List[object]
$contextMenuSnapshot = ""
$cancelReplaceCandidate = $null
$openedContextMenu = $false
$clickedCancelReplace = $false
$activeEditorReady = $false
$foregroundWindow = $null

if ($errors.Count -eq 0) {
    $snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
    $nodes = @($snapshot.nodes)
    $nodesById = @{}
    foreach ($n in $nodes) { $nodesById[[string]$n.id] = $n }

    $rawPattern = [regex]::Escape([string]$item.ReplacingOrderId)
    $ocoPattern = [regex]::Escape([string]$item.OcoId)
    $symbolPattern = [regex]::Escape([string]$item.Symbol)
    $thresholdPattern = [regex]::Escape([string]$item.CurrentThreshold)

    if ($MatchScope -eq 'WorkingOrders') {
        $tables = @($nodes | Where-Object { $_.role -eq 'table' -and [int]$_.childCount -gt 500 -and ([string]$_.path) -like '*.0.2.1.1' })
        $tableIds = @($tables | ForEach-Object { [string]$_.id })
        $reMatches = @($nodes | Where-Object {
            $_.role -eq 'label' -and
            ([string]$_.name) -eq "RE #$($item.ReplacingOrderId)" -and
            $tableIds -contains ([string]$_.parentId)
        })
        $verified = @()
        foreach ($reNode in $reMatches) {
            $table = $nodesById[[string]$reNode.parentId]
            $cellIndex = Get-LastPathIndex ([string]$reNode.path)
            if ($cellIndex -lt 0) { continue }
            $ocoNearby = @($nodes | Where-Object {
                [string]$_.parentId -eq [string]$table.id -and
                ([string]$_.name) -eq "OCO #$($item.OcoId)" -and
                (Get-LastPathIndex ([string]$_.path)) -ge $cellIndex -and
                (Get-LastPathIndex ([string]$_.path)) -le ($cellIndex + 40)
            })
            if ($ocoNearby.Count -gt 0) { $verified += $reNode }
        }
        if ($verified.Count -ne 1) {
            $errors.Add("Working Orders match expected one row for RE #$($item.ReplacingOrderId) / OCO #$($item.OcoId) / $($item.Symbol), found $($verified.Count).") | Out-Null
        } else {
            $node = $verified[0]
            $ancestors = @(Get-AncestorNodes $nodesById $node)
            $monitor = $ancestors | Where-Object { $_.role -eq 'page tab' -and $_.name -eq 'Monitor' -and $_.bounds -and [int]$_.bounds.width -gt 0 } | Select-Object -Last 1
            $monitorSurface = $ancestors | Where-Object { $_.bounds -and [int]$_.bounds.width -gt 500 -and [int]$_.bounds.height -gt 500 } | Select-Object -Last 1
            $workingOrdersViewport = $ancestors | Where-Object { $_.role -eq 'viewport' -and $_.bounds -and [int]$_.bounds.width -gt 500 -and [int]$_.bounds.height -gt 100 } | Select-Object -Last 1
            if (-not $monitor -or -not $monitorSurface) { $errors.Add('Working Orders row was not under the Monitor tab/surface; refusing to click.') | Out-Null }
            else {
                $cellIndex = Get-LastPathIndex ([string]$node.path)
                $rowIndex = [Math]::Floor($cellIndex / $WorkingOrdersCellsPerRow)
                $table = $nodesById[[string]$node.parentId]
                $rowHeight = 15.0
                $headerOffsetY = 24.0
                $clickX = [int]([int]$table.bounds.x + 690)
                $clickY = [int]([int]$table.bounds.y + $headerOffsetY + ([double]([Math]::Max(0, $rowIndex - 2)) * $rowHeight) + ($rowHeight / 2.0))
                if ($workingOrdersViewport) {
                    $viewport = [pscustomobject]@{ x = [int]$workingOrdersViewport.bounds.x; y = [int]$workingOrdersViewport.bounds.y; width = [int]$workingOrdersViewport.bounds.width; height = [int]$workingOrdersViewport.bounds.height }
                } else {
                    $viewport = [pscustomobject]@{ x = [int]$monitorSurface.bounds.x; y = [int]$monitorSurface.bounds.y + 65; width = [int]$monitorSurface.bounds.width; height = [int]$monitorSurface.bounds.height - 65 }
                }
                $inViewport = $clickX -ge [int]$viewport.x -and $clickX -le ([int]$viewport.x + [int]$viewport.width) -and $clickY -ge [int]$viewport.y -and $clickY -le ([int]$viewport.y + [int]$viewport.height)
                $rowPlan = [pscustomobject]@{
                    matchScope = $MatchScope
                    snapshotJson = $SnapshotJson
                    nodePath = $node.path
                    cellIndex = $cellIndex
                    cellsPerRow = $WorkingOrdersCellsPerRow
                    rowIndex = $rowIndex
                    rowHeight = $rowHeight
                    tableBounds = $table.bounds
                    tableChildCount = ($nodesById[[string]$node.parentId]).childCount
                    viewportBounds = $viewport
                    clickPoint = [pscustomobject]@{ x = $clickX; y = $clickY }
                    inViewport = [bool]$inViewport
                    matchedText = $node.name
                }
                if (-not $inViewport) { $errors.Add('Matched Working Orders row is not inside the visible TOS viewport. Scroll it into view and rerun.') | Out-Null }
            }
        }
    } else {
        $matches = @($nodes | Where-Object {
            $_.role -eq 'label' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
            [string]$_.name -match "Replacing #$rawPattern" -and
            [string]$_.name -match "\b$symbolPattern\b" -and
            [string]$_.name -match "OCO #$ocoPattern" -and
            [string]$_.name -match $thresholdPattern
        })
        if ($matches.Count -ne 1) {
            $errors.Add("Fresh snapshot expected one matching TOS order-entry row, found $($matches.Count).") | Out-Null
        } else {
            $node = $matches[0]
            $ancestors = @(Get-AncestorNodes $nodesById $node)
            $table = $ancestors | Where-Object { $_.role -eq 'table' -and $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 } | Select-Object -Last 1
            $viewport = $ancestors | Where-Object { $_.role -eq 'viewport' -and $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 } | Select-Object -Last 1
            if (-not $table -or -not $viewport) {
                $errors.Add('Could not derive table and viewport bounds for the matched row.') | Out-Null
            } else {
                $cellIndex = Get-LastPathIndex ([string]$node.path)
                if ($cellIndex -lt 0 -or $CellsPerRow -le 0) { $errors.Add("Could not derive table cell index from matched path '$($node.path)'.") | Out-Null }
                else {
                    $rowIndex = [Math]::Floor($cellIndex / $CellsPerRow)
                    $rowCount = [Math]::Max(1, [Math]::Ceiling([double]$table.childCount / [double]$CellsPerRow))
                    $rowHeight = [double]$table.bounds.height / [double]$rowCount
                    if ($rowHeight -lt 8 -or $rowHeight -gt 40) { $rowHeight = 16.0 }
                    $clickX = [int]([int]$table.bounds.x + [Math]::Min([double]$table.bounds.width - 20.0, [Math]::Max(30.0, [double]$table.bounds.width * 0.34)))
                    $clickY = [int]([double]$table.bounds.y + ([double]$rowIndex * $rowHeight) + ($rowHeight / 2.0))
                    $inViewport = $clickX -ge [int]$viewport.bounds.x -and $clickX -le ([int]$viewport.bounds.x + [int]$viewport.bounds.width) -and $clickY -ge [int]$viewport.bounds.y -and $clickY -le ([int]$viewport.bounds.y + [int]$viewport.bounds.height)
                    $rowPlan = [pscustomobject]@{
                        matchScope = $MatchScope
                        snapshotJson = $SnapshotJson
                        nodePath = $node.path
                        cellIndex = $cellIndex
                        cellsPerRow = $CellsPerRow
                        rowIndex = $rowIndex
                        rowHeight = [Math]::Round($rowHeight, 2)
                        tableBounds = $table.bounds
                        tableChildCount = $table.childCount
                        viewportBounds = $viewport.bounds
                        clickPoint = [pscustomobject]@{ x = $clickX; y = $clickY }
                        inViewport = [bool]$inViewport
                        matchedText = $node.name
                    }
                    if (-not $inViewport) { $errors.Add('Matched row is not inside the visible TOS viewport. Scroll it into view and rerun.') | Out-Null }
                }
            }
        }
    }
}

if (
    $MatchScope -eq 'WorkingOrders' -and
    $Stage -in @('OpenContextMenu', 'ClickCancelReplace') -and
    $AllowInput -and
    $rowPlan -and
    $rowPlan.inViewport -ne $true -and
    (Test-OnlyViewportErrors -ErrorList @($errors))
) {
    $errors.Clear()
    for ($attempt = 1; $attempt -le $MaxScrollAttempts; $attempt++) {
        $vp = $rowPlan.viewportBounds
        if (-not $vp) { $errors.Add("Cannot auto-scroll without viewport bounds.") | Out-Null; break }
        $scrollX = [int]([int]$vp.x + ([int]$vp.width / 2))
        $scrollY = [int]([int]$vp.y + ([int]$vp.height / 2))
        $direction = if ([int]$rowPlan.clickPoint.y -lt [int]$vp.y) { "Up" } else { "Down" }
        $delta = if ($direction -eq "Up") { 720 } else { -720 }
        $foregroundWindow = Set-TosForegroundWindow -VerifyX $scrollX -VerifyY $scrollY
        Add-NativeInputType
        [TosCancelReplaceNativeInput]::Wheel($scrollX, $scrollY, $delta)
        Start-Sleep -Milliseconds 800
        $safeSymbol = $item.Symbol -replace '[^A-Za-z0-9_.-]+', '-'
        $SnapshotJson = Get-LatestSnapshotJson "CancelReplaceScrolled-$safeSymbol-$attempt"
        $probe = Invoke-PlanProbe -ProbeSnapshotJson $SnapshotJson -Attempt $attempt
        $rowPlan = $probe.rowPlan
        $scrollTrace.Add([pscustomobject]@{
            attempt = $attempt
            direction = $direction
            wheelDelta = $delta
            scrollPoint = [pscustomobject]@{ x = $scrollX; y = $scrollY }
            snapshotJson = $SnapshotJson
            rowPlan = $rowPlan
            probeErrors = @($probe.errors)
        }) | Out-Null
        if ($rowPlan -and $rowPlan.inViewport -eq $true -and @($probe.errors).Count -eq 0) { break }
        $nonViewport = @($probe.errors | Where-Object { ([string]$_) -notmatch 'not inside the visible TOS viewport|outside visible viewport|Scroll .* rerun' })
        if ($nonViewport.Count -gt 0) {
            foreach ($e in $nonViewport) { $errors.Add([string]$e) | Out-Null }
            break
        }
    }
    if ($errors.Count -eq 0 -and (-not $rowPlan -or $rowPlan.inViewport -ne $true)) {
        $errors.Add("Matched Working Orders row could not be scrolled into the visible TOS viewport after $MaxScrollAttempts attempts.") | Out-Null
    }
}

if ($errors.Count -eq 0 -and $Stage -in @('OpenContextMenu', 'ClickCancelReplace')) {
    $foregroundWindow = Set-TosForegroundWindow -VerifyX ([int]$rowPlan.clickPoint.x) -VerifyY ([int]$rowPlan.clickPoint.y)
    [TosCancelReplaceNativeInput]::RightClick([int]$rowPlan.clickPoint.x, [int]$rowPlan.clickPoint.y)
    $openedContextMenu = $true
    Start-Sleep -Milliseconds 700
}

if ($errors.Count -eq 0 -and $Stage -eq 'ClickCancelReplace') {
    $contextMenuSnapshot = Get-LatestElementUnderMouseJson
    $mouseMenuSnapshot = Get-Content -LiteralPath $contextMenuSnapshot -Raw | ConvertFrom-Json
    $mouseMenuNodes = @(@($mouseMenuSnapshot.hit) + @($mouseMenuSnapshot.children))
    $clickable = @($mouseMenuNodes | Where-Object {
        $_.role -match 'menu item' -and
        ([string]$_.name) -match '(?i)^\s*cancel\s*/?\s*replace\s+order\s*$' -and
        $_.bounds -and [int]$_.bounds.x -ge 0 -and [int]$_.bounds.y -ge 0 -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0
    })

    if ($clickable.Count -eq 1) {
        $cancelReplaceCandidate = $clickable[0]
        Add-NativeInputType
        $x = [int]([int]$cancelReplaceCandidate.bounds.x + ([int]$cancelReplaceCandidate.bounds.width / 2))
        $y = [int]([int]$cancelReplaceCandidate.bounds.y + ([int]$cancelReplaceCandidate.bounds.height / 2))
        [TosCancelReplaceNativeInput]::LeftClick($x, $y)
        $clickedCancelReplace = $true
        Start-Sleep -Milliseconds 1200
    } else {
        $contextMenuSnapshot = Get-LatestSnapshotJson "CancelReplaceMenu-$($item.Symbol -replace '[^A-Za-z0-9_.-]+', '-')"
        $menuSnapshot = Get-Content -LiteralPath $contextMenuSnapshot -Raw | ConvertFrom-Json
        $allMenuNodes = @($menuSnapshot.nodes)
        $menuNodes = @($allMenuNodes | Where-Object {
            ($_.role -match 'menu|label|push button') -and
            (-not [string]::IsNullOrWhiteSpace([string]$_.name) -or -not [string]::IsNullOrWhiteSpace([string]$_.description)) -and
            (([string]$_.name + ' ' + [string]$_.description) -match '(?i)cancel\s*/?\s*replace|cancel\s+and\s+replace|replace\s+order')
        })
        $clickable = @($menuNodes | Where-Object { $_.bounds -and [int]$_.bounds.x -ge 0 -and [int]$_.bounds.y -ge 0 -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 })
        if ($clickable.Count -ne 1) {
            $entryAccordion = @($allMenuNodes | Where-Object { $_.role -eq 'toggle button' -and $_.name -eq 'Order Entry and Saved Orders' -and $_.states -match 'checked' -and $_.states -match 'showing' })
            $strategyBook = @($allMenuNodes | Where-Object { $_.role -eq 'toggle button' -and $_.name -eq 'Order and Strategy Book' -and $_.states -match 'checked' })
            $entryTabs = @($allMenuNodes | Where-Object { $_.role -eq 'page tab' -and $_.name -eq 'Order Entry' -and $_.states -match 'selected' -and $_.states -match 'showing' })
            $workingOrderRegex = "Replacing #$([regex]::Escape([string]$item.ReplacingOrderId)).*\b$([regex]::Escape([string]$item.Symbol))\b.*OCO #$([regex]::Escape([string]$item.OcoId)).*$([regex]::Escape([string]$item.CurrentThreshold))"
            $workingOrderMatches = @($allMenuNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name) -match $workingOrderRegex })
            $triggerLabels = @($allMenuNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim() -eq 'Trigger At:' -and $_.states -match 'showing' })
            $activeEditorReady = (
                $entryAccordion.Count -eq 1 -and
                $strategyBook.Count -eq 0 -and
                $entryTabs.Count -eq 1 -and
                $workingOrderMatches.Count -eq 1 -and
                $triggerLabels.Count -ge 1
            )
            if ($activeEditorReady) {
                $cancelReplaceCandidate = [pscustomobject]@{
                    source = "active_order_entry_editor"
                    snapshotJson = $contextMenuSnapshot
                    matchedWorkingOrder = $workingOrderMatches[0].name
                }
                $clickedCancelReplace = $true
            } else {
                $errors.Add("Expected exactly one visible Cancel/Replace menu item, found $($clickable.Count), and no matching active Order Entry editor was ready. Popup probe: $($mouseMenuSnapshot.hit.role) children=$(@($mouseMenuSnapshot.children).Count). Context snapshot: $contextMenuSnapshot") | Out-Null
            }
        } else {
            $cancelReplaceCandidate = $clickable[0]
            Add-NativeInputType
            $x = [int]([int]$cancelReplaceCandidate.bounds.x + ([int]$cancelReplaceCandidate.bounds.width / 2))
            $y = [int]([int]$cancelReplaceCandidate.bounds.y + ([int]$cancelReplaceCandidate.bounds.height / 2))
            [TosCancelReplaceNativeInput]::LeftClick($x, $y)
            $clickedCancelReplace = $true
            Start-Sleep -Milliseconds 1000
        }
    }
}

$result = [ordered]@{
    createdAt = (Get-Date).ToString('o')
    stage = $Stage
    allowInput = [bool]$AllowInput
    batchPath = $BatchPath
    currentTosAccount = $batch.currentTosAccount
    requested = [ordered]@{ symbol = $Symbol; phase = $Phase; ocoId = $OcoId; replacingOrderId = $ReplacingOrderId }
    matchedCount = $items.Count
    selectedItem = $item
    rowPlan = $rowPlan
    scrollTrace = @([object[]]$scrollTrace.ToArray())
    openedContextMenu = $openedContextMenu
    contextMenuSnapshot = $contextMenuSnapshot
    cancelReplaceCandidate = $cancelReplaceCandidate
    clickedCancelReplace = $clickedCancelReplace
    activeEditorReady = $activeEditorReady
    errors = @($errors)
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 18
Write-Host "Wrote cancel/replace opener result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }








