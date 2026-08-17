param(
    [Parameter(Mandatory=$true)][string]$SnapshotJson,
    [Parameter(Mandatory=$true)][string]$LocatorJson,
    [string]$NameRegex = "",
    [string]$RoleRegex = "",
    [int]$Top = 20
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $SnapshotJson)) { throw "SnapshotJson not found: $SnapshotJson" }
if (-not (Test-Path -LiteralPath $LocatorJson)) { throw "LocatorJson not found: $LocatorJson" }

$snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
$locator = Get-Content -LiteralPath $LocatorJson -Raw | ConvertFrom-Json
$weights = $locator.scoring
$minimumConfidence = if ($weights.minimumConfidence) { [int]$weights.minimumConfidence } else { 70 }

$anchorMatches = New-Object System.Collections.Generic.List[object]
foreach ($anchor in @($locator.anchors)) {
    foreach ($node in @($snapshot.nodes)) {
        $nameOk = [string]::IsNullOrWhiteSpace($anchor.nameRegex) -or ($node.name -match $anchor.nameRegex) -or ($node.description -match $anchor.nameRegex) -or ($node.raw -match $anchor.nameRegex)
        $roleOk = [string]::IsNullOrWhiteSpace($anchor.roleRegex) -or ($node.role -match $anchor.roleRegex)
        if ($nameOk -and $roleOk) { $anchorMatches.Add($node) | Out-Null }
    }
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($node in @($snapshot.nodes)) {
    $score = 0
    $reasons = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($NameRegex) -and (($node.name -match $NameRegex) -or ($node.description -match $NameRegex) -or ($node.raw -match $NameRegex))) {
        $score += [int]$weights.nameMatch
        $reasons.Add("name") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($RoleRegex) -and ($node.role -match $RoleRegex)) {
        $score += [int]$weights.roleMatch
        $reasons.Add("role") | Out-Null
    }
    if (($node.states -match 'visible|showing|enabled') -or ($node.raw -match 'states=')) {
        $score += [int]$weights.visibleShowing
        $reasons.Add("state") | Out-Null
    }
    if ($anchorMatches.Count -gt 0 -and $node.bounds) {
        foreach ($anchorNode in $anchorMatches) {
            if (-not $anchorNode.bounds) { continue }
            $dx = [Math]::Abs(([int]$node.bounds.x + ([int]$node.bounds.width / 2)) - ([int]$anchorNode.bounds.x + ([int]$anchorNode.bounds.width / 2)))
            $dy = [Math]::Abs(([int]$node.bounds.y + ([int]$node.bounds.height / 2)) - ([int]$anchorNode.bounds.y + ([int]$anchorNode.bounds.height / 2)))
            if ($dx -le 450 -and $dy -le 220) {
                $score += [int]$weights.nearAnchor
                $reasons.Add("nearAnchor") | Out-Null
                break
            }
        }
    }
    if ($node.bounds -and [int]$node.bounds.width -gt 0 -and [int]$node.bounds.height -gt 0) {
        $score += [int]$weights.insideExpectedRegion
        $reasons.Add("bounds") | Out-Null
    }
    if (($node.accessible.text -eq $true) -or ($node.accessible.value -eq $true) -or ($node.states -match 'focused|editable')) {
        $score += [int]$weights.focusedOrEditable
        $reasons.Add("editable") | Out-Null
    }

    if ($score -gt 0) {
        $results.Add([pscustomobject]@{
            score = $score
            meetsMinimum = ($score -ge $minimumConfidence)
            id = $node.id
            parentId = $node.parentId
            path = $node.path
            depth = $node.depth
            role = $node.role
            name = $node.name
            description = $node.description
            states = $node.states
            bounds = $node.bounds
            childCount = $node.childCount
            reasons = ($reasons -join ',')
        }) | Out-Null
    }
}

$results | Sort-Object score -Descending | Select-Object -First $Top | Format-Table -AutoSize score,meetsMinimum,id,path,role,name,description,states,reasons
if ($anchorMatches.Count -eq 0) {
    Write-Warning "No anchors from locator '$($locator.id)' were found in this snapshot. Capture the intended TOS screen state before using this locator."
}
