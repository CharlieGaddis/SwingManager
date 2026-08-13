param(
    [string]$DownloadsDir = "$env:USERPROFILE\Downloads",
    [string]$SourcePath = "",
    [string]$SourceUrl = "",
    [string]$OutDir = "$PSScriptRoot\Analysis",
    [switch]$CaptureTos,
    [string]$TradingDashboardBaseUrl = "http://127.0.0.1:5080"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

if ($SourceUrl) {
    $fileName = Split-Path -Leaf ([uri]$SourceUrl).AbsolutePath
    if (-not $fileName -or $fileName -notlike "*.json") {
        $fileName = "squeeze-intel-$(Get-Date -Format yyyy-MM-dd).json"
    }
    $SourcePath = Join-Path $OutDir $fileName
    Invoke-WebRequest -Uri $SourceUrl -OutFile $SourcePath
}

if (-not $SourcePath) {
    $SourcePath = Get-ChildItem -LiteralPath $DownloadsDir -Filter "squeeze-intel-*.json" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) {
    throw "No Squeeze Intel JSON file was found. Pass -SourcePath or place squeeze-intel-YYYY-MM-DD.json in Downloads."
}

$todayName = Split-Path -Leaf $SourcePath
$todayProjectPath = Join-Path $OutDir $todayName
$sourceResolved = (Resolve-Path -LiteralPath $SourcePath).Path
$targetResolved = if (Test-Path -LiteralPath $todayProjectPath) { (Resolve-Path -LiteralPath $todayProjectPath).Path } else { $todayProjectPath }
if ($sourceResolved -ne $targetResolved) {
    Copy-Item -LiteralPath $SourcePath -Destination $todayProjectPath -Force
}

$todayJson = Get-Content -Raw -LiteralPath $todayProjectPath | ConvertFrom-Json
$todayDate = [datetime]$todayJson.scan_date
$previousDateText = $todayDate.AddDays(-1).ToString("yyyy-MM-dd")
$previousPath = Join-Path $OutDir "squeeze-intel-$previousDateText.json"
if (-not (Test-Path -LiteralPath $previousPath)) {
    $downloadPrevious = Join-Path $DownloadsDir "squeeze-intel-$previousDateText.json"
    if (Test-Path -LiteralPath $downloadPrevious) {
        Copy-Item -LiteralPath $downloadPrevious -Destination $previousPath -Force
    }
}

$queueArgs = @{
    TodayPath = $todayProjectPath
    OutDir = $OutDir
}
if (Test-Path -LiteralPath $previousPath) {
    $queueArgs.PreviousPath = $previousPath
}

$queue = & "$PSScriptRoot\Build-SqueezeActionQueue.ps1" @queueArgs
$tosRecon = ""
if ($CaptureTos) {
    $treePath = Join-Path $OutDir "tos-jab-tree-$($todayDate.ToString('yyyyMMdd')).txt"
    & "$PSScriptRoot\tools\Dump-TosJabTree.ps1" -WindowTitle "thinkorswim" -OutFile $treePath -MaxDepth 45 -MaxChildrenPerNode 300 | Out-Null
    $tos = & "$PSScriptRoot\Extract-TosWorkingOrdersFromTree.ps1" -TreePath $treePath -ActionQueuePath $queue.CsvPath -OutDir $OutDir
    $tosRecon = Get-ChildItem -LiteralPath $OutDir -Filter "tos-oco-reconciliation-*.csv" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

[pscustomobject]@{
    SourceJson = $todayProjectPath
    PreviousJson = if (Test-Path -LiteralPath $previousPath) { $previousPath } else { "" }
    ActionQueue = $queue.CsvPath
    PendingEntryTriggers = $queue.PendingEntryTriggers
    ExpectedActiveOcos = $queue.ExpectedActiveOcos
    OcoUpdatesRequired = $queue.OcoUpdatesRequired
    TosReconciliation = $tosRecon
    TradingDashboardBaseUrl = $TradingDashboardBaseUrl
}
