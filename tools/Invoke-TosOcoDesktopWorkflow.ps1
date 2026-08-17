param(
    [string]$BatchPath = "",
    [Parameter(Mandatory=$true)][string]$Symbol,
    [ValidateSet("", "Stop", "T1", "T2")]
    [string]$Phase = "",
    [string]$OcoId = "",
    [string]$ReplacingOrderId = "",
    [ValidateSet("Plan", "OpenCancelReplace", "SetThreshold", "OpenConfirmation", "VerifyConfirmation", "FinalSend", "RunToConfirmation", "RunToFinalSend")]
    [string]$Stage = "Plan",
    [switch]$AllowInput,
    [switch]$AllowFinalSend,
    [string]$WindowTitle = "Main@thinkorswim",
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
$analysisDir = Join-Path $projectRoot "Analysis"
$diagnosticsDir = Join-Path $projectRoot "TosAutomation\Diagnostics"
$discoveryDir = Join-Path $projectRoot "TosAutomation\Discovery"
if (-not (Test-Path -LiteralPath $diagnosticsDir)) { New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null }
if (-not (Test-Path -LiteralPath $discoveryDir)) { New-Item -ItemType Directory -Force -Path $discoveryDir | Out-Null }

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
    $safeSymbol = $Symbol.ToUpperInvariant() -replace '[^A-Z0-9_.-]+', '-'
    $OutFile = Join-Path $diagnosticsDir "tos-oco-desktop-workflow-$safeSymbol-$Stage-$stamp.json"
}

function Invoke-WorkflowStep {
    param([string]$Name, [string]$Script, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Script)) { throw "Missing workflow script for $Name`: $Script" }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments
    return [pscustomobject]@{
        name = $Name
        script = $Script
        arguments = @($Arguments)
        output = ($output | Out-String).Trim()
        exitCode = $LASTEXITCODE
    }
}

function Invoke-WorkflowStepWithTimeout {
    param(
        [string]$Name,
        [string]$Script,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 90
    )
    if (-not (Test-Path -LiteralPath $Script)) { throw "Missing workflow script for $Name`: $Script" }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeName = $Name -replace '[^A-Za-z0-9_.-]+', '-'
    $stdout = Join-Path $diagnosticsDir "tos-workflow-step-$safeName-$stamp.out.txt"
    $stderr = Join-Path $diagnosticsDir "tos-workflow-step-$safeName-$stamp.err.txt"
    function ConvertTo-NativeQuotedArgument([string]$Value) {
        if ($null -eq $Value) { return '""' }
        if ($Value -notmatch '[\s"]') { return $Value }
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    $argList = (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Script) + @($Arguments) | ForEach-Object { ConvertTo-NativeQuotedArgument ([string]$_) }) -join " "

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = $argList
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw "Failed to start child workflow process for $Name." }
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    $timedOut = -not $completed
    if ($timedOut) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 300
    }

    $output = $process.StandardOutput.ReadToEnd().Trim()
    $errorText = $process.StandardError.ReadToEnd().Trim()
    $output | Set-Content -LiteralPath $stdout -Encoding UTF8
    $errorText | Set-Content -LiteralPath $stderr -Encoding UTF8
    $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    return [pscustomobject]@{
        name = $Name
        script = $Script
        arguments = @($Arguments)
        timeoutSeconds = $TimeoutSeconds
        timedOut = $timedOut
        output = $output
        stderr = $errorText
        stdoutPath = $stdout
        stderrPath = $stderr
        exitCode = $exitCode
    }
}

function Get-SelectedBatchItem {
    param([object]$Batch)
    $items = @($Batch.items | Where-Object {
        $_.Action -eq 'update_condition_threshold' -and
        $_.ReadyForDesktopAutomation -eq $true -and
        $_.AccountVerified -eq $true -and
        ([string]$_.SnapshotStatus).Trim().ToUpperInvariant() -notmatch 'CANCELED|FILLED'
    })
    $want = $Symbol.Trim().ToUpperInvariant()
    $items = @($items | Where-Object { ([string]$_.Symbol).Trim().ToUpperInvariant() -eq $want })
    if (-not [string]::IsNullOrWhiteSpace($Phase)) { $items = @($items | Where-Object { $_.Phase -eq $Phase }) }
    if (-not [string]::IsNullOrWhiteSpace($OcoId)) { $items = @($items | Where-Object { [string]$_.OcoId -eq [string]$OcoId }) }
    if (-not [string]::IsNullOrWhiteSpace($ReplacingOrderId)) { $items = @($items | Where-Object { [string]$_.ReplacingOrderId -eq [string]$ReplacingOrderId }) }
    return @($items)
}

function Get-ExpectedConfirmationReplacingOrderId($Item) {
    $current = ([string]$Item.CurrentOrderId).Trim()
    if (-not [string]::IsNullOrWhiteSpace($current)) { return $current }
    return ([string]$Item.ReplacingOrderId).Trim()
}

function Get-ExpectedOrderDescriptionRegex($Item) {
    $symbolPattern = [regex]::Escape(([string]$Item.Symbol).Trim())
    $typePattern = [regex]::Escape(([string]$Item.OrderType).Trim())
    if ([string]::IsNullOrWhiteSpace($typePattern)) { $typePattern = 'STP|LMT' }
    return "\b$symbolPattern\b.*\b($typePattern)\b"
}

function New-SnapshotJson {
    param([string]$Label, [string]$SnapshotWindowTitle = $WindowTitle)
    $snapshotScript = Join-Path $scriptDir "New-TosAutomationSnapshot.ps1"
    if (-not (Test-Path -LiteralPath $snapshotScript)) { throw "Missing snapshot script: $snapshotScript" }
    $started = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $snapshotScript -WindowTitle $SnapshotWindowTitle -Label $Label -MaxDepth 35 -MaxChildrenPerNode 1000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Snapshot command failed for label $Label with exit code $LASTEXITCODE." }
    $snapshot = Get-ChildItem -LiteralPath $discoveryDir -Filter "tos-$Label-*-tree.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $snapshot) { throw "Fresh snapshot JSON was not produced for label $Label." }
    return $snapshot.FullName
}


function Get-ClickPointFromNode($Node) {
    if (-not $Node -or -not $Node.bounds -or [int]$Node.bounds.width -le 0 -or [int]$Node.bounds.height -le 0) { return $null }
    return [pscustomobject]@{
        x = [int]([int]$Node.bounds.x + ([int]$Node.bounds.width / 2))
        y = [int]([int]$Node.bounds.y + ([int]$Node.bounds.height / 2))
    }
}

function Click-Point {
    param([object]$Point, [string]$Reason)
    if (-not $Point) { throw "Cannot click missing point for $Reason." }
    $inputScript = Join-Path $scriptDir "Invoke-TosNativeInput.ps1"
    $args = @("-Action", "Click", "-X", [string]$Point.x, "-Y", [string]$Point.y)
    if ($AllowInput) { $args += "-AllowInput" }
    return Invoke-WorkflowStep -Name $Reason -Script $inputScript -Arguments $args
}

$batch = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json
$items = @(Get-SelectedBatchItem $batch)
$errors = New-Object System.Collections.Generic.List[string]
$steps = New-Object System.Collections.Generic.List[object]
if ($items.Count -eq 0) { $errors.Add("No verified ready desktop OCO update item matched the requested filters.") | Out-Null }
if ($items.Count -gt 1) { $errors.Add("More than one ready item matched. Add Phase, OcoId, or ReplacingOrderId.") | Out-Null }
if ($Stage -in @('OpenCancelReplace','SetThreshold','OpenConfirmation','FinalSend','RunToConfirmation','RunToFinalSend') -and -not $AllowInput) { $errors.Add("$Stage requires -AllowInput.") | Out-Null }
if ($Stage -in @('FinalSend','RunToFinalSend') -and -not $AllowFinalSend) { $errors.Add("$Stage requires -AllowFinalSend.") | Out-Null }
$item = $items | Select-Object -First 1

$expectedConditionText = $null
if ($item) {
    $side = ([string]$item.CurrentConditionSide).Trim().ToUpperInvariant()
    if ($side -eq 'BELOW') { $expectedConditionText = "$($item.Symbol) MARK AT OR BELOW $($item.ExpectedThreshold)" }
    elseif ($side -eq 'ABOVE') { $expectedConditionText = "$($item.Symbol) MARK AT OR ABOVE $($item.ExpectedThreshold)" }
    else { $errors.Add("Unsupported condition side '$($item.CurrentConditionSide)'.") | Out-Null }
}

$confirmationPlan = $null
$confirmSnapshot = ""
$buttonPlan = $null

try {
    if ($errors.Count -eq 0) {
        switch ($Stage) {
            'Plan' {
                $snapshot = New-SnapshotJson "OcoWorkflowPlan-$($item.Symbol -replace '[^A-Za-z0-9_.-]+','-')"
                $steps.Add([pscustomobject]@{ name='Snapshot'; snapshotJson=$snapshot }) | Out-Null
            }
            'OpenCancelReplace' {
                $guardScript = Join-Path $scriptDir "Ensure-TosMonitorWorkingOrders.ps1"
                $guardArgs = @("-WindowTitle", $WindowTitle)
                if ($AllowInput) { $guardArgs += "-AllowInput" }
                $guard = Invoke-WorkflowStep -Name "EnsureMonitorWorkingOrders" -Script $guardScript -Arguments $guardArgs
                $steps.Add($guard) | Out-Null
                if ($guard.exitCode -ne 0) {
                    $errors.Add("EnsureMonitorWorkingOrders failed with exit code $($guard.exitCode).") | Out-Null
                    break
                }
                $openScript = Join-Path $scriptDir "Open-TosCancelReplaceFromBatch.ps1"
                $args = @("-BatchPath", $BatchPath, "-Symbol", [string]$item.Symbol, "-Phase", [string]$item.Phase, "-OcoId", [string]$item.OcoId, "-ReplacingOrderId", [string]$item.ReplacingOrderId, "-Stage", "ClickCancelReplace", "-WindowTitle", $WindowTitle)
                if ($AllowInput) { $args += "-AllowInput" }
                $step = Invoke-WorkflowStep -Name "OpenCancelReplace" -Script $openScript -Arguments $args
                $steps.Add($step) | Out-Null
                if ($step.exitCode -ne 0) { $errors.Add("OpenCancelReplace failed with exit code $($step.exitCode).") | Out-Null }
            }
            'SetThreshold' {
                $surfaceGuardScript = Join-Path $scriptDir "Ensure-TosOrderEntryMaintenanceSurface.ps1"
                $surfaceGuardArgs = @("-WindowTitle", $WindowTitle)
                if ($AllowInput) { $surfaceGuardArgs += "-AllowInput" }
                $surfaceGuard = Invoke-WorkflowStep -Name "EnsureOrderEntryMaintenanceSurface" -Script $surfaceGuardScript -Arguments $surfaceGuardArgs
                $steps.Add($surfaceGuard) | Out-Null
                if ($surfaceGuard.exitCode -ne 0) {
                    $errors.Add("EnsureOrderEntryMaintenanceSurface failed with exit code $($surfaceGuard.exitCode).") | Out-Null
                    break
                }
                $snapshot = New-SnapshotJson "OcoWorkflowSetThreshold-$($item.Symbol -replace '[^A-Za-z0-9_.-]+','-')"
                $setScript = Join-Path $scriptDir "Set-TosActiveOrderEntryTriggerThreshold.ps1"
                $args = @("-BatchPath", $BatchPath, "-Symbol", [string]$item.Symbol, "-Phase", [string]$item.Phase, "-OcoId", [string]$item.OcoId, "-ReplacingOrderId", [string]$item.ReplacingOrderId, "-SnapshotJson", $snapshot, "-WindowTitle", $WindowTitle)
                if ($AllowInput) { $args += "-AllowInput" }
                $step = Invoke-WorkflowStepWithTimeout -Name "SetThreshold" -Script $setScript -Arguments $args -TimeoutSeconds 120
                $steps.Add([pscustomobject]@{ name='PreSetSnapshot'; snapshotJson=$snapshot }) | Out-Null
                $steps.Add($step) | Out-Null
                if ($step.timedOut -eq $true) { $errors.Add("SetThreshold timed out after $($step.timeoutSeconds) seconds. The staged ticket was left unsent; inspect/clear it before retrying.") | Out-Null }
                if ($step.exitCode -ne 0) { $errors.Add("SetThreshold failed with exit code $($step.exitCode).") | Out-Null }
            }
            'OpenConfirmation' {
                $snapshot = New-SnapshotJson "OcoWorkflowPreConfirm-$($item.Symbol -replace '[^A-Za-z0-9_.-]+','-')"
                $snap = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
                $nodes = @($snap.nodes)
                $entryAccordion = @($nodes | Where-Object { $_.role -eq 'toggle button' -and $_.name -eq 'Order Entry and Saved Orders' -and $_.states -match 'checked' -and $_.states -match 'showing' })
                $strategyBook = @($nodes | Where-Object { $_.role -eq 'toggle button' -and $_.name -eq 'Order and Strategy Book' -and $_.states -match 'checked' })
                $entryTabs = @($nodes | Where-Object { $_.role -eq 'page tab' -and $_.name -eq 'Order Entry' -and $_.states -match 'selected' -and $_.states -match 'showing' })
                $confirm = $nodes | Where-Object { $_.role -eq 'push button' -and $_.name -eq 'Confirm and Send' -and $_.bounds -and [int]$_.bounds.width -gt 0 -and [int]$_.bounds.height -gt 0 } | Select-Object -First 1
                if ($entryAccordion.Count -ne 1) { $errors.Add("Order Entry and Saved Orders is not open in pre-confirm snapshot.") | Out-Null }
                if ($strategyBook.Count -gt 0) { $errors.Add("Order and Strategy Book is open in pre-confirm snapshot.") | Out-Null }
                if ($entryTabs.Count -ne 1) { $errors.Add("Order Entry tab is not selected in pre-confirm snapshot.") | Out-Null }
                if (-not $confirm) { $errors.Add("Confirm and Send button was not found in pre-confirm snapshot.") | Out-Null }
                $buttonPlan = [pscustomobject]@{ snapshotJson=$snapshot; confirmAndSendButton=$confirm; clickPoint=(Get-ClickPointFromNode $confirm) }
                $steps.Add([pscustomobject]@{ name='PreConfirmSnapshot'; snapshotJson=$snapshot; buttonPlan=$buttonPlan }) | Out-Null
                if ($errors.Count -eq 0) {
                    $steps.Add((Click-Point -Point $buttonPlan.clickPoint -Reason "ClickConfirmAndSend")) | Out-Null
                    Start-Sleep -Milliseconds 1500
                    $confirmSnapshot = New-SnapshotJson "OcoWorkflowConfirmation-$($item.Symbol -replace '[^A-Za-z0-9_.-]+','-')" "Order Confirmation"
                    $steps.Add([pscustomobject]@{ name='ConfirmationSnapshot'; snapshotJson=$confirmSnapshot }) | Out-Null
                }
            }
            'VerifyConfirmation' {
                $confirmSnapshot = New-SnapshotJson "OcoWorkflowVerifyConfirmation-$($item.Symbol -replace '[^A-Za-z0-9_.-]+','-')" "Order Confirmation"
                $planScript = Join-Path $scriptDir "New-TosOrderConfirmationSendPlan.ps1"
                $confirmationReplacingOrderId = Get-ExpectedConfirmationReplacingOrderId $item
                $regex = Get-ExpectedOrderDescriptionRegex $item
                $args = @("-SnapshotJson", $confirmSnapshot, "-ExpectedSymbol", [string]$item.Symbol, "-ExpectedReplacingOrderId", $confirmationReplacingOrderId, "-ExpectedThresholdText", $expectedConditionText, "-ExpectedOrderRegex", $regex)
                $step = Invoke-WorkflowStep -Name "VerifyConfirmation" -Script $planScript -Arguments $args
                $steps.Add([pscustomobject]@{ name='ConfirmationSnapshot'; snapshotJson=$confirmSnapshot }) | Out-Null
                $steps.Add($step) | Out-Null
                if ($step.exitCode -ne 0) { $errors.Add("VerifyConfirmation failed with exit code $($step.exitCode).") | Out-Null }
            }
            'RunToConfirmation' {
                $workflowScript = $MyInvocation.MyCommand.Path
                $baseArgs = @("-BatchPath", $BatchPath, "-Symbol", [string]$item.Symbol, "-Phase", [string]$item.Phase, "-OcoId", [string]$item.OcoId, "-ReplacingOrderId", [string]$item.ReplacingOrderId, "-WindowTitle", $WindowTitle)
                foreach ($childStage in @("OpenCancelReplace", "SetThreshold", "OpenConfirmation")) {
                    $childArgs = @($baseArgs + @("-Stage", $childStage, "-AllowInput"))
                    $childTimeout = if ($childStage -eq "SetThreshold") { 150 } else { 90 }
                    $child = Invoke-WorkflowStepWithTimeout -Name $childStage -Script $workflowScript -Arguments $childArgs -TimeoutSeconds $childTimeout
                    $steps.Add($child) | Out-Null
                    if ($child.timedOut -eq $true) { $errors.Add("$childStage timed out after $($child.timeoutSeconds) seconds. The workflow stopped before confirmation/send.") | Out-Null; break }
                    if ($child.exitCode -ne 0) { $errors.Add("$childStage failed with exit code $($child.exitCode).") | Out-Null; break }
                    Start-Sleep -Milliseconds 900
                }
                if ($errors.Count -eq 0) {
                    $verifyArgs = @($baseArgs + @("-Stage", "VerifyConfirmation"))
                    $verify = Invoke-WorkflowStep -Name "VerifyConfirmation" -Script $workflowScript -Arguments $verifyArgs
                    $steps.Add($verify) | Out-Null
                    if ($verify.exitCode -ne 0) { $errors.Add("VerifyConfirmation failed with exit code $($verify.exitCode).") | Out-Null }
                }
            }
            'RunToFinalSend' {
                $workflowScript = $MyInvocation.MyCommand.Path
                $baseArgs = @("-BatchPath", $BatchPath, "-Symbol", [string]$item.Symbol, "-Phase", [string]$item.Phase, "-OcoId", [string]$item.OcoId, "-ReplacingOrderId", [string]$item.ReplacingOrderId, "-WindowTitle", $WindowTitle)
                $runArgs = @($baseArgs + @("-Stage", "RunToConfirmation", "-AllowInput"))
                $run = Invoke-WorkflowStepWithTimeout -Name "RunToConfirmation" -Script $workflowScript -Arguments $runArgs -TimeoutSeconds 360
                $steps.Add($run) | Out-Null
                if ($run.timedOut -eq $true) { $errors.Add("RunToConfirmation timed out after $($run.timeoutSeconds) seconds. The workflow stopped before final send.") | Out-Null }
                if ($run.exitCode -ne 0) { $errors.Add("RunToConfirmation failed with exit code $($run.exitCode).") | Out-Null }
                if ($errors.Count -eq 0) {
                    $finalArgs = @($baseArgs + @("-Stage", "FinalSend", "-AllowInput", "-AllowFinalSend"))
                    $final = Invoke-WorkflowStep -Name "FinalSend" -Script $workflowScript -Arguments $finalArgs
                    $steps.Add($final) | Out-Null
                    if ($final.exitCode -ne 0) { $errors.Add("FinalSend failed with exit code $($final.exitCode).") | Out-Null }
                }
            }
            'FinalSend' {
                $confirmSnapshot = New-SnapshotJson "OcoWorkflowFinalSendPreflight-$($item.Symbol -replace '[^A-Za-z0-9_.-]+','-')" "Order Confirmation"
                $planScript = Join-Path $scriptDir "New-TosOrderConfirmationSendPlan.ps1"
                $confirmationReplacingOrderId = Get-ExpectedConfirmationReplacingOrderId $item
                $regex = Get-ExpectedOrderDescriptionRegex $item
                $planOut = Join-Path $diagnosticsDir ("tos-order-confirmation-send-preflight-{0}-{1}.json" -f ($item.Symbol -replace '[^A-Za-z0-9_.-]+','-'), (Get-Date -Format yyyyMMdd-HHmmss))
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planScript -SnapshotJson $confirmSnapshot -ExpectedSymbol ([string]$item.Symbol) -ExpectedReplacingOrderId $confirmationReplacingOrderId -ExpectedThresholdText $expectedConditionText -ExpectedOrderRegex $regex -OutFile $planOut | Out-Null
                $confirmationPlan = Get-Content -LiteralPath $planOut -Raw | ConvertFrom-Json
                $steps.Add([pscustomobject]@{ name='FinalSendPreflight'; snapshotJson=$confirmSnapshot; planJson=$planOut; allowedToFinalSend=$confirmationPlan.allowedToFinalSend }) | Out-Null
                if ($confirmationPlan.allowedToFinalSend -ne $true) { $errors.Add("Final send preflight failed: $($confirmationPlan.errors -join '; ')") | Out-Null }
                if ($errors.Count -eq 0) {
                    $steps.Add((Click-Point -Point $confirmationPlan.sendClickPoint -Reason "ClickFinalSend")) | Out-Null
                }
            }
        }
    }
} catch {
    $errors.Add($_.Exception.Message) | Out-Null
}

$stepArray = if ($null -ne $steps) { [object[]]$steps.ToArray() } else { [object[]]@() }
$errorArray = if ($null -ne $errors) { [string[]]$errors.ToArray() } else { [string[]]@() }
$result = [ordered]@{
    createdAt = (Get-Date).ToString('o')
    stage = $Stage
    allowInput = [bool]$AllowInput
    allowFinalSend = [bool]$AllowFinalSend
    batchPath = $BatchPath
    currentTosAccount = $batch.currentTosAccount
    requested = [ordered]@{ symbol=$Symbol; phase=$Phase; ocoId=$OcoId; replacingOrderId=$ReplacingOrderId }
    matchedCount = $items.Count
    selectedItem = $item
    expectedConditionText = $expectedConditionText
    confirmationSnapshot = $confirmSnapshot
    confirmationPlan = $confirmationPlan
    steps = @($stepArray)
    errors = @($errorArray)
    success = ($errors.Count -eq 0)
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 24
Write-Host "Wrote TOS OCO desktop workflow result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }



