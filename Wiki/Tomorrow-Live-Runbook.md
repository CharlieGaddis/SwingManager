# Swing Manager Live Runbook

Target session: 2026-08-13
Last updated: 2026-08-13 live-readiness check

## Launch

Use quoted PowerShell invocation because the project path contains a space:

```powershell
& "D:\AI-Chat GPT\SwingManager\Start-SwingPendingManager.ps1" -OpenBrowser
```

Dashboard URL: `http://127.0.0.1:8765`

Trading Dashboard URL: `http://127.0.0.1:5080`

## Current safety posture

After the CXW spread-order issue, keep Swing Manager in `paper` mode until option spread leg direction is fixed and retested.\n\n## Current Readiness

Last checked on 2026-08-13:

- Trading Dashboard Schwab status must be `connected: true`, `orderCapability: true`, token not expired. If `orderCapability` is false, do not go live.
- Swing Manager current safe default: `executionMode: paper`, monitor stopped. Switch to `live` only after the morning preflight passes.
- Broker active-order readback: 0 active working orders from Schwab recent-order API.
- Swing Manager now checks broker-side active matching orders before first live submit and fails closed if the check cannot run.
- Do not start the monitor until enabled trigger-hit rows are reviewed. Current checkpoint found `CXW 32/30P 09-18` already trigger-hit and armed.

## Morning Readiness

1. Start Trading Dashboard.
2. Restore/confirm Schwab connection and order capability.
3. Start Swing Manager.
4. Upload the current Squeeze Intel JSON through `Nightly Workflow -> Upload + Build Queue`.
5. Run `Nightly Workflow -> Run TOS Preflight` with TOS open and logged in.
6. Review OCO statuses and pending entry rows.
7. Confirm quote feed populates after Schwab auth is restored.
8. Review every enabled row; uncheck or delete anything that should not auto-enter.
9. Confirm `Config\pending-manager.json` is `"executionMode": "live"` only after final review.
10. Start the monitor. Live startup should refuse if Schwab/account checks fail.

## Live Behavior

- Enabled rows only.
- Before first live submit, Swing Manager checks Schwab recent orders for an active matching setup and blocks duplicate submission.
- New live entries are limited to `09:35-15:30 America/New_York` on weekdays. The monitor may run outside that window, but live submits are skipped/blocked.
- Trigger must still be valid at submit time.
- Initial order uses bid-side pricing.
- If still working after `bidPhaseSeconds`, Swing Manager cancels the initial order and submits one mark-price replacement.
- Replacement is capped by `maxCancelReplaceCount`. Current default: `1`.
- Filled orders move to `filled_pending_oco`; partial fills move to `partial_fill_review`.

## During Session

Keep TOS visible for order review. If any row moves to `live_submit_failed`, `live_replace_failed`, `partial_fill_review`, or `broker_terminal`, handle it manually in TOS before rearming that row.

## After Fill

Every new fill requires risk-management setup before it is considered protected.

- IRA stock fills: create/update stock stop/profit-management orders.
- Living Trust option/spread fills: create T1/T2 OCO/risk-management structure in TOS.

For tomorrow, OCO/stop handoff remains guarded/review-assisted. Use the dashboard preflight and existing scripts to identify required updates. Do not rely on memory from chat.

## Tested Tonight

- JSON upload/build endpoint passed with `squeeze-intel-2026-08-12.json`.
- TOS preflight endpoint passed and produced `tos-oco-reconciliation-20260812-223113.csv`.
- USB OCO dry-run matched both active spread stop parents at `63.19` without clicks.

## 2026-08-13 Spread Direction Fix

- Fixed put_credit_spread entry payloads to use NET_CREDIT: sell the higher-strike put and buy the lower-strike put.
- Verified dry-run CXW 32/30P 09-18: SELL_TO_OPEN CXW 32P, BUY_TO_OPEN CXW 30P, NET_CREDIT.
- Verified dry-run PBF 65/75C 09-18 still uses NET_DEBIT: BUY_TO_OPEN 65C, SELL_TO_OPEN 75C.
- Swing Manager remains paper and monitor stopped until a final supervised paper/live-readiness check.

## 2026-08-13 Readiness Review

- Dashboard Upload + Build Queue endpoint was tested with squeeze-intel-2026-08-12.json: 38 pending entries, no workflow error.
- Live order entry remains blocked unless Trading Dashboard reports Schwab orderCapability: true.
- Mark replacement now checks the live-entry window before canceling an existing order, so it will not cancel first and then fail to re-submit outside the allowed window.
- TOS preflight is required after tonight's JSON; any NOT_VISIBLE_IN_CURRENT_VIEW or REVIEW_* rows need manual review before live start.
