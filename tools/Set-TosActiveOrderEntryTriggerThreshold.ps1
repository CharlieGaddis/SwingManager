param(
    [string]$BatchPath = "",
    [string]$Symbol = "",
    [ValidateSet("", "Stop", "T1", "T2")]
    [string]$Phase = "",
    [string]$OcoId = "",
    [string]$ReplacingOrderId = "",
    [string]$WindowTitle = "Main@thinkorswim",
    [string]$SnapshotJson = "",
    [switch]$AllowInput,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
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
    $OutFile = Join-Path $diagnosticsDir "tos-active-order-entry-threshold-$safeSymbol-$stamp.json"
}

function ConvertTo-JabSetterPath([string]$TreePath) {
    $parts = @($TreePath -split '[./]' | Where-Object { $_ -ne '' })
    if ($parts.Count -gt 0 -and $parts[0] -eq '0') { $parts = @($parts | Select-Object -Skip 1) }
    return ($parts -join '/')
}

function Get-PathParent([string]$Path) {
    $parts = @($Path -split '[./]' | Where-Object { $_ -ne '' })
    if ($parts.Count -le 1) { return "" }
    return (($parts | Select-Object -First ($parts.Count - 1)) -join '.')
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

function Get-ExpectedConfirmationReplacingOrderId($Item) {
    $current = ([string]$Item.CurrentOrderId).Trim()
    if (-not [string]::IsNullOrWhiteSpace($current)) { return $current }
    return ([string]$Item.ReplacingOrderId).Trim()
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


$batch = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json
$items = @(Find-SelectedBatchItem $batch)
$errors = New-Object System.Collections.Generic.List[string]
if ($items.Count -eq 0) { $errors.Add("No verified ready desktop OCO update item matched the requested filters.") | Out-Null }
if ($items.Count -gt 1) { $errors.Add("More than one ready item matched. Add Symbol, Phase, OcoId, or ReplacingOrderId.") | Out-Null }
if (-not $AllowInput) { $errors.Add("Setting the active TOS threshold requires -AllowInput.") | Out-Null }
$item = $items | Select-Object -First 1

if ($errors.Count -eq 0 -and [string]::IsNullOrWhiteSpace($SnapshotJson)) {
    $safeSymbol = $item.Symbol -replace '[^A-Za-z0-9_.-]+', '-'
    $SnapshotJson = Get-LatestSnapshotJson "ActiveOrderEntryPreSet-$safeSymbol"
}
if ($errors.Count -eq 0 -and -not (Test-Path -LiteralPath $SnapshotJson)) { $errors.Add("SnapshotJson not found: $SnapshotJson") | Out-Null }

$surface = $null
$thresholdNode = $null
$setterPath = ""
$setTextCsv = ""
$setTextResult = $null
$openOrderRulesCsv = ""
$openOrderRulesResult = $null
$openOrderRulesWarning = ""
$orderRulesEditJson = ""
$orderRulesEditResult = $null
$postSaveWarning = ""
$postSaveSnapshotJson = ""
$postSaveStagedRow = $null

if ($errors.Count -eq 0) {
    $snapshot = Get-Content -LiteralPath $SnapshotJson -Raw | ConvertFrom-Json
    $nodes = @($snapshot.nodes)

    $entryAccordion = @($nodes | Where-Object { $_.role -eq 'toggle button' -and $_.name -eq 'Order Entry and Saved Orders' -and $_.states -match 'checked' -and $_.states -match 'showing' })
    $strategyBook = @($nodes | Where-Object { $_.role -eq 'toggle button' -and $_.name -eq 'Order and Strategy Book' -and $_.states -match 'checked' })
    $entryTabs = @($nodes | Where-Object { $_.role -eq 'page tab' -and $_.name -eq 'Order Entry' -and $_.states -match 'selected' -and $_.states -match 'showing' })

    if ($entryAccordion.Count -ne 1) { $errors.Add("Expected exactly one open Order Entry and Saved Orders accordion, found $($entryAccordion.Count).") | Out-Null }
    if ($strategyBook.Count -gt 0) { $errors.Add("Order and Strategy Book is open; close it before maintenance automation.") | Out-Null }
    if ($entryTabs.Count -ne 1) { $errors.Add("Expected selected Order Entry tab in Order Entry and Saved Orders, found $($entryTabs.Count).") | Out-Null }

    if ($errors.Count -eq 0) {
        $tab = $entryTabs[0]
        $tabPrefix = [string]$tab.path
        $activeNodes = @($nodes | Where-Object { ([string]$_.path) -like "$tabPrefix*" })
        $symbolNodes = @($activeNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim().ToUpperInvariant() -eq ([string]$item.Symbol).Trim().ToUpperInvariant() })
        $markNodes = @($activeNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim() -eq 'MARK' })
        $verticalNodes = @($activeNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim() -eq 'VERTICAL' })
        $sellNodes = @($activeNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim() -eq 'SELL' })
        $gtcNodes = @($activeNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim() -eq 'GTC' })
        $triggerLabels = @($activeNodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name).Trim() -eq 'Trigger At:' })
        if ($symbolNodes.Count -lt 1) { $errors.Add("Active Order Entry row does not show symbol $($item.Symbol).") | Out-Null }
        if ($markNodes.Count -lt 1) { $errors.Add("Active Order Entry row does not show MARK method.") | Out-Null }
        if ($verticalNodes.Count -lt 1) { $errors.Add("Active Order Entry row does not show VERTICAL spread type.") | Out-Null }
        if ($sellNodes.Count -lt 1) { $errors.Add("Active Order Entry row does not show SELL side.") | Out-Null }
        if ($gtcNodes.Count -lt 1) { $errors.Add("Active Order Entry row does not show GTC time-in-force.") | Out-Null }
        if ($triggerLabels.Count -ne 1) { $errors.Add("Expected exactly one active Trigger At label, found $($triggerLabels.Count).") | Out-Null }

        $workingOrderRegex = "Replacing #$([regex]::Escape([string]$item.ReplacingOrderId)).*\b$([regex]::Escape([string]$item.Symbol))\b.*OCO #$([regex]::Escape([string]$item.OcoId)).*$([regex]::Escape([string]$item.CurrentThreshold))"
        $workingOrderMatches = @($nodes | Where-Object { $_.role -eq 'label' -and ([string]$_.name) -match $workingOrderRegex })
        if ($workingOrderMatches.Count -ne 1) { $errors.Add("Expected one matching staged/working order label for Replacing #$($item.ReplacingOrderId) OCO #$($item.OcoId), found $($workingOrderMatches.Count).") | Out-Null }

        if ($errors.Count -eq 0) {
            $surface = [ordered]@{
                snapshotJson = $SnapshotJson
                orderEntryAccordionPath = $entryAccordion[0].path
                orderEntryTabPath = $tab.path
                matchedWorkingOrder = $workingOrderMatches[0].name
                symbolMatches = $symbolNodes.Count
                markMatches = $markNodes.Count
                verticalMatches = $verticalNodes.Count
                sellMatches = $sellNodes.Count
                gtcMatches = $gtcNodes.Count
                workingOrderStopConfirmed = ([string]$workingOrderMatches[0].name -match ' STP ')
            }
        }
    }
}

if ($errors.Count -eq 0) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeSymbol = $item.Symbol -replace '[^A-Za-z0-9_.-]+', '-'

    $openRulesScript = Join-Path $scriptDir "Open-TosOrderRulesForFirstOrderEntryRow.ps1"
    $openOrderRulesCsv = Join-Path $diagnosticsDir "tos-open-active-order-rules-$safeSymbol-$stamp.csv"
    $openArgs = @(
        "-WindowTitle", $WindowTitle,
        "-ExpectedSymbol", [string]$item.Symbol,
        "-ExpectedSide", [string]$item.Side,
        "-ExpectedQuantity", " ",
        "-OutFile", $openOrderRulesCsv
    )
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $openRulesScript @openArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { $errors.Add("Open Order Rules from staged replacement ticket failed with exit code $LASTEXITCODE.") | Out-Null }
    if (-not (Test-Path -LiteralPath $openOrderRulesCsv)) { $errors.Add("Open Order Rules result CSV was not produced: $openOrderRulesCsv") | Out-Null }
    else {
        $openOrderRulesResult = Import-Csv -LiteralPath $openOrderRulesCsv | Select-Object -First 1
        if ([string]$openOrderRulesResult.OrderRulesOpenAfter -ne 'True') {
            $openOrderRulesWarning = "Order Rules open detector returned false after the gear click; continuing to the dialog-specific edit verifier."
        }
    }

    if ($errors.Count -eq 0) {
        $side = ([string]$item.CurrentConditionSide).Trim().ToUpperInvariant()
        $operator = if ($side -eq 'BELOW') { '<=' } elseif ($side -eq 'ABOVE') { '>=' } else { '' }
        if ([string]::IsNullOrWhiteSpace($operator)) { $errors.Add("Unsupported condition side '$($item.CurrentConditionSide)'.") | Out-Null }
        else {
            $editScript = Join-Path $scriptDir "Invoke-TosOrderRulesThresholdEdit.ps1"
            $orderRulesEditJson = Join-Path $diagnosticsDir "tos-active-order-rules-edit-$safeSymbol-$stamp.json"
            $editArgs = @(
                "-ExpectedSymbol", [string]$item.Symbol,
                "-ExpectedMethod", "MARK",
                "-ExpectedOperator", $operator,
                "-NewThreshold", [string]$item.ExpectedThreshold,
                "-OutFile", $orderRulesEditJson
            )
            if ($AllowInput) {
                $editArgs += "-AllowInput"
                $editArgs += "-AllowSave"
            }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $editScript @editArgs | Out-Null
            if ($LASTEXITCODE -ne 0) { $errors.Add("Order Rules threshold edit failed with exit code $LASTEXITCODE.") | Out-Null }
            if (-not (Test-Path -LiteralPath $orderRulesEditJson)) { $errors.Add("Order Rules edit result JSON was not produced: $orderRulesEditJson") | Out-Null }
            else {
                $orderRulesEditResult = Get-Content -LiteralPath $orderRulesEditJson -Raw | ConvertFrom-Json
                foreach ($err in @($orderRulesEditResult.errors)) {
                    if (-not [string]::IsNullOrWhiteSpace($err)) { $errors.Add("Order Rules edit: $err") | Out-Null }
                }
                if ($AllowInput -and $orderRulesEditResult.saveClicked -ne $true) {
                    $errors.Add("Order Rules edit did not click Save, so the staged replacement ticket was not updated.") | Out-Null
                }
            }
        }
    }

    if ($errors.Count -eq 0 -and $AllowInput) {
        Start-Sleep -Milliseconds 900
        $postSaveSnapshotJson = Get-LatestSnapshotJson "ActiveOrderEntryPostSave-$safeSymbol"
        $findScript = Join-Path $scriptDir "Find-TosStagedOrderInSnapshot.ps1"
        $postSaveReplacingOrderId = Get-ExpectedConfirmationReplacingOrderId $item
        $findJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $findScript -SnapshotJson $postSaveSnapshotJson -Symbol ([string]$item.Symbol) -ReplacingOrderId $postSaveReplacingOrderId -OcoId ([string]$item.OcoId) -Threshold ([string]$item.ExpectedThreshold)
        if ($LASTEXITCODE -ne 0) { $errors.Add("Post-save staged row verification failed with exit code $LASTEXITCODE.") | Out-Null }
        else {
            $postSaveStagedRow = $findJson | ConvertFrom-Json
            if ($postSaveStagedRow.uniqueMatch -ne $true) {
                if ($orderRulesEditResult -and $orderRulesEditResult.postEditVerified -eq $true -and $orderRulesEditResult.saveClicked -eq $true) {
                    $postSaveWarning = "Post-save staged row did not expose expected threshold $($item.ExpectedThreshold); continuing because Order Rules verified and saved. Confirmation preview remains authoritative."
                } else {
                    $errors.Add("Post-save staged replacement row does not show expected threshold $($item.ExpectedThreshold); matched $($postSaveStagedRow.matchCount).") | Out-Null
                }
            }
        }
    }
}

$result = [ordered]@{
    createdAt = (Get-Date).ToString('o')
    allowInput = [bool]$AllowInput
    batchPath = $BatchPath
    requested = [ordered]@{ symbol = $Symbol; phase = $Phase; ocoId = $OcoId; replacingOrderId = $ReplacingOrderId }
    matchedCount = $items.Count
    selectedItem = $item
    surface = $surface
    setTextCsv = $setTextCsv
    setTextResult = $setTextResult
    openOrderRulesCsv = $openOrderRulesCsv
    openOrderRulesResult = $openOrderRulesResult
    openOrderRulesWarning = $openOrderRulesWarning
    orderRulesEditJson = $orderRulesEditJson
    orderRulesEditResult = $orderRulesEditResult
    postSaveSnapshotJson = $postSaveSnapshotJson
    postSaveStagedRow = $postSaveStagedRow
    postSaveWarning = $postSaveWarning
    errors = @($errors)
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $OutFile -Encoding UTF8
$result | ConvertTo-Json -Depth 18
Write-Host "Wrote active Order Entry threshold result to $OutFile"
if ($errors.Count -gt 0) { exit 2 }



