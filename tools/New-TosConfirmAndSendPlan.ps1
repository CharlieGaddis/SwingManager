param(
    [Parameter(Mandatory=$true)][string]$SnapshotJson,
    [Parameter(Mandatory=$true)][string]$Symbol,
    [Parameter(Mandatory=$true)][string]$ReplacingOrderId,
    [Parameter(Mandatory=$true)][string]$OcoId,
    [Parameter(Mandatory=$true)][string]$Threshold,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not (Test-Path -LiteralPath $SnapshotJson)) { throw "SnapshotJson not found: $SnapshotJson" }
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = ($Symbol -replace '[^A-Za-z0-9_.-]+', '-')
    $OutFile = Join-Path $projectRoot "TosAutomation\Diagnostics\tos-confirm-send-plan-$safeSymbol-$stamp.json"
}

$rowJson = & (Join-Path $scriptDir 'Find-TosStagedOrderInSnapshot.ps1') -SnapshotJson $SnapshotJson -Symbol $Symbol -ReplacingOrderId $ReplacingOrderId -OcoId $OcoId -Threshold $Threshold
$rowResult = $rowJson | ConvertFrom-Json
$snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
$nodes = @($snapshot.nodes)
$confirm = $nodes | Where-Object { $_.role -eq 'push button' -and $_.name -eq 'Confirm and Send' -and $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 } | Select-Object -First 1

$errors = New-Object System.Collections.Generic.List[string]
if ($rowResult.uniqueMatch -ne $true) { $errors.Add("Expected exactly one staged row match but found $($rowResult.matchCount).") | Out-Null }
if (-not $confirm) { $errors.Add("Visible Confirm and Send button was not found.") | Out-Null }
$status = if ($rowResult.uniqueMatch) { $rowResult.matches[0].status } else { '' }
if ($status -ne 'WAIT COND' -and $status -ne 'WORKING') { $errors.Add("Unexpected staged row status '$status'.") | Out-Null }

$clickPoint = $null
if ($confirm) {
    $clickPoint = [pscustomobject]@{
        x = [int]([int]$confirm.bounds.x + ([int]$confirm.bounds.width / 2))
        y = [int]([int]$confirm.bounds.y + ([int]$confirm.bounds.height / 2))
    }
}

$plan = [pscustomobject]@{
    createdAt = (Get-Date).ToString("o")
    dryRun = $true
    snapshot = $SnapshotJson
    symbol = $Symbol
    replacingOrderId = $ReplacingOrderId
    ocoId = $OcoId
    threshold = $Threshold
    stagedRow = $rowResult
    confirmAndSendButton = $confirm
    clickPoint = $clickPoint
    allowedToSubmit = ($errors.Count -eq 0)
    requiredExecutionFlag = "-AllowSubmit"
    warnings = @(
        "This plan does not click Confirm and Send.",
        "Final submit/replace must be run as a separate explicitly approved step.",
        "After clicking Confirm and Send, TOS may show an additional confirmation dialog that must be verified before final send."
    )
    errors = @($errors)
}
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$plan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$plan | ConvertTo-Json -Depth 14
Write-Host "Wrote Confirm and Send plan to $OutFile"
