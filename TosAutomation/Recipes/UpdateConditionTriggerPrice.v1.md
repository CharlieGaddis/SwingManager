# Recipe: Update Condition Trigger Price v1

Status: discovery/testing only. Not production-approved.

## Goal

Update one existing Thinkorswim conditional trigger value in an already staged cancel/replace order, then verify the persisted value.

## Preconditions

- Correct account is visible/selected.
- Correct working order has been located by symbol, OCO id, side, status, and old trigger threshold.
- Cancel/replace has created the staged replacement order.
- Order Rules dialog is open for the staged replacement order.
- `Submit at` is unchecked.

## Transaction

1. Fingerprint current screen as `OrderRulesDialog`.
2. Locate the conditions section by semantic anchors.
3. If the conditions section is collapsed, native-click the header and discard the old JAB tree.
4. Rediscover the dialog tree.
5. Locate the condition row by underlying symbol and method `MARK`.
6. Locate the trigger price cell by row-relative geometry.
7. Native-click or double-click the trigger cell.
8. Send `Ctrl+A`, type the new threshold, then `Tab`.
9. Rediscover the dialog tree.
10. Verify the condition row contains the new threshold.
11. Verify `Submit at` remains unchecked.
12. Save Order Rules.
13. Rediscover the staged order row.
14. Verify the staged replacement text contains the new threshold.
15. Final submit is a separate guarded recipe.

## Abort Conditions

- More than one candidate row matches.
- No candidate reaches the confidence threshold.
- The current account does not match the expected account.
- `Submit at` becomes checked and cannot be unchecked.
- Read-back does not match the intended new threshold.
- Any unexpected confirmation text appears.

## Repeatability Target

25 consecutive successful supervised cycles before promotion to `Production/`.
