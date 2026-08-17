param(
    [Parameter(Mandatory=$true)][string]$SnapshotJson
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $SnapshotJson)) { throw "SnapshotJson not found: $SnapshotJson" }
$snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
$nodes = @($snapshot.nodes)
$byId = @{}
foreach ($node in $nodes) { $byId[[int]$node.id] = $node }

function Get-Children($Node) {
    @($nodes | Where-Object { $_.parentId -eq $Node.id } | Sort-Object id)
}

function Node-Center($Node) {
    if (-not $Node.bounds) { return $null }
    if ([int]$Node.bounds.width -le 0 -or [int]$Node.bounds.height -le 0) { return $null }
    [pscustomobject]@{
        x = [int]([int]$Node.bounds.x + ([int]$Node.bounds.width / 2))
        y = [int]([int]$Node.bounds.y + ([int]$Node.bounds.height / 2))
    }
}

$submitAtLabel = $nodes | Where-Object { $_.role -eq 'label' -and $_.name -eq 'Submit at:' } | Select-Object -First 1
$submitWhenLabel = $nodes | Where-Object { $_.role -eq 'label' -and $_.name -match '^Submit when at least one' } | Select-Object -First 1
$saveButton = $nodes | Where-Object { $_.role -eq 'push button' -and $_.name -eq 'Save' } | Select-Object -First 1
$cancelButton = $nodes | Where-Object { $_.role -eq 'push button' -and $_.name -eq 'Cancel' } | Select-Object -First 1

$submitAtCheckbox = $null
if ($submitAtLabel) {
    $candidateBoxes = $nodes | Where-Object {
        $_.role -eq 'check box' -and $_.bounds -and
        [int]$_.bounds.y -ge ([int]$submitAtLabel.bounds.y - 8) -and
        [int]$_.bounds.y -le ([int]$submitAtLabel.bounds.y + 8) -and
        [int]$_.bounds.x -lt [int]$submitAtLabel.bounds.x
    } | Sort-Object @{ Expression = { [Math]::Abs([int]$_.bounds.y - [int]$submitAtLabel.bounds.y) } }
    $submitAtCheckbox = $candidateBoxes | Select-Object -First 1
}

$submitConditionTable = $null
if ($submitWhenLabel) {
    $tables = $nodes | Where-Object { $_.role -eq 'table' -and $_.bounds -and [int]$_.bounds.y -gt [int]$submitWhenLabel.bounds.y }
    $submitConditionTable = $tables | Sort-Object @{ Expression = { [Math]::Abs([int]$_.bounds.x - [int]$submitWhenLabel.bounds.x) } }, @{ Expression = { [int]$_.bounds.y } } | Select-Object -First 1
}

$row = $null
$rowCells = @()
if ($submitConditionTable) {
    $rowCells = Get-Children $submitConditionTable
    $rowDescendants = @($nodes | Where-Object { $_.path -like "$($submitConditionTable.path).*" })
    $symbol = $rowCells | Where-Object { $_.role -eq 'label' -and -not [string]::IsNullOrWhiteSpace($_.name) } | Select-Object -First 1
    $method = $rowDescendants | Where-Object { $_.role -eq 'label' -and $_.name -match '^(MARK|LAST|BID|ASK)$' -and $_.states -match 'selected' } | Select-Object -First 1
    $operator = $rowDescendants | Where-Object { $_.role -eq 'label' -and $_.name -match '^(>=|<=|>|<)$' -and $_.states -match 'selected' } | Select-Object -First 1
    $thresholdEditor = $rowCells | Where-Object { $_.role -eq 'spinbox' -or $_.accessible.text -eq $true -or $_.accessible.value -eq $true } | Select-Object -Last 1
    $row = [pscustomobject]@{
        symbol = if ($symbol) { $symbol.name } else { '' }
        method = if ($method -and $method.raw -match 'name="(?<v>[^"]+)"') { $matches.v } else { '' }
        operator = if ($operator -and $operator.raw -match 'name="(?<v>[^"]+)"') { $matches.v } else { '' }
        tableBounds = $submitConditionTable.bounds
        tablePath = $submitConditionTable.path
        thresholdEditorPath = if ($thresholdEditor) { $thresholdEditor.path } else { '' }
        thresholdEditorBounds = if ($thresholdEditor) { $thresholdEditor.bounds } else { $null }
        thresholdClickEstimate = if ($submitConditionTable.bounds) {
            [pscustomobject]@{
                x = [int]([int]$submitConditionTable.bounds.x + ([int]$submitConditionTable.bounds.width * 0.82))
                y = [int]([int]$submitConditionTable.bounds.y + ([int]$submitConditionTable.bounds.height / 2))
            }
        } else { $null }
    }
}

[pscustomobject]@{
    source = $SnapshotJson
    nodeCount = $snapshot.nodeCount
    inferred = [ordered]@{
        hasSubmitAt = [bool]$submitAtLabel
        submitAtChecked = if ($submitAtCheckbox) { $submitAtCheckbox.states -match 'checked' } else { $null }
        hasSubmitWhen = [bool]$submitWhenLabel
        hasSubmitConditionTable = [bool]$submitConditionTable
        hasSave = [bool]$saveButton
        hasCancel = [bool]$cancelButton
    }
    controls = [ordered]@{
        submitAtCheckbox = $submitAtCheckbox
        submitWhenLabel = $submitWhenLabel
        submitConditionTable = $submitConditionTable
        saveButton = $saveButton
        cancelButton = $cancelButton
    }
    submitConditionRow = $row
} | ConvertTo-Json -Depth 12

