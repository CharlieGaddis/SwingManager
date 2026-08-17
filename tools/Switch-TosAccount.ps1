param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("IRA", "Living Trust")]
    [string]$TargetAccount,
    [switch]$AllowInput,
    [string]$WindowTitle = "Main@thinkorswim",
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
$diagnosticsDir = Join-Path $projectRoot "TosAutomation\Diagnostics"
$discoveryDir = Join-Path $projectRoot "TosAutomation\Discovery"
if (-not (Test-Path -LiteralPath $diagnosticsDir)) { New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null }
if (-not (Test-Path -LiteralPath $discoveryDir)) { New-Item -ItemType Directory -Force -Path $discoveryDir | Out-Null }

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeTarget = $TargetAccount -replace '[^A-Za-z0-9_.-]+', '-'
    $OutFile = Join-Path $diagnosticsDir "tos-account-switch-$safeTarget-$stamp.json"
}

function Normalize-TosAccountAlias {
    param([string]$Alias)
    $text = ([string]$Alias).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    if ($text -match '(?i)\bIRA\b|Rollover IRA') { return "IRA" }
    if ($text -match '(?i)Living Trust') { return "Living Trust" }
    return $text
}

function Get-ExpectedAccountEnding {
    param([string]$Alias)
    $normalized = Normalize-TosAccountAlias $Alias
    if ($normalized -eq "IRA") { return "5682" }
    if ($normalized -eq "Living Trust") { return "9157" }
    return ""
}

function New-SnapshotJson {
    param([string]$Label)
    $snapshotScript = Join-Path $scriptDir "New-TosAutomationSnapshot.ps1"
    $started = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $snapshotScript -WindowTitle $WindowTitle -Label $Label -MaxDepth 35 -MaxChildrenPerNode 1200 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Snapshot command failed for $Label with exit code $LASTEXITCODE." }
    $snapshot = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-$Label-*-tree.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $snapshot) { throw "Fresh snapshot JSON was not produced for $Label." }
    return $snapshot.FullName
}

function Get-CurrentAccount {
    param([object[]]$Nodes)
    $node = @($Nodes | Where-Object {
        $_.role -eq 'label' -and
        $_.name -match '^(?<number>\d{8}|ACCOUNT_REDACTED)SCHW\s+\((?<alias>[^)]+)\)' -and
        $_.states -match 'showing' -and
        [int]$_.bounds.x -ge 0 -and
        [int]$_.bounds.y -ge 0
    } | Sort-Object @{ Expression = { [int]$_.bounds.y } }, @{ Expression = { [int]$_.bounds.x } }) | Select-Object -First 1

    if (-not $node) {
        return [pscustomobject]@{ Alias = ""; Ending = ""; Label = ""; Node = $null }
    }

    $match = [regex]::Match([string]$node.name, '^(?<number>\d{8}|ACCOUNT_REDACTED)SCHW\s+\((?<alias>[^)]+)\)')
    $alias = Normalize-TosAccountAlias $match.Groups['alias'].Value
    $ending = if ($match.Groups['number'].Value -eq 'ACCOUNT_REDACTED') {
        Get-ExpectedAccountEnding $alias
    } else {
        $match.Groups['number'].Value.Substring($match.Groups['number'].Value.Length - 4)
    }
    return [pscustomobject]@{ Alias = $alias; Ending = $ending; Label = [string]$node.name; Node = $node }
}

function Invoke-JabAction {
    param([string]$Name, [string]$Path, [string]$ExpectedRole)
    if (-not $AllowInput) { throw "$Name requires -AllowInput." }
    $actionScript = Join-Path $scriptDir "Invoke-TosJabActionPath.ps1"
    $args = @("-WindowTitle", $WindowTitle, "-Path", $Path, "-ExpectedRole", $ExpectedRole, "-OutFile", (Join-Path $diagnosticsDir ("tos-account-switch-{0}-{1}.json" -f $Name, (Get-Date -Format "yyyyMMdd-HHmmss"))), "-AllowAction")
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $actionScript @args
    return [pscustomobject]@{ name = $Name; output = ($output | Out-String).Trim(); exitCode = $LASTEXITCODE }
}

function Find-AccountToggle {
    param([object[]]$Nodes, [object]$AccountNode)
    if (-not $AccountNode) { return $null }
    $parent = $Nodes | Where-Object { $_.id -eq $AccountNode.parentId } | Select-Object -First 1
    if ($parent -and $parent.role -eq "toggle button" -and [int]$parent.bounds.width -gt 0 -and [int]$parent.bounds.height -gt 0) {
        return $parent
    }
    return @($Nodes | Where-Object {
        $_.role -eq "toggle button" -and
        [int]$_.bounds.width -gt 100 -and
        [int]$_.bounds.height -gt 10 -and
        [int]$_.bounds.y -ge 80 -and
        [int]$_.bounds.y -le 180
    } | Sort-Object @{ Expression = { [int]$_.bounds.y } }, @{ Expression = { [int]$_.bounds.x } }) | Select-Object -First 1
}

function Find-TargetAccountChoice {
    param([object[]]$Nodes, [string]$Wanted)
    $wantedAlias = Normalize-TosAccountAlias $Wanted
    return @($Nodes | Where-Object {
        $_.role -eq "label" -and
        $_.states -match "selectable" -and
        $_.name -match "ACCOUNT_REDACTED|\d{8}" -and
        (Normalize-TosAccountAlias ([string]$_.name)) -eq $wantedAlias
    } | Sort-Object id) | Select-Object -First 1
}

$steps = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
$targetAlias = Normalize-TosAccountAlias $TargetAccount
$targetEnding = Get-ExpectedAccountEnding $targetAlias
$initialSnapshot = ""
$dropdownSnapshot = ""
$verifySnapshot = ""
$initialAccount = $null
$verifiedAccount = $null

try {
    $initialSnapshot = New-SnapshotJson "AccountSwitchInitial-$($targetAlias -replace '[^A-Za-z0-9_.-]+','-')"
    $initialNodes = @((Get-Content -LiteralPath $initialSnapshot -Raw | ConvertFrom-Json).nodes)
    $initialAccount = Get-CurrentAccount $initialNodes
    $steps.Add([pscustomobject]@{ name = "InitialSnapshot"; snapshotJson = $initialSnapshot; account = $initialAccount }) | Out-Null

    if ($initialAccount.Alias -eq $targetAlias) {
        $verifiedAccount = $initialAccount
    } else {
        $toggle = Find-AccountToggle -Nodes $initialNodes -AccountNode $initialAccount.Node
        if (-not $toggle) { throw "Could not locate the top TOS account selector toggle." }
        $steps.Add((Invoke-JabAction -Name "OpenAccountSelector" -Path ([string]$toggle.path) -ExpectedRole "toggle button")) | Out-Null
        Start-Sleep -Milliseconds 1000

        $dropdownSnapshot = New-SnapshotJson "AccountSwitchDropdown-$($targetAlias -replace '[^A-Za-z0-9_.-]+','-')"
        $dropdownNodes = @((Get-Content -LiteralPath $dropdownSnapshot -Raw | ConvertFrom-Json).nodes)
        $targetChoice = Find-TargetAccountChoice -Nodes $dropdownNodes -Wanted $targetAlias
        if (-not $targetChoice) { throw "Could not locate account choice for $targetAlias in the TOS account selector." }
        $steps.Add([pscustomobject]@{ name = "DropdownSnapshot"; snapshotJson = $dropdownSnapshot; targetChoicePath = $targetChoice.path; targetChoiceName = $targetChoice.name }) | Out-Null
        $steps.Add((Invoke-JabAction -Name "ChooseAccount" -Path ([string]$targetChoice.path) -ExpectedRole "label")) | Out-Null
        Start-Sleep -Milliseconds 1800

        $verifySnapshot = New-SnapshotJson "AccountSwitchVerify-$($targetAlias -replace '[^A-Za-z0-9_.-]+','-')"
        $verifyNodes = @((Get-Content -LiteralPath $verifySnapshot -Raw | ConvertFrom-Json).nodes)
        $verifiedAccount = Get-CurrentAccount $verifyNodes
        $steps.Add([pscustomobject]@{ name = "VerifySnapshot"; snapshotJson = $verifySnapshot; account = $verifiedAccount }) | Out-Null
    }

    if ($verifiedAccount.Alias -ne $targetAlias) {
        $errors.Add("TOS account switch verification failed. Expected $targetAlias but saw '$($verifiedAccount.Alias)'.") | Out-Null
    }
    if ($targetEnding -and $verifiedAccount.Ending -and $verifiedAccount.Ending -ne $targetEnding) {
        $errors.Add("TOS account ending verification failed. Expected $targetEnding but saw '$($verifiedAccount.Ending)'.") | Out-Null
    }
} catch {
    $errors.Add($_.Exception.Message) | Out-Null
}

$result = [ordered]@{
    createdAt = (Get-Date).ToString("o")
    targetAccount = [ordered]@{ alias = $targetAlias; ending = $targetEnding }
    initialAccount = $initialAccount
    verifiedAccount = $verifiedAccount
    initialSnapshot = $initialSnapshot
    dropdownSnapshot = $dropdownSnapshot
    verifySnapshot = $verifySnapshot
    allowInput = [bool]$AllowInput
    steps = @($steps.ToArray())
    errors = @($errors.ToArray())
    success = ($errors.Count -eq 0)
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 18
Write-Host "Wrote TOS account switch result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }
