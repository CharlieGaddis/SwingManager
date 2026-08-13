# Swing Manager Live Runbook

Target session: 2026-08-13
Last updated: 2026-08-12 22:45 ET

## Launch

Use quoted PowerShell invocation because the project path contains a space:

```powershell
& "D:\AI-Chat GPT\SwingManager\Start-SwingPendingManager.ps1" -OpenBrowser
```

Dashboard URL: `http://127.0.0.1:8765`

Trading Dashboard URL: `http://127.0.0.1:5080`

## Current Blocker

Before live trading, Trading Dashboard Schwab auth must be restored.

Last checked status:

- `connected: false`
- `orderCapability: false`
- `AUTHENTICATION_REQUIRED`
- `HTTPS_CERTIFICATE_MISSING`
- `SCHWAB_CALLBACK_CERTIFICATE_UNAVAILABLE`

Swing Manager should not be switched to live execution until Schwab status is connected and order-capable.

## Morning Readiness

1. Start Trading Dashboard.
2. Restore/confirm Schwab connection and order capability.
3. Start Swing Manager.
4. Upload the current Squeeze Intel JSON through `Nightly Workflow -> Upload + Build Queue`.
5. Run `Nightly Workflow -> Run TOS Preflight` with TOS open and logged in.
6. Review OCO statuses and pending entry rows.
7. Confirm quote feed populates after Schwab auth is restored.
8. Review every enabled row; uncheck or delete anything that should not auto-enter.
9. Keep `executionMode` as `paper` until row review and Schwab preflight pass.
10. Change `Config\pending-manager.json` to `"executionMode": "live"` only after final review.
11. Start the monitor. Live startup should refuse if Schwab/account checks fail.

## Live Behavior

- Enabled rows only.
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
