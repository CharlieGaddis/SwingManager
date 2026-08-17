param(
    [Parameter(Mandatory=$true)][string]$TreePath,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "TosPrivacyRedactor.psm1") -Force
if (-not (Test-Path -LiteralPath $TreePath)) { throw "TreePath not found: $TreePath" }
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = [System.IO.Path]::ChangeExtension($TreePath, ".json")
}

$lines = Get-Content -LiteralPath $TreePath
$nodes = New-Object System.Collections.Generic.List[object]
$stack = @{}
$pathById = @{}
$nextChildIndexByParent = @{}
$id = 0

foreach ($line in $lines) {
    if ($line -notmatch '^(?<indent>\s*)-\s+(?<body>.*)$') { continue }
    $indent = $matches.indent.Length
    $depth = [int]($indent / 2)
    $body = ConvertTo-TosSanitizedText $matches.body
    if ($body -like '<unreadable*') { continue }

    $role = ""
    $name = ""
    $description = ""
    $states = ""
    $children = $null
    $bounds = $null
    $flags = [ordered]@{ component=$null; action=$null; text=$null; value=$null }

    if ($body -match 'role="(?<v>[^"]*)"') { $role = $matches.v }
    if ($body -match 'name="(?<v>[^"]*)"') { $name = $matches.v }
    if ($body -match 'description="(?<v>[^"]*)"') { $description = $matches.v }
    if ($body -match 'children=(?<v>-?\d+)') { $children = [int]$matches.v }
    if ($body -match 'bounds=(?<x>-?\d+),(?<y>-?\d+),(?<w>-?\d+),(?<h>-?\d+)') {
        $bounds = [ordered]@{ x=[int]$matches.x; y=[int]$matches.y; width=[int]$matches.w; height=[int]$matches.h }
    }
    if ($body -match 'states="(?<v>[^"]*)"') { $states = $matches.v }
    if ($body -match 'comp=(?<v>True|False)') { $flags.component = [bool]::Parse($matches.v) }
    if ($body -match 'act=(?<v>True|False)') { $flags.action = [bool]::Parse($matches.v) }
    if ($body -match 'text=(?<v>True|False)') { $flags.text = [bool]::Parse($matches.v) }
    if ($body -match 'value=(?<v>True|False)') { $flags.value = [bool]::Parse($matches.v) }

    $parentId = if ($depth -gt 0 -and $stack.ContainsKey($depth - 1)) { $stack[$depth - 1] } else { $null }
    $parentKey = if ($null -eq $parentId) { "root" } else { [string]$parentId }
    if (-not $nextChildIndexByParent.ContainsKey($parentKey)) { $nextChildIndexByParent[$parentKey] = 0 }
    $sameDepthIndex = [int]$nextChildIndexByParent[$parentKey]
    $nextChildIndexByParent[$parentKey] = $sameDepthIndex + 1
    $path = if ($depth -gt 0 -and $parentId -ne $null -and $pathById.ContainsKey($parentId)) {
        "$($pathById[$parentId]).$sameDepthIndex"
    } else {
        "$sameDepthIndex"
    }

    $node = [pscustomobject]@{
        id = $id
        parentId = $parentId
        path = $path
        depth = $depth
        role = $role
        name = ConvertTo-TosSanitizedText $name
        description = ConvertTo-TosSanitizedText $description
        states = $states
        bounds = $bounds
        childCount = $children
        accessible = $flags
        raw = ConvertTo-TosSanitizedText $body
    }
    $nodes.Add($node) | Out-Null
    $pathById[$id] = $path
    $stack[$depth] = $id
    $removeDepths = @($stack.Keys | Where-Object { $_ -gt $depth })
    foreach ($key in $removeDepths) { $stack.Remove($key) }
    $id++
}

$result = [pscustomobject]@{
    sourceTree = $TreePath
    generatedAt = (Get-Date).ToString("o")
    nodeCount = $nodes.Count
    nodes = $nodes
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutFile -Encoding UTF8
[pscustomobject]@{ TreePath=$TreePath; OutFile=$OutFile; NodeCount=$nodes.Count } | Format-List

