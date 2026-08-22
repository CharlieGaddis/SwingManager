# TOS OCO Automation State

Last updated: 2026-08-15 19:05 ET

## Goal

Swing Manager is being built as an application, not a chat-memory workflow. The TOS automation layer must expose repeatable commands that can be dry-run, audited, and then promoted behind explicit save/submit switches.

## Proven Capabilities

- Java Access Bridge works against thinkorswim when the client pumps Windows messages after `Windows_run()`.
- The main TOS frame and the `Order Rules` dialog are readable through JAB.
- AHK can activate TOS and drive clicks/keys when JAB exposes insufficient control actions.
- From a known collapsed Monitor layout, prior testing opened a closing order and Order Rules using this coordinate sequence:
  - Top group: `841,359`
  - None group: `846,379`
  - Ticker row: `920,417`
  - Filled order row: `974,485`
  - Create Closing Order parent: `1140,502`
  - Top submenu item: `1260,503`
  - Gear/Order Rules opener: `1829,857`
- A staged order-entry row can be semantically verified through JAB, then the Order Rules cell can be clicked using row geometry.
- Right-clicking a staged order line and selecting `Create duplicate order` creates the second OCO row.
- Advanced Order can be changed to `OCO`.
- Existing OCO conditional rows can be updated through cancel/replace, opening `Order Rules`, editing the condition threshold, saving, and confirming the replacement.
- The verified USB replacement created active child `1007574646188` under OCO `1007453816390` with `USB MARK AT OR BELOW 63.19`.

## Critical Rule

Never enable `Submit at` for OCO condition updates. That checkbox creates a date/time gate and can block submission with a past timestamp. `tools\Set-TosSubmitCondition.ps1` now treats that control as `SubmitAtCheckbox`, verifies it is off, and unchecks it if necessary before touching the condition grid.

## Stop-Leg Model

For option/spread stop legs:

- Order type: `STOP`
- TIF: `GTC`
- `Stop linked to:` = `MARK`
- Stop offset/price = `0.00` when using the MARK-linked stop model
- `Stop type:` = `MARK`
- Lower condition grid carries the underlying trigger, e.g. `USB MARK <= 63.19`
- Top `Submit at:` remains off

## Durable Commands

### Existing condition-row writer

```powershell
powershell -Sta -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\Set-TosOrderCondition.ps1" -ConditionType Stop -Threshold 63.19 -LeaveOpen
```

This requires an already-open `Order Rules` dialog. It does not final-submit.

### Existing OCO update dry-run wrapper

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\Update-TosExistingOcoCondition.ps1" -Symbol USB -OcoId 1007453816390 -ConditionType Stop -ExpectedOldThreshold 63.19 -NewThreshold 63.19 -UseExistingTree -TreePath "D:\AI-Chat GPT\SwingManager\Analysis\tos-working-only-usb2.txt"
```

Verified on saved USB tree data. It matched exactly one active row and produced:

- `ExpectedNewConditionText = USB MARK AT OR BELOW 63.19`
- `MatchedStatus = WAIT COND`
- `MatchedQuantity = -8`
- `MatchedTicker = VERTICAL`
- `MatchedOrderType = STP`

The wrapper currently performs preflight/dry-run only unless live switches are supplied. Live switches intentionally stop until the cancel/replace and final confirmation stages are wired behind hard validation gates.

## Current Gap

The missing application piece is a single end-to-end live command:

`locate exact working OCO row -> cancel/replace -> open Order Rules -> update threshold -> verify Submit at off -> save -> confirm/send -> re-dump -> verify active replacement`

The pieces exist, but row-level cancel/replace and final confirm/send are not yet packaged as one guarded command.

## Next Implementation Steps

1. Extend `tools\Update-TosExistingOcoCondition.ps1` from dry-run into staged modes:
   - `-OpenCancelReplace`
   - `-ApplyOrderRules`
   - `-AllowSave`
   - `-AllowFinalSubmit`
2. Add exact visible-row context menu targeting for working OCO rows.
3. Refuse live action unless the preflight finds exactly one active row by symbol, OCO id, status, condition side, and old threshold.
4. In `Order Rules`, verify the header contains the expected symbol/order and does not contain `SUBMIT AT` before Save.
5. After Save, verify the staged replacement text contains the new threshold before Confirm/Send.
6. After final Send, dump TOS and require the old order to be canceled/replaced and the new order to be `WAIT COND`.

## Operator Handoff Rule

If TOS does not expose the exact row through JAB, stop and ask the operator to expose that row. Do not scroll blindly during a live update.

## Project Location Rule

No C-drive Swing Manager directory is authoritative. Do not restore or use one.
The sole Swing Manager application root is `D:\AI-Chat GPT\SwingManager`,
which contains the recovered screenshots, JAB dumps, workflow notes, and
current tools needed to continue.

## 2026-08-12 21:12 ET Live Dry-Run Results

No TOS clicks were performed.

Command wrapper: `tools\Update-TosExistingOcoCondition.ps1`

Passed live-screen dry runs:

1. USB OCO `1007453816390`
   - Status: `WAIT COND`
   - Quantity: `-8`
   - Order type: `STP`
   - Active condition: `USB MARK AT OR BELOW 63.19`
   - Tree: `Analysis\tos-oco-update-USB-20260812-211119.txt`
   - Plan: `Analysis\tos-oco-update-USB-20260812-211119-plan.csv`

2. USB OCO `1007453365774`
   - Status: `WAIT COND`
   - Quantity: `-8`
   - Order type: `STP`
   - Active condition: `USB MARK AT OR BELOW 63.19`
   - Tree: `Analysis\tos-oco-update-USB-20260812-211206.txt`
   - Plan: `Analysis\tos-oco-update-USB-20260812-211206-plan.csv`

Result: both U.S. Bank spread stop OCOs are visible and already show the expected `63.19` stop trigger.

## IRA Stock Stop Updates

The nightly OCO/update workflow must cover both accounts:

1. Living Trust option/spread OCOs
   - Requires TOS conditional order rules.
   - Hardest path: cancel/replace, edit condition grid, keep `Submit at` off, save, confirm/send, verify replacement.

2. IRA stock stops
   - Required and not optional.
   - Simpler path than option/spread OCO condition updates.
   - Must switch to the IRA account, locate stock stop orders, update stop levels from the latest JSON, save/confirm, and verify active replacement.
   - Account guard is mandatory so stock-stop updates do not run in the Living Trust account.

TODO: Add IRA stock-stop update queue and dashboard status alongside option OCO update queue. Do not mark nightly prep complete until both Living Trust option OCOs and IRA stock stops have been reconciled.

## JSON Source Direction

Near term: manual JSON upload/download is acceptable and safest for tomorrow.

Long term: Swing Manager should be able to pull the report automatically if the source website supports stable authentication and download access. Preferred order:

1. Official API or authenticated download endpoint.
2. Browser/session automation only if the website has no API.
3. Manual upload as fallback.

The dashboard should support both modes: `Upload JSON` now, and later `Fetch Latest Report` after credentials/session handling is built safely.

## New Position Risk-Management Orders

Every newly opened position must get protective/risk-management orders. This is separate from nightly updates to existing orders.

Required workflow after a new fill:

1. Detect new filled position from Schwab/TOS account state.
2. Classify account and instrument:
   - IRA stock position
   - Living Trust option/spread position
3. Pull the correct levels from the latest JSON/report:
   - T1 profit target
   - T2 profit target
   - stop loss
4. Build initial management orders:
   - T1 profit-taking order with its stop protection
   - T2 profit-taking order with its stop protection
   - Use the correct account and quantity split.
5. Verify the order structure in TOS/Schwab before marking the position protected.
6. Dashboard must clearly distinguish:
   - `Needs initial OCO/risk setup`
   - `Protected / OCO active`
   - `Needs update from latest JSON`
   - `Exception / manual review`

This requirement applies whenever a new investment/position is opened. Nightly maintenance updates existing protected positions; new-position setup creates the initial risk mitigation structure.

## 2026-08-14 Hybrid Automation Direction

Adopt the hybrid TOS driver model:

- Use Java Access Bridge for discovery, semantic locating, screen-state fingerprinting, and read-back verification.
- Use native Windows input for clicks, double-clicks, keyboard activation, text entry, and scrolling.
- Never cache a JAB child path after any TOS UI mutation. Rediscover after accordion expand/collapse, row selection, dialog open, save, or scroll.
- Promote only specific recipes, not a generic GUI agent.

New durable project structure:

- `TosAutomation/Discovery/`
- `TosAutomation/Locators/`
- `TosAutomation/Recipes/`
- `TosAutomation/Diagnostics/`
- `TosAutomation/Production/`

New read-only tools:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\New-TosAutomationSnapshot.ps1" -Label "OrderRulesOpen"

powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\Capture-TosElementUnderMouse.ps1"
```

Next vertical slice is still supervised and non-production: capture the staged replacement row, Order Rules gear/control, condition-row trigger field, Save button, and final confirmation dialog. After those controls are mapped, implement one transactional update recipe and require repeated successful cycles before live use.
## 2026-08-14 Hybrid Automation Implementation Progress

Implemented the first durable pieces of the revised TOS automation approach:

- Added `TosAutomation/` with `Discovery`, `Locators`, `Recipes`, `Diagnostics`, and `Production` folders.
- Added read-only screen snapshot command: `tools/New-TosAutomationSnapshot.ps1`.
- Added read-only element capture command: `tools/Capture-TosElementUnderMouse.ps1`.
- Added native input primitive with dry-run default: `tools/Invoke-TosNativeInput.ps1`.
- Added snapshot diff utility: `tools/Compare-TosAutomationSnapshots.ps1`.
- Added structured JSON conversion for saved JAB trees: `tools/Convert-TosJabTreeTextToJson.ps1`.
- Added locator scoring utility: `tools/Find-TosAutomationNode.ps1`.
- Added first locator definition: `TosAutomation/Locators/OrderRules.ConditionTriggerPrice.v1.json`.
- Added first recipe draft: `TosAutomation/Recipes/UpdateConditionTriggerPrice.v1.md`.

Verified:

## 2026-08-15 Desktop OCO Workflow Fixes

The TOS workflow now owns its starting surface instead of relying on operator tab state:

- Added `tools/Ensure-TosMonitorWorkingOrders.ps1`.
  - Selects `Monitor` using current JAB bounds with native-click fallback.
  - Verifies `Working Orders` is open.
- Added `tools/Ensure-TosOrderEntryMaintenanceSurface.ps1`.
  - Verifies `Order Entry and Saved Orders` is open.
  - Verifies `Order Entry` tab is selected.
  - Closes `Order and Strategy Book` when it is open.
- Updated `tools/Open-TosCancelReplaceFromBatch.ps1`.
  - Uses the actual JAB viewport ancestor for Working Orders row visibility.
  - Adds wheel support for self-scrolling offscreen rows.
  - Strengthens TOS foreground safety by verifying the window under the intended click point.
- Updated `tools/Invoke-TosOcoDesktopWorkflow.ps1`.
  - Runs the Monitor/Working Orders guard before cancel/replace.
  - Runs the Order Entry maintenance guard before threshold edits.
  - Captures confirmation dialogs through the `Order Confirmation` window title.
- Updated `tools/Set-TosActiveOrderEntryTriggerThreshold.ps1`.
  - Treats the post-save staged-row text as advisory when the Order Rules dialog itself verified and saved the new value; confirmation preview remains authoritative.

Live supervised proof:

- Account: Living Trust ending `9157`.
- Symbol: ASB.
- OCO: `1007531194984`.
- Active replacement order: `1007574646220`.
- Workflow completed: Monitor guard -> Working Orders row match -> cancel/replace -> Order Rules threshold edit -> confirmation verification -> final Send.
- Verified confirmation condition: `ASB MARK AT OR BELOW 31.41`.
- Post-send snapshot: `TosAutomation/Discovery/tos-PostFinalSend-ASB-20260815-190457-tree.txt`.
- Post-send proof row: `(Replacing #1007574646220) SELL -5 VERTICAL ASB 100 18 SEP 26 30/35 CALL STP MARK+.00 MARK GTC OCO #1007531194984 WHEN ASB MARK AT OR BELOW 31.41 [TO CLOSE/TO CLOSE]`.

- Main TOS window can be detected by HWND.
- Bounded JAB snapshots can be captured from the main TOS window.
- Text snapshots can be converted to structured JSON nodes.
- Snapshot wrapper now writes tree, JSON, metadata, and best-effort screenshot without failing if screenshot capture is unavailable.
- Native input helper defaults to dry-run and does not click unless `-AllowInput` is supplied.

Still needed before production OCO updates:

- Capture actual `Order Rules` dialog with conditions expanded.
- Capture the exact trigger-price cell under the mouse.
- Capture `Submit at` checkbox unchecked/checked states so the guard can verify it before saving.
- Capture Save/Cancel buttons and the staged replacement row after save.
- Build one vertical-slice production candidate only after the above captures are converted into locators and verified through supervised cycles.

## 2026-08-14 Order Rules Capture: CROX

Captured visible TOS `Order Rules` dialog by HWND `2757474`.

Artifacts:

- `TosAutomation/Discovery/tos-OrderRulesDialog-20260814-182130-tree.txt`
- `TosAutomation/Discovery/tos-OrderRulesDialog-20260814-182130-tree.json`
- `TosAutomation/Discovery/tos-OrderRulesDialog-20260814-182130-meta.json`
- `TosAutomation/Discovery/tos-OrderRulesDialog-20260814-182130.png`
- `TosAutomation/Diagnostics/order-rules-crox-20260814-182130-analysis.json`

Analyzer result:

- Screen inferred as `OrderRulesDialog`.
- `Submit at` checkbox present and unchecked.
- Submit-side condition table found at bounds `572,602,450,32`.
- Row symbol read as `CROX`.
- Method read as `MARK`.
- Operator read as `>=`.
- Threshold editor exists as table child path `0.0.1.0.0.0.0.0.1.1.0.0.12.0.2.0.4`, but TOS reports its bounds as `-1,-1,-1,-1`.
- Estimated threshold click point from table geometry: `941,618`.

Implication: production interaction should locate the submit condition table semantically, verify symbol/method/operator from descendants, then click the threshold by table-relative geometry unless a focused editor exposes real bounds after activation. Do not depend on cached child indexes after any UI change.

## 2026-08-14 Trigger Field Mouse Capture

Captured exact threshold/trigger field under mouse in the visible `Order Rules` window.

Artifacts:

- `TosAutomation/Discovery/tos-element-under-mouse-20260814-182518.json`
- `TosAutomation/Discovery/tos-element-under-mouse-20260814-182518.png`
- `TosAutomation/Discovery/tos-element-under-mouse-20260814-182518-crop.png`

Capture details:

- Window: `Order Rules`, HWND `2757474`.
- Mouse point: `943,606`.
- Hit role: `text`.
- Hit states: `enabled,focusable,visible,showing,focused,editable,single line`.
- Hit bounds: `925,605,70,9`.

Locator update:

- `TosAutomation/Locators/OrderRules.ConditionTriggerPrice.v1.json` now stores the table-relative threshold activation geometry.
- Use submit table bounds as the basis. Captured table bounds were `572,602,450,32`.
- The correct initial click point is approximately table X + `0.8244 * width`, table Y + `4`, then rediscover the focused editable text field.

## 2026-08-14 No-Save Threshold Edit Test

Implemented and tested the first executable vertical slice for the `Order Rules` threshold field.

Scripts added/updated:

- `tools/Invoke-TosOrderRulesThresholdEdit.ps1`
- `tools/Test-TosOrderRulesThresholdEditLoop.ps1`

Important result:

- The initial `System.Windows.Forms.SendKeys` approach failed safely. The threshold field was focused, but keyboard events did not reach TOS; clipboard verification read old external text.
- The native `SendInput` keyboard implementation also failed safely; clipboard verification retained the sentinel value.
- Replacing keyboard input with Win32 `keybd_event` chords plus sentinel clipboard verification worked.

Verified working path:

- Fresh `Order Rules` snapshot before every attempt.
- Verify `CROX / MARK / >=` and `Submit at` unchecked.
- Click learned threshold point `943,606`.
- Set clipboard to intended threshold.
- Native `Ctrl+A`, `Ctrl+V` into the field.
- Set clipboard to sentinel.
- Native `Ctrl+A`, `Ctrl+C` from the field.
- Require copied text to equal intended threshold.
- `Tab` out.
- Do not Save unless `-AllowSave` is explicitly supplied.

Test evidence:

- Single no-save edit test passed at `tos-threshold-edit-result-CROX-20260814-183834.json`.
- 3-cycle no-save loop passed: `tos-threshold-edit-loop-CROX-20260814-183949.json` with 3 successes, 0 failures, Save attempted false.
- Post-save code path exists behind `-AllowSave`, but it has not been run.

## 2026-08-14 Guarded Save Stage Passed

Ran the guarded `Order Rules` Save-stage test on CROX using the same threshold value `157.37`.

Result artifact:

- `TosAutomation/Diagnostics/tos-threshold-edit-result-CROX-20260814-184352.json`

Result:

- `allowInput`: true
- `allowSave`: true
- `verifiedTypedValue`: true
- `copiedValue`: `157.37`
- `postEditVerified`: true
- `saveAttempted`: true
- `saveClicked`: true
- `errors`: none
- No final order submit was attempted.

After-save verification:

- Main TOS snapshot: `TosAutomation/Discovery/tos-MainAfterOrderRulesSave-CROX-20260814-184422-tree.json`
- Staged-order verifier result: `TosAutomation/Diagnostics/tos-staged-order-crox-after-save-20260814-184422.json`
- Exactly one staged replacement row matched:
  - replacing order id: `1007531194058`
  - staged/order id: `1007557782022`
  - OCO id: `1007531194057`
  - symbol: `CROX`
  - threshold text: `WHEN CROX MARK AT OR ABOVE 157.37`
  - status: `WAIT COND`

Next guarded stage is final `Confirm and Send`, but it must remain a separate recipe with explicit `-AllowSubmit`. Do not run it under `-AllowSave`.

## 2026-08-14 Confirm And Send Plan Built But Not Executed

Built read-only final-submit plan script:

- `tools/New-TosConfirmAndSendPlan.ps1`

Validated against after-save CROX snapshot:

- Plan artifact: `TosAutomation/Diagnostics/tos-confirm-send-plan-CROX-20260814-184806.json`
- Matched exactly one staged CROX replacement row.
- Found visible `Confirm and Send` button.
- Computed button click point: `1602,814`.
- `allowedToSubmit`: true

Important boundary:

- The plan builder does not click anything.
- Final submit/replace must be a separate explicitly approved recipe using `-AllowSubmit`.
- After clicking `Confirm and Send`, TOS may show another confirmation dialog; that dialog must be captured and verified before any final send/replace action is automated.

## 2026-08-14 Order Confirmation Dialog Captured

User approved clicking `Confirm and Send` for CROX capture. The script verified the staged CROX row from a fresh main-window snapshot and clicked only the `Confirm and Send` button.

Artifacts:

- Pre-click snapshot: `TosAutomation/Discovery/tos-PreConfirmSend-CROX-20260814-185030-tree.json`
- Confirm-and-send plan: `TosAutomation/Diagnostics/tos-confirm-send-plan-CROX-20260814-185030.json`
- Click result: `TosAutomation/Diagnostics/tos-confirm-send-click-CROX-20260814-185030.csv`
- Order confirmation snapshot: `TosAutomation/Discovery/tos-OrderConfirmation-CROX-20260814-185145-tree.json`
- Final Send plan: `TosAutomation/Diagnostics/tos-order-confirmation-send-plan-CROX-20260814-185145.json`

Order Confirmation Dialog verification:

- Dialog title: `Order Confirmation Dialog`
- Symbol label: `CROX`
- Order description: `(Replacing #1007557782022) SELL -4 VERTICAL CROX 100 18 SEP 26 140/150 CALL @MARK+.00 LMT GTC [TO CLOSE/TO CLOSE]`
- Condition: `CROX MARK AT OR ABOVE 157.37`
- `Edit` button found.
- Final `Send` button found at click point `1600,798`.
- `allowedToFinalSend`: true in the plan.

Boundary:

- Final `Send` was not clicked.
- Final `Send` must require separate explicit approval and a dedicated `-AllowFinalSend` execution path.

## 2026-08-14 CROX Final Send Executed And Verified

User explicitly approved final Send for CROX. Before clicking, the automation took a fresh confirmation-dialog snapshot and rebuilt the final-send plan from current bounds.

Fresh final confirmation artifacts:

- `TosAutomation/Discovery/tos-OrderConfirmationFinal-CROX-20260814-185412-tree.json`
- `TosAutomation/Diagnostics/tos-order-confirmation-send-plan-CROX-20260814-185412.json`
- `TosAutomation/Diagnostics/tos-final-send-click-CROX-20260814-185412.csv`

Final Send verification:

- After-send main snapshot: `TosAutomation/Discovery/tos-AfterFinalSend-CROX-20260814-185446-tree.json`
- New row verification: `TosAutomation/Diagnostics/tos-final-send-new-crox-row-20260814-185446.json`
- Old row verification: `TosAutomation/Diagnostics/tos-final-send-old-crox-row-20260814-185446.json`

Observed result after final Send:

- New order id: `1007606080881`
- New row text: `(Replacing #1007557782022) SELL -4 VERTICAL CROX 100 18 SEP 26 140/150 CALL @MARK+.00 LMT GTC OCO #1007531194057 WHEN CROX MARK AT OR ABOVE 157.37 [TO CLOSE/TO CLOSE]`
- New row status: `WAIT COND`
- Old staged order id: `1007557782022`
- Old row text: `(Replacing #1007531194058) SELL -4 VERTICAL CROX 100 18 SEP 26 140/150 CALL @MARK+.00 LMT GTC OCO #1007531194057 WHEN CROX MARK AT OR ABOVE 157.37 [TO CLOSE/TO CLOSE]`
- Old row status: `CANCELED`

Dynamic locator note:

- Final Send was not based on stale coordinates. It used a fresh confirmation-dialog snapshot, verified symbol/order/condition text, read current `Send` button bounds, and clicked the current button center.

## 2026-08-14 Multi-OCO Batch Planning Added

Added `tools/New-TosOcoUpdateBatchPlan.ps1` and integrated it into `Invoke-SwingNightlyReconciliation.ps1`.

Rule now memorialized in code: one visible TOS OCO/order row creates one desktop work item. Do not dedupe by ticker. A ticker can have multiple live protection rows because T1 and T2 commonly each carry their own stop, and one side may already be filled or stopped.

USB verification from latest available TOS snapshot:

- Desktop batch: `Analysis/tos-oco-desktop-update-batch-20260814-190748.json`
- USB stop row 1: OCO `1007453365774`, replacing `1007453365777`, current order `1007574646217`, `USB MARK AT OR BELOW 63.19`, expected `63.51`, unique snapshot match.
- USB stop row 2: OCO `1007453816390`, replacing `1007557782004`, current order `1007574646188`, `USB MARK AT OR BELOW 63.19`, expected `63.51`, unique snapshot match.
- USB target review still shows expected T1 `65.52` and T2 `66.39` not visible as active close rows in the current TOS visible-order snapshot, so they remain protection-review items.

Dashboard status now exposes the latest desktop batch path plus ready/update/missing counts. Restart the Swing Manager server after this change so `pending_manager_server.py` reloads.

## 2026-08-14 Current TOS Account Guard Added

User confirmed the current account appears in the top row of the main TOS window. The latest snapshot contains the visible header label `ACCOUNT_REDACTEDSCHW (Living Trust)`.

`tools/New-TosOcoUpdateBatchPlan.ps1` now detects the current TOS account from the visible main-header account label when a snapshot is provided. It records:

- `currentTosAccount.Number`
- `currentTosAccount.Alias`
- `currentTosAccount.Label`
- per-item `CurrentTosAccountNumber`, `CurrentTosAccountAlias`, `CurrentTosAccountLabel`, `AccountContextSource`, and `AccountVerified`

Latest regenerated batch:

- `Analysis/tos-oco-desktop-update-batch-20260814-191404.json`
- Current TOS account: `ACCOUNT_REDACTED`, `Living Trust`
- Ready rows verified under this account context: USB OCO `1007453365774`, ASB OCO `1007531194984`, USB OCO `1007453816390`.

Operational rule: before desktop OCO automation modifies IRA stock orders, switch TOS to the IRA account (`ACCOUNT_REDACTEDSCHW`) and capture a fresh main-window snapshot. The batch planner must show `CurrentTosAccountAlias = IRA` / `AccountVerified = True` before IRA-specific desktop updates proceed.


## 2026-08-14 TOS Privacy Redaction

Implemented `tools\TosPrivacyRedactor.psm1` and wired it into TOS diagnostic capture paths.

Current behavior:

- `Dump-TosJabTree.ps1` sanitizes TOS window titles plus JAB node names/descriptions before writing tree snapshots.
- `Convert-TosJabTreeTextToJson.ps1` sanitizes names, descriptions, raw lines, and JSON output.
- `New-TosAutomationSnapshot.ps1` captures screenshots to memory, finds the TOS account selector from the JAB tree, applies a solid opaque mask, and only writes the redacted PNG.
- `Capture-TosElementUnderMouse.ps1` redacts the full screenshot before saving the screenshot or crop and sanitizes its JSON metadata.
- `New-TosOcoUpdateBatchPlan.ps1` accepts sanitized TOS account labels and records `ACCOUNT_REDACTED` plus the account ending.
- Schwab/TOS generated diagnostics now persist `ACCOUNT_REDACTED` with account endings where useful instead of full account numbers.
- `Repair-TosPrivacyArtifacts.ps1` sanitizes existing generated text artifacts and redacts stored TOS PNGs from paired JAB tree bounds.

Verification performed on 2026-08-14 19:39 ET:

- Fresh privacy snapshot found one dynamic JAB account-label rectangle and masked it with a solid black block.
- Pixel checks inside the masked rectangle returned black pixels.
- Fresh nightly generation completed after privacy changes.
- Artifact scan of `Analysis`, `TosAutomation`, `Wiki`, and `tools\Analysis` found no full known account values and no eight-digit `SCHW` account labels.

Still to complete for full acceptance matrix:

- Repeat screenshot/JAB capture checks with TOS maximized, windowed, moved between monitors, alternate DPI/scaling, account dropdown open, and account dropdown closed.

## 2026-08-15 Desktop OCO Batch Runner

Added `tools\Invoke-TosOcoDesktopBatch.ps1` as the durable bridge between the nightly OCO batch JSON and the Order Rules editor.

Current behavior:

- Loads the latest `Analysis\tos-oco-desktop-update-batch-*.json` by default.
- Filters by symbol, phase, OCO id, and replacing order id.
- Refuses to proceed when more than one ready row matches.
- Requires `ReadyForDesktopAutomation = true` and `AccountVerified = true`.
- Emits the exact next operator step and apply command for one selected row.
- `-Mode ApplyOpenOrderRules -AllowInput` edits an already-open TOS Order Rules threshold through the existing guarded threshold editor.
- `-AllowSave` is still separate and requires `-AllowInput`; final confirm/send is not wired into the dashboard.

Dashboard progress:

- `/api/oco` now includes desktop batch summary and ready items.
- `/api/oco/desktop-batch/plan` returns a per-row plan from the same PowerShell runner.
- The dashboard OCO Review section now shows `Desktop OCO Updates` with a `Plan` button for each ready row.

Verified:

- Runner rejects ambiguous unfiltered batches.
- Runner selected exact USB and ASB stop rows from the latest batch.
- Dashboard POST route returned a valid plan for ASB.
- Dashboard server and JavaScript syntax checks passed with bundled runtimes.
- Account-number scan across `Data`, `Analysis`, `TosAutomation`, `Wiki`, `tools\Analysis`, and `tools\README.md` is clean.
- 152 JSON artifacts under `Data`, `Analysis`, and `TosAutomation` parsed successfully after privacy repairs.

Next implementation gap:

Package the TOS row-level cancel/replace opener so the app can move from a selected ready row to the correct Order Rules dialog without operator right-click/menu assistance. Keep final submit behind a separate verified command.

## 2026-08-15 Desktop Workflow Packaging

Implemented durable one-shot workflow command: `tools\Invoke-TosOcoDesktopWorkflow.ps1`.

Current guarded sequence:

1. Locate exact ready desktop batch row by `Symbol`, `Phase`, `OcoId`, and `ReplacingOrderId`.
2. In TOS Working Orders, right-click the exact row and choose `Cancel/replace order`.
3. Verify maintenance is in `Order Entry and Saved Orders` with the `Order Entry` tab selected.
4. Refuse if `Order and Strategy Book` is open.
5. Verify active row context: symbol, vertical/sell/GTC/mark, selected `<=` or `>=`, exact OCO/replacing order label.
6. Set the active trigger threshold through JAB.
7. Click `Confirm and Send` only in `RunToConfirmation`/`RunToFinalSend` stages.
8. Verify the TOS `Order Confirmation Dialog` before final send.
9. Final `Send` requires `-AllowFinalSend`.

Known TOS limitation: the active trigger edit control accepts `setTextContents` and reports success, but does not expose its current text through JAB before confirmation. Therefore confirmation-preview verification is the required read-back gate.

### Fresh snapshot guard

`Invoke-TosOcoDesktopWorkflow.ps1`, `Open-TosCancelReplaceFromBatch.ps1`, and `Set-TosActiveOrderEntryTriggerThreshold.ps1` now require a newly-created TOS snapshot for each live stage. If TOS is restarting or no current main window exists, the scripts stop instead of reusing an older same-label snapshot.

Dashboard endpoint added:

```text
POST /api/oco/desktop-workflow
```

Supported stages: `Plan`, `RunToConfirmation`, and `RunToFinalSend` plus the individual debug stages. `RunToFinalSend` requires the final-send flag and remains the live replacement boundary.

## 2026-08-15 TOS build 1993 retry notes

Retested after Thinkorswim maintenance. The stale-snapshot guard worked and fresh snapshots were produced from `Main@thinkorswim [build 1993]`.

What now works:
- USB OCO worklist matching resolves the exact stop row for `Replacing #1007453365777` / `OCO #1007453365774` / `USB`.
- Account labels in persisted diagnostics remain sanitized as `ACCOUNT_REDACTED`.
- `Open-TosCancelReplaceFromBatch.ps1` now has a popup-first capture path using `Capture-TosElementUnderMouse.ps1` so, when the TOS context menu is actually open, it can click the real `Cancel/replace order` menu item by JAB bounds.
- Working Orders coordinate planning was corrected for build 1993 grouped rows. The measured USB target uses table geometry instead of the old monitor-surface approximation: `x = table.x + 220`, `y = table.y + 24 + rowIndex * 15`. This put the pointer on `RE #1007453365777` instead of the wrong visible row.

Current blocker:
- TOS build 1993 did not open the row action popup from programmatic right-click on the `RE` child row, right-click on the parent `VERTICAL` row, Windows context-menu key, Shift+F10, or direct clicks on the far-right row icon during this retry.
- Latest probe confirmed the corrected coordinate hits `RE #1007453365777`; failure is specifically the menu-opening gesture, not row identification.

Next implementation step:
- Add a dedicated row-action opener recipe that locates the parent order row, the visible action/icon cell, and verifies popup creation via `Capture-TosElementUnderMouse.ps1` before clicking `Cancel/replace order`.
- If TOS requires a human-only gesture sequence, use Capture Mode to record the successful action-menu opening immediately after Charlie performs it, then encode that as a tested recipe rather than leaving it in chat notes.

## 2026-08-15 USB Live Stop Update Result

Verified live USB stop replacements submitted in TOS:

- `OCO #1007453365774`: old `WAIT COND` stop at `63.19` was canceled/replaced; new active `WAIT COND` stop is `(Replacing #1007606081198)` with `USB MARK AT OR BELOW 63.51`.
- `OCO #1007453816390`: old `WAIT COND` stop at `63.19` was canceled/replaced; new active `WAIT COND` stop is `(Replacing #1007574646188)` with `USB MARK AT OR BELOW 63.51`.
- Existing USB target sides remained unchanged: `65.52` for `OCO #1007453365774` and `66.39` for `OCO #1007453816390`.

Working recipe details:

1. Start from `Monitor > Activity and Positions > Today's Trade Activity`, sorted/grouped by symbol.
2. Right-click the exact stop replacement row, not the target row and not the option-chain row.
3. Choose `Cancel/replace order`.
4. TOS may switch to the `Trade` tab after cancel/replace; this is acceptable only if `Order Entry and Saved Orders` is open and the active staged order is visible in `Order Entry`.
5. Open the Order Rules gear from the far-right gear cell of the active staged row. In build 1993, the reliable click is near `rowTable.x + rowTable.width - 24`, vertically near the top leg of the staged two-leg order, not the row midpoint.
6. Edit the condition threshold, verify typed value, ensure `Submit at` is unchecked, then Save.
7. Click `Confirm and Send`.
8. Final `Send` is allowed only after `Order Confirmation Dialog` verifies the staged replacement id, symbol, order description, and condition text.
9. After Send, extract visible working orders and confirm old rows are `CANCELED` and new rows are active at the expected condition.

Code changes recorded from the run:

- `tools\Invoke-TosNativeInput.ps1` now supports `RightClick` so row context menus do not require one-off inline native input code.
- `tools\Open-TosOrderRulesForFirstOrderEntryRow.ps1` now defaults to dynamic far-right gear targeting instead of the stale `+754` offset and row midpoint.
- `tools\New-TosOcoUpdateBatchPlan.ps1` and the dashboard now refuse `CANCELED` / `FILLED` rows as executable desktop work.
- The dashboard exposes `Run Next Preview` and `Run Next Final Send` so the operator can drive the next verified ready OCO item without manually selecting the row. The final-send path refreshes TOS and rebuilds the batch after a successful send.

## 2026-08-16 USB Live Stop Update / Row Focus Fix

Verified the remaining Living Trust USB stop replacement:

- `OCO #1007453365774`: old `WAIT COND` stop at `63.51` was canceled/replaced; new active replacement `1007607036746` is `USB MARK AT OR BELOW 63.59`.
- `OCO #1007453816390`: had already been replaced earlier in the session; post-reconcile Living Trust desktop batch reported `desktopOcoBatchReadyCount = 0`.

Critical automation lesson:

- Opening Order Rules from the staged two-leg order requires a row focus click first, then the far-right rules gear/cell click.
- A direct gear click can appear to land but not open the dialog.
- `tools\Open-TosOrderRulesForFirstOrderEntryRow.ps1` now activates TOS, clicks the staged row focus point, then clicks `rowTable.x + rowTable.width - 17` near the top leg.
- The separate `Invoke-TosOrderRulesThresholdEdit.ps1` verifier remains the safety gate for symbol, method, operator, typed threshold, and unchecked `Submit at`.

IRA check from the same run:

- TOS account switch verified IRA/Rollover IRA ending `5682`.
- Monitor > Working Orders showed `15 orders`.
- Visible IRA stock OCOs for `CGON` and `LLY` already matched JSON levels: `CGON 68.35 / 79.69 / 83.11`, `LLY 1112.71 / 1287.61 / 1336.16`.
- IRA desktop batch reported `desktopOcoBatchReadyCount = 0`; no existing IRA orders required a sendable update from the visible worklist.

## 2026-08-15 Account-Scoped Batch Preparation

Implemented account-aware preparation so one uploaded JSON can be used for both accounts without mixing expected levels:

- `tools\New-TosOcoUpdateBatchPlan.ps1` accepts `-TargetAccount` and writes `TargetAccountAlias` / `TargetAccountEnding` on each item.
- The planner normalizes TOS `Rollover IRA` labels to Swing Manager `IRA`.
- `ReadyForDesktopAutomation` now requires the target account to match the current TOS account.
- `tools\Switch-TosAccount.ps1` detects the top TOS account header, switches to `IRA` or `Living Trust` only when needed, and verifies the final header state.
- `POST /api/oco/prepare-account` switches/verifies TOS, captures a redacted snapshot, extracts visible working orders, and rebuilds an account-scoped desktop batch from the uploaded JSON.
- Dashboard buttons were added for `Prepare Living Trust` and `Prepare IRA`.

Smoke tests:

- Living Trust read-only switch detection succeeded with account ending `9157`.
- Living Trust prepare-account API succeeded and built `tos-oco-desktop-update-batch-20260815-172202.json`.
- Account gating smoke test showed Living Trust ready work while TOS was on Living Trust, and IRA target work correctly blocked with `readyCount = 0` while TOS remained on Living Trust.
