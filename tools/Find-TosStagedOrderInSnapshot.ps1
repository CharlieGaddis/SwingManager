param(
    [Parameter(Mandatory=$true)][string]$SnapshotJson,
    [string]$Symbol = "",
    [string]$ReplacingOrderId = "",
    [string]$OcoId = "",
    [string]$Threshold = "",
    [string]$StatusRegex = "WAIT COND|WORKING|CANCELED|FILLED"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $SnapshotJson)) { throw "SnapshotJson not found: $SnapshotJson" }
$snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
$nodes = @($snapshot.nodes)
$foundRows = New-Object System.Collections.Generic.List[object]

foreach ($node in $nodes) {
    if ($node.role -ne 'label') { continue }
    if ([string]::IsNullOrWhiteSpace($node.name)) { continue }
    $name = [string]$node.name
    if (-not [string]::IsNullOrWhiteSpace($Symbol) -and $name -notmatch "\b$([regex]::Escape($Symbol))\b") { continue }
    if (-not [string]::IsNullOrWhiteSpace($ReplacingOrderId) -and $name -notmatch "Replacing #$([regex]::Escape($ReplacingOrderId))") { continue }
    if (-not [string]::IsNullOrWhiteSpace($OcoId) -and $name -notmatch "OCO #$([regex]::Escape($OcoId))") { continue }
    if (-not [string]::IsNullOrWhiteSpace($Threshold) -and $name -notmatch [regex]::Escape($Threshold)) { continue }

    $siblings = @($nodes | Where-Object { $_.parentId -eq $node.parentId } | Sort-Object id)
    $idx = [Array]::IndexOf([object[]]$siblings, $node)
    $status = $null
    $orderId = $null
    $timePlaced = $null
    $window = @()
    if ($idx -ge 0) {
        $start = [Math]::Max(0, $idx - 4)
        $end = [Math]::Min($siblings.Count - 1, $idx + 4)
        $window = $siblings[$start..$end]
        $status = $window | Where-Object { $_.role -eq 'label' -and $_.name -match $StatusRegex } | Select-Object -First 1
        $orderId = $window | Where-Object { $_.role -eq 'label' -and $_.name -match '^\d{10,}$' } | Select-Object -Last 1
        $timePlaced = $window | Where-Object { $_.role -eq 'label' -and $_.name -match '^\d{1,2}/\d{1,2}/\d{2}\s+\d{2}:\d{2}:\d{2}$' } | Select-Object -Last 1
    }

    $match = [pscustomobject]@{
        id = $node.id
        parentId = $node.parentId
        path = $node.path
        rowIndexEstimate = if ($idx -ge 0) { [int]([Math]::Floor($idx / 8)) } else { $null }
        cellIndex = $idx
        timePlaced = if ($timePlaced) { $timePlaced.name } else { '' }
        orderId = if ($orderId) { $orderId.name } else { '' }
        status = if ($status) { $status.name } else { '' }
        text = $name
        context = @($window | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) } | Select-Object role,name,path)
    }
    $foundRows.Add($match) | Out-Null
}

$result = [pscustomobject]@{
    source = $SnapshotJson
    symbol = $Symbol
    replacingOrderId = $ReplacingOrderId
    ocoId = $OcoId
    threshold = $Threshold
    matchCount = $foundRows.Count
    uniqueMatch = ($foundRows.Count -eq 1)
    matches = $foundRows
}
$result | ConvertTo-Json -Depth 10


