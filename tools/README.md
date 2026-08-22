# Swing Manager Tools

Last updated: 2026-08-16

## Safety Levels

- Read-only: inspects files, API, or TOS state without UI clicks.
- Dry-run: builds a plan and refuses live UI changes.
- UI-open: may click/open TOS windows but should not save/submit.
- Save-capable: can save an order dialog after validation.
- Submit-capable: can submit/cancel/replace live orders. Use only after explicit approval and verification.

Swing Manager production rule: do not turn off pending-entry live submission or downgrade it to paper unless Charlie explicitly requests that. Swing Manager is the approved production path for entering triggered swing trades without consuming buying power early through broker-side conditional entry orders. TradingDashboard's separate Schwab order-capability flag is not a Swing Manager kill switch; the Swing Manager submit helper uses shared Schwab auth/account lookup plus direct Schwab API submission.

## Current Tools

| Tool | Level | Purpose |
|---|---|---|
| `Dump-TosJabTree.ps1` | Read-only | Dumps Java Access Bridge tree for TOS windows. |
| `New-TosAutomationSnapshot.ps1` | Read-only | Captures a full TOS screen-state snapshot: JAB tree, screenshot, and inferred state metadata. |
| `Capture-TosElementUnderMouse.ps1` | Read-only | Captures the JAB node under the mouse, nearby children, full screenshot, and crop for locator training. |
| `Compare-TosAutomationSnapshots.ps1` | Read-only | Compares two saved TOS tree snapshots and reports added/removed unique lines. |
| `Convert-TosJabTreeTextToJson.ps1` | Read-only | Converts text JAB tree captures into flat JSON nodes for locator scoring/tests. |
| `Find-TosAutomationNode.ps1` | Read-only | Scores nodes from a saved snapshot against a semantic locator definition. |
| `Get-TosJavaWindows.ps1` | Read-only | Lists Java/TOS windows and context status. |
| `Get-TosJabControlInventory.ps1` | Read-only | Produces control inventory for an open TOS/JAB window. |
| `Find-TosJabTables.ps1` | Read-only | Finds visible JAB tables matching symbols/names. |
| `Update-TosExistingOcoCondition.ps1` | Dry-run | Matches exactly one visible active OCO row and writes an update plan. Live stages are intentionally not enabled yet. |
| `Open-TosOrderRulesForFirstOrderEntryRow.ps1` | UI-open | Verifies a staged order-entry row and clicks the computed Order Rules cell. |
| `Set-TosOrderCondition.ps1` | UI-open / optional save flag | Wrapper to set Target or Stop condition in an already-open Order Rules dialog. |
| `Set-TosSubmitCondition.ps1` | UI-open / save-capable with `-AllowSave` | Low-level condition editor. It guards `Submit at` so it stays off. |
| `New-TosOcoConditionPlan.ps1` | Read-only | Builds T1/T2/stop condition plan from position levels. |
| `New-TosOrderRulesThresholdEditPlan.ps1` | Read-only | Builds a guarded dry-run plan for editing one Order Rules threshold field. |
| `Invoke-TosOrderRulesThresholdEdit.ps1` | UI-open / optional save-capable | Fresh-snapshots Order Rules, verifies row and Submit at, edits threshold, verifies copied value. Save requires explicit `-AllowSave`. |
| `Test-TosOrderRulesThresholdEditLoop.ps1` | UI-open | Repeats the no-save threshold edit path for reliability testing. |
| `Find-TosStagedOrderInSnapshot.ps1` | Read-only | Verifies a staged/replacement order row in a saved TOS main-window snapshot by symbol/order ids/threshold. |
| `New-TosConfirmAndSendPlan.ps1` | Read-only | Builds a final Confirm and Send plan from a verified staged row and visible button. Does not click. |
| `New-TosOrderConfirmationSendPlan.ps1` | Read-only | Verifies the TOS Order Confirmation Dialog and final Send button. Does not click final Send. |
| `Ensure-TosMonitorWorkingOrders.ps1` | UI-open | Forces the main TOS surface back to `Monitor` and verifies `Working Orders` is open before locating a working OCO row. |
| `Ensure-TosOrderEntryMaintenanceSurface.ps1` | UI-open | Verifies `Order Entry and Saved Orders` is open, `Order Entry` is selected, and `Order and Strategy Book` is closed before threshold edits. |
| `Invoke-TosNativeInput.ps1` | UI helper / dry-run default | Guarded Win32 mouse/key primitive. Requires `-AllowInput` and caller-side rediscover/verify. |
| `Click-ScreenAbsolute.ahk`, `Send-KeysGlobal.ahk`, `Wheel-ScreenAbsolute.ahk` | UI helper | Low-level AHK primitives. Use only behind validated higher-level scripts. |
| `TosPrivacyRedactor.psm1` | Read-only support | Sanitizes TOS account identifiers in screenshots, JAB dumps, JSON, CSV, Markdown, logs, and diagnostic text. Uses JAB-derived account selector bounds when available and applies a solid opaque screenshot mask. |
| `Repair-TosPrivacyArtifacts.ps1` | Read-only/cleanup | Re-sanitizes existing generated artifacts and redacts stored TOS PNGs using paired JAB tree bounds. |

## Rules

- Do not use raw AHK helpers directly for live orders unless a higher-level script has already identified the exact target row/window.
- Never enable `Submit at` for OCO condition updates.
- Live submit/cancel/replace must produce before/after artifacts in `Analysis` and must be reflected in the dashboard status.

## TOS Hybrid Automation Notes

- `New-TosAutomationSnapshot.ps1` now writes a text tree, structured JSON tree, metadata, and screenshot.
- Locator scorer output is evidence, not permission to click. Production recipes must still verify the current screen state, rediscover after each UI change, and read back the edited value.
- Capture mode is the preferred way to teach exact TOS controls: place the mouse over the target control and run `Capture-TosElementUnderMouse.ps1`.





| `New-TosOcoUpdateBatchPlan.ps1` | Read-only | Builds one desktop-update work item per visible TOS OCO/order row, preserving multiple T1/T2 stops per ticker and optionally verifying current order IDs from a TOS snapshot. |
| `Switch-TosAccount.ps1` | UI-open with explicit flag | Detects the current TOS account from the main header, opens the account selector only when needed, chooses `IRA` or `Living Trust`, and verifies the header before returning success. Screenshots/JAB artifacts are redacted. |
| `Invoke-TosOcoDesktopBatch.ps1` | Read-only / UI-open with explicit flags | Consumes the desktop OCO batch JSON, refuses ambiguous rows, verifies account context, and can apply one already-open Order Rules threshold edit with `-AllowInput`; saving still requires `-AllowSave`. |
| `Set-TosActiveOrderEntryTriggerThreshold.ps1` | UI-open | Verifies `Order Entry and Saved Orders` / `Order Entry`, refuses `Order and Strategy Book`, verifies symbol/OCO/replacing order context, and sets the active trigger threshold field. |
| `Invoke-TosOcoDesktopWorkflow.ps1` | UI-open / submit-capable with explicit flags | One-shot staged workflow: locate working order, cancel/replace, set active Order Entry threshold, open confirmation, verify preview, and optionally final send with `-AllowFinalSend`. |

## Privacy Rules

- Do not rely on Thinkorswim Privacy mode for automation captures.
- Any TOS screenshot/debug image must be captured to memory, redacted in memory, and then saved. Raw screenshots containing account numbers must not be persisted.
- Account-number redaction is handled by `TosPrivacyRedactor.psm1`. It prefers Java Access Bridge account-selector bounds, expands the rectangle slightly, and applies a solid opaque block.
- JAB tree text, structured JSON, CSV, Markdown reports, and logs must write `ACCOUNT_REDACTED` plus account ending only when needed for operator verification.
- Use `Repair-TosPrivacyArtifacts.ps1 -Roots @('Analysis','TosAutomation','Wiki','tools\Analysis') -RedactImages` after any diagnostic capture changes or before sharing artifacts.


## Existing OCO Desktop Workflow

Correct TOS surface for maintenance:

1. `Monitor`
2. `Order Entry and Saved Orders` accordion open
3. `Order Entry` tab selected
4. `Order and Strategy Book` closed

Run to confirmation preview, but do not final send:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\Invoke-TosOcoDesktopWorkflow.ps1" -Symbol USB -Phase Stop -OcoId 1007453365774 -ReplacingOrderId 1007453365777 -Stage RunToConfirmation -AllowInput
```

Final send is a separate boundary and requires both flags:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\Invoke-TosOcoDesktopWorkflow.ps1" -Symbol USB -Phase Stop -OcoId 1007453365774 -ReplacingOrderId 1007453365777 -Stage RunToFinalSend -AllowInput -AllowFinalSend
```

The workflow refuses ambiguous batch rows and writes diagnostics under `TosAutomation\Diagnostics` plus sanitized snapshots under `TosAutomation\Discovery`.

Dashboard API:

```text
POST /api/oco/desktop-workflow
```

Use `stage=RunToConfirmation` for the complete guarded path through confirmation preview. Use `stage=RunToFinalSend` only when the operator intends to complete the live cancel/replace.

Dashboard controls:

- `Prepare Living Trust` switches/verifies TOS is on Living Trust, captures a sanitized TOS snapshot, extracts visible working orders, and builds a Living Trust-scoped desktop batch from the uploaded JSON.
- `Prepare IRA` performs the same account-scoped preparation for IRA stock-side orders.
- `Run Next Preview` picks the first verified ready desktop OCO update and runs it through the TOS confirmation preview.
- `Run Next Final Send` picks the first verified ready desktop OCO update, requires a browser confirmation, verifies the TOS confirmation dialog, clicks final Send, then refreshes TOS and rebuilds the desktop batch.
- Rows with `SnapshotStatus` of `CANCELED` or `FILLED` are not eligible for desktop automation.
- The workflow now self-navigates to `Monitor`, verifies `Working Orders`, uses the real row viewport instead of a fixed y-offset, closes `Order and Strategy Book`, and captures confirmation dialogs via the `Order Confirmation` window title.

Verified live replacement on 2026-08-15:

- ASB Stop, OCO `1007531194984`
- Replaced active order `1007574646220`
- Confirmed and sent condition `ASB MARK AT OR BELOW 31.41`
- Post-send TOS snapshot shows new row `(Replacing #1007574646220) ... OCO #1007531194984 WHEN ASB MARK AT OR BELOW 31.41`

Post-update verification command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AI-Chat GPT\SwingManager\tools\New-TosOcoUpdateBatchPlan.ps1" -VisibleOrdersCsv "D:\AI-Chat GPT\SwingManager\Analysis\tos-visible-working-orders-20260815-144247.csv" -ReconciliationCsv "D:\AI-Chat GPT\SwingManager\Analysis\tos-oco-reconciliation-20260815-141549.csv" -SnapshotJson "D:\AI-Chat GPT\SwingManager\TosAutomation\Discovery\tos-UsbAfterSecondStopSend-20260815-144218-tree.json" -Symbol USB -OutFile "D:\AI-Chat GPT\SwingManager\Analysis\tos-oco-desktop-update-batch-USB-post-send-verified.json"
```

Expected result after the verified USB run:

- `readyCount = 0`
- Active USB stop rows at `63.51` are `no_change`
- Old USB stop rows at `63.19` are `skip_inactive_snapshot_row`, not ready work
