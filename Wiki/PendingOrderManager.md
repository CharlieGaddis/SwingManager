# Pending Order Manager

The pending order manager watches the Squeeze Intel pending entries without placing broker-side conditional entry orders. This avoids tying up IRA buying power or Living Trust option buying power before the underlying stock trigger is actually hit.

## Inputs

- Latest action queue: `Analysis\squeeze-action-queue-YYYYMMDD.csv`
- Queue source: `Build-SqueezeActionQueue.ps1`
- Local settings: `Config\pending-manager.json`
- Local row state: `Data\pending-state.json`

When a pending entry disappears from the latest JSON/action queue, it disappears from the Swing Manager pending grid. User-deleted rows are also hidden through local state.

## Accounts

- `IRA`: stock entries only.
- `Living Trust`: option entries and option spreads.

Stock entries use the configured max capital, currently `5000.00`. Share quantity is rounded to the nearest whole share, then reduced if needed so the estimated cost does not exceed the configured max capital.

Option entries use the contract count from the JSON. Straight calls/puts and spreads are separate entries and should both be monitored.

## Trigger Logic

Entries are driven by the underlying stock price:

- Calls and long stock entries trigger when the underlying is less than or equal to the JSON stock limit price.
- Puts trigger when the underlying is greater than or equal to the JSON stock limit price.

The local web app polls the TradingDashboard Schwab quote endpoint:

`GET http://127.0.0.1:5080/api/schwab/quotes?symbols=HSIC,BNY,...`

## Execution Plan

The web app currently starts in `paper` execution mode. In paper mode, a hit trigger records/stages the intended order but does not transmit to Schwab.

Planned live stock fill method:

- Submit a buy limit at the bid.
- Refresh/cancel-replace every 15 seconds for the first minute.
- After one minute, work the order at mark.
- If the underlying moves away before fill, keep monitoring and reconcile with TOS/Schwab.

Planned live option fill method:

- Submit the option or spread from the JSON at the bid-side debit for the first minute, refreshing every 15 seconds.
- For a single option buy, bid-side means the option bid.
- For a debit spread buy, bid-side means long-leg bid minus short-leg ask.
- After one minute, step the live order to the option/spread mark.
- The underlying stock trigger controls when the order is sent.
- Before each refresh/replace, re-check that the underlying is still at a valid entry price.
- Reconcile fills from Schwab/TOS, then create or maintain OCO management orders in TOS.

Live Schwab transmission remains intentionally guarded by `Config\pending-manager.json` until the final Schwab submit adapter is reviewed and enabled.

## 2026-08-12 Live Submit Breakthrough

Swing Manager now has a local Schwab submit helper at `tools/SwingSchwabSubmit`.

The first live API submit test used PBF and posted three orders:

- IRA stock order: BUY 77 PBF LIMIT 64.83 DAY.
- Living Trust single call: BUY_TO_OPEN 3 PBF 09/18/2026 60C LIMIT 11.45 DAY.
- Living Trust vertical spread: BUY_TO_OPEN 6 PBF 09/18/2026 65C / SELL_TO_OPEN 6 PBF 09/18/2026 75C NET_DEBIT 4.30 DAY.

All three were accepted by Schwab with HTTP 201 and appeared in recent order readback as `PENDING_ACTIVATION`.

## Auto-Fire Launch Path

The monitor now calls the generic Schwab submit helper when all of the following are true:

- The row is enabled in the pending grid.
- The underlying stock trigger is hit.
- `Config/pending-manager.json` has `executionMode` set to `live`.
- The row has not already been submitted or failed.

On a live trigger, Swing Manager writes a JSON submit plan under `Data/live-submit-plans`, calls `tools/SwingSchwabSubmit`, stores the Schwab order id/location in `Data/pending-state.json`, and records an event in `Data/pending-events.jsonl`.

The first launch version is intentionally one-shot per trigger. The next hardening step is the cancel/replace ladder:

- Refresh every 15 seconds during the first minute.
- Keep using bid-side pricing during that first minute.
- Step to mark after one minute.
- Re-check the underlying is still valid before each replace.

## 2026-08-12 Live Readiness Work

The monitor now has a safer live baseline:

- Paper dry-run rows no longer permanently block a later live submit.
- A real Schwab order id is the primary duplicate lock.
- Live entries are guarded by `Config\pending-manager.json` and currently allow `09:30-16:30 America/New_York`, weekdays only.
- Live monitor start performs Schwab preflight:
  - TradingDashboard reachable.
  - Schwab configured.
  - Schwab connected.
  - Access token not expired.
  - IRA and Living Trust account numbers resolvable.
- Live submit is not considered accepted unless Schwab returns both success and an order id.
- After submit, Swing Manager attempts immediate readback confirmation from Schwab recent orders.
- Submitted live orders are reconciled through the TradingDashboard Schwab order endpoint.
- The grid exposes Schwab order id, broker status, and filled quantity.

Broker status mapping:

- `FILLED` -> `filled_pending_oco`
- partial status -> `partial_fill_review`
- `WORKING`, `PENDING_ACTIVATION`, `QUEUED`, `ACCEPTED`, `AWAITING_CONDITION` -> `live_working`
- `CANCELED`, `CANCELLED`, `REJECTED`, `EXPIRED` -> `broker_terminal`

Remaining live launch choice for Charlie:

- First live day can run one-shot auto-submit with reconciliation only.
- Or we can finish and enable cancel/replace ladder before first live day.

Safer recommendation: first live day uses one-shot auto-submit and TOS manual cancellation/modification if needed; add ladder after watching behavior.

Clarification from Charlie:

- Charlie was not confused about the remaining live work.
- The essential safety work is order confirmation, duplicate prevention, and feedback when an order is filled so Swing Manager can update state and trigger OCO handoff.
- This is now the core definition of "live-ready" before unattended use.

## 2026-08-12 Closeout Plan

Current launch posture:

- Tomorrow is a paper-trade dry run day. Keep `executionMode` set to `paper`.
- Charlie will watch the pending orders and accepts that a few trades may be missed during dry-run hardening.
- After the dry run, move toward live monitoring by changing `Config/pending-manager.json` from `paper` to `live`.
- The first live version should auto-fire only from enabled rows and should not require manual fire buttons.
- Charlie will use TOS directly for intraday cancellation/modification if needed.
- TOS OCO work should generally happen after market hours because Charlie needs TOS during live trading.

Near-term engineering sequence:

1. Paper-trade tomorrow with the monitor running and confirm trigger behavior, quote feed freshness, and event logging.
2. Add fill reconciliation so submitted Schwab order IDs are checked for `FILLED`, partial fill, cancellation, or rejection.
3. Add the cancel/replace ladder:
   - Initial order at stock bid, single-option bid, or spread bid-side debit.
   - Replace every 15 seconds during the first minute.
   - Step to mark after 60 seconds.
   - Re-check the underlying trigger before each replace.
4. Add OCO handoff for newly filled positions:
   - For filled stock entries, build target and stop OCO orders in the IRA account.
   - For filled option entries/spreads, build conditional T1/T2 and stop OCO management in TOS.
   - The mechanics should mostly reuse the current TOS OCO update workflow, except there is no existing OCO to cancel/replace.
5. Automate the nightly JSON import from Simpler Trading.

## Simpler Trading JSON Import

The next major external integration is getting Swing Manager access to the Simpler Trading website so it can download the daily Squeeze Intel JSON after it is published.

Expected workflow:

- Log in to Simpler Trading using Charlie's authorized session or credentials.
- Navigate to/download the daily Squeeze Intel dashboard JSON.
- Save the file under the Swing Manager input/archive area.
- Run `Build-SqueezeActionQueue.ps1` against the new JSON and previous JSON.
- Reconcile pending entries:
  - New JSON pending rows appear in Swing Manager.
  - Rows that fall off the JSON disappear from the grid unless already submitted/filled and under reconciliation.
  - User-deleted rows remain locally suppressed.
- Reconcile open positions:
  - Compare active stock and option positions/OCOs against the latest JSON.
  - Tighten stops and update targets after market.
  - Flag exceptions when JSON expects an OCO but Schwab/TOS has no matching open order.

Implementation options to evaluate:

- Browser automation with an authenticated browser profile if Simpler Trading does not expose a direct API.
- A direct download URL if the dashboard makes the JSON request from the browser.
- A manual drop-folder fallback for the first few days.

## GitHub Source Protection

We should move the durable source code to GitHub soon, but only the bare minimum should be committed.

Keep in GitHub:

- Core PowerShell scripts.
- `pending_manager_server.py`.
- `web/` UI files.
- `tools/SwingSchwabSubmit` source files.
- `Config/*.example.json` or sanitized config templates.
- `Wiki/` documentation.
- Small synthetic fixtures needed for tests.

Do not commit:

- Raw Schwab order/account captures.
- TOS screenshots.
- Java Access Bridge tree dumps.
- AHK coordinate capture CSVs unless promoted into intentional source assets.
- `Data/pending-state.json`, `Data/pending-events.jsonl`, live submit plans, OAuth tokens, account hashes, or any personal credentials.
- `bin/`, `obj/`, `__pycache__/`, temporary files, and downloaded JSONs unless sanitized.

Before creating the GitHub repo, add a `.gitignore` and likely move old analysis artifacts into a local-only archive. The repo should protect source code without uploading unnecessary or sensitive operational history.

## Running

From the project folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-SwingPendingManager.ps1
```

Open:

`http://127.0.0.1:8765`
