# TOS OCO Automation State

Last updated: 2026-08-12 21:08 ET

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

## Restore Old C Directory?

The old `C:\Users\charl\Documents\ChatGPT\SwingManager` directory is not present. Do not restore it yet. Restore only if we determine there was a missing script not present in `D:\AI-Chat GPT\SwingManager`. The D project already contains the recovered screenshots, JAB dumps, workflow notes, and current tools needed to continue.

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
