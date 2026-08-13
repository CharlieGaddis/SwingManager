# Swing Manager Wiki

Last updated: 2026-08-12 22:45 ET

## Mission

Swing Manager manages Squeeze Intel swing trades from daily JSON reports and coordinates with Schwab/thinkorswim.

Core responsibilities:

- Import the daily Squeeze Intel JSON report.
- Build the pending entry queue for IRA stock trades and Living Trust option/spread trades.
- Monitor enabled pending entries and submit real Schwab API entry orders when triggers hit.
- Reconcile fills, working orders, and positions.
- Create or maintain protective risk-management orders after fills.
- Use TOS desktop automation for conditional option/spread OCO management because Schwab API does not support the required cross-symbol conditional workflow.

## Current App Location

Active project:

`D:\AI-Chat GPT\SwingManager`

Dashboard:

`http://127.0.0.1:8765`

Launch:

```powershell
& "D:\AI-Chat GPT\SwingManager\Start-SwingPendingManager.ps1" -OpenBrowser
```

## Current Data Source

Near term: manually download the Squeeze Intel JSON and upload it through Swing Manager.

Dashboard workflow now supports:

- `Upload + Build Queue`
- `Run TOS Preflight`

Long term: add `Fetch Latest Report` if the source site exposes a stable authenticated download/API path.

## Accounts

- IRA: stock entries and stock stop management.
- Living Trust: option/spread entries and TOS conditional OCO management.

Account guards are mandatory. Stock-stop automation must not run in the Living Trust account, and option/spread OCO automation must not run in the IRA account.

## Entry Lifecycle

Use these status concepts consistently:

- `Pending trigger`
- `API entry submitted`
- `API entry working`
- `API entry filled`
- `Needs initial risk setup`
- `Protected / OCO active`
- `Needs update from latest JSON`
- `Exception / manual review`

Do not call pending entries virtual trades. They are real pending triggers managed by Swing Manager.

## New Position Requirement

Every new fill must receive risk-management orders before the position is considered protected.

- IRA stock fills need stock stop/profit-management orders.
- Living Trust option/spread fills need two management slices: T1 and T2, each with appropriate stop protection.
- New-position setup is separate from nightly maintenance of existing OCOs/stops.

## Nightly Workflow

1. Upload the latest JSON.
2. Build the action queue.
3. Pull/verify Schwab state through Trading Dashboard.
4. Capture TOS working orders through Java Access Bridge.
5. Reconcile expected active OCOs/stops against visible/working orders.
6. Show dashboard statuses: ready, needs update, not visible, ambiguous, initial setup required, manual review.
7. Apply updates only through guarded workflows with verification and audit logs.

## Current Readiness

Working tonight:

- Dashboard server running on port `8765`.
- JSON upload/build endpoint tested successfully with `squeeze-intel-2026-08-12.json`.
- TOS preflight endpoint tested successfully; it captured TOS and produced a fresh reconciliation without changing orders.
- OCO dry-run wrapper found both USB spread stop OCOs active at `63.19`.

Not yet complete:

- Schwab connection is currently unauthenticated in Trading Dashboard.
- Bounded Working Orders scroll/search needs to be added.
- IRA stock-stop update queue needs to be added.
- End-to-end live TOS cancel/replace/save/confirm/send is not yet enabled in one guarded command.
- GitHub remote and first commit are not yet set up.

## Primary References

- `Wiki\Tomorrow-Live-Runbook.md`
- `Wiki\TosOcoAutomationState.md`
- `Wiki\PendingOrderManager.md`
- `Wiki\Cleanup-Plan.md`
