# Swing Manager Live Runbook

Last updated: 2026-08-17

This page is the durable checkpoint for the current live workflow. It exists so the TOS desktop automation is saved in the project, not rediscovered from chat.

## Entry Monitor

Use the dashboard upload flow for the nightly Squeeze Intel JSON:

1. Choose the JSON file.
2. Click `Upload + Build Queue`.
3. Review pending entries and OCO review counts.
4. Use live entry monitoring only during the configured market window.

Current live entry policy:

- Swing Manager is production-approved for live pending-entry submission. Do not turn off live entries or change `Config\pending-manager.json` back to `paper` unless Charlie explicitly requests that.
- TradingDashboard order capability is separate from Swing Manager entry submission. If TradingDashboard is connected and the shared Schwab token/account lookup works, a disabled TradingDashboard order toggle must not stop Swing Manager from entering trades.
- Live entry window is hardcoded in `Config\pending-manager.json` as `09:30-16:00 America/New_York`, weekdays only.
- Entry-only live mode is allowed when historical OCO/stop rows are unresolved.
- Manual OCO is required immediately after any new fill until full OCO creation is promoted.
- One active order per setup is enforced by the pending queue/order-id tracking and live preflight.
- Schwab submit payloads currently use `session: NORMAL`; entries are intentionally limited to the regular session.

## Existing OCO Updates

The durable desktop path for existing T1/T2/Stop maintenance is:

1. Select/verify the correct TOS account.
2. Navigate TOS to `Monitor`.
3. Verify `Working Orders` is open.
4. Find the specific active OCO row by symbol, OCO id, replacing order id, phase, and expected old/new trigger.
5. Right-click the row.
6. Click `Cancel/replace order`.
7. Verify `Order Entry and Saved Orders` is open.
8. Verify `Order Entry` tab is selected.
9. Close `Order and Strategy Book` if it is open.
10. Open Order Rules from the staged replacement row.
11. Keep `Submit at` unchecked.
12. Update the condition trigger threshold.
13. Save Order Rules.
14. Open `Confirm and Send`.
15. Verify the `Order Confirmation` dialog has the expected symbol, OCO id, replacing order, and new condition text.
16. Final send only when the run mode explicitly includes final send.

Hardcoded guard scripts:

- `tools/Ensure-TosMonitorWorkingOrders.ps1`
- `tools/Ensure-TosOrderEntryMaintenanceSurface.ps1`
- `tools/Open-TosCancelReplaceFromBatch.ps1`
- `tools/Set-TosActiveOrderEntryTriggerThreshold.ps1`
- `tools/Invoke-TosOcoDesktopWorkflow.ps1`

Dashboard controls:

- `Prepare Living Trust`: switch/verify Living Trust, capture TOS, extract working orders, build account-scoped OCO update batch.
- `Prepare IRA`: switch/verify IRA, capture TOS, extract working orders, build account-scoped OCO update batch.
- `Run Next Preview`: run the next verified work item through confirmation preview.
- `Run Next Final Send`: run the next verified work item through final send after confirmation.

## New Positions

New positions are different from existing OCO maintenance:

- Existing OCO updates modify already-working T1/T2/Stop orders.
- New filled positions need new risk mitigation orders created from scratch.
- Every new position normally needs T1 with stop and T2 with stop.
- If one leg is already filled or stopped, the worklist must detect the remaining unprotected quantity.

Until full new-OCO creation is promoted, the dashboard must surface new fills as manual OCO-required work.

## Privacy

Do not rely on TOS privacy mode. Generated captures must redact only the account number before writing screenshots, JAB dumps, structured JSON, logs, or diagnostics.

Use:

- `tools/TosPrivacyRedactor.psm1`
- `tools/Repair-TosPrivacyArtifacts.ps1`

Raw unredacted TOS screenshots should not be persisted.

## Verified Proof

Verified live replacement on 2026-08-15:

- Account context: Living Trust
- Symbol: ASB
- OCO: `1007531194984`
- Replaced active order: `1007574646220`
- New condition: `ASB MARK AT OR BELOW 31.41`
- Final send completed successfully.

This proves the hardcoded path can navigate Monitor, use Working Orders, cancel/replace the correct row, edit the condition, verify confirmation, and submit.

## Next Promotion Target

Before marking full auto-OCO maintenance production-ready:

1. Run multiple account-scoped items from a fresh TOS state.
2. Verify post-send worklist rebuild removes completed rows.
3. Confirm both IRA stock-side and Living Trust option-side paths.
4. Preserve final proof in diagnostics, then commit only source/docs/config, not generated captures.
