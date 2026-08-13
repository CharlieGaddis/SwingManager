# Swing Manager Tools

Last updated: 2026-08-12 22:50 ET

## Safety Levels

- Read-only: inspects files, API, or TOS state without UI clicks.
- Dry-run: builds a plan and refuses live UI changes.
- UI-open: may click/open TOS windows but should not save/submit.
- Save-capable: can save an order dialog after validation.
- Submit-capable: can submit/cancel/replace live orders. Use only after explicit approval and verification.

## Current Tools

| Tool | Level | Purpose |
|---|---|---|
| `Dump-TosJabTree.ps1` | Read-only | Dumps Java Access Bridge tree for TOS windows. |
| `Get-TosJavaWindows.ps1` | Read-only | Lists Java/TOS windows and context status. |
| `Get-TosJabControlInventory.ps1` | Read-only | Produces control inventory for an open TOS/JAB window. |
| `Find-TosJabTables.ps1` | Read-only | Finds visible JAB tables matching symbols/names. |
| `Update-TosExistingOcoCondition.ps1` | Dry-run | Matches exactly one visible active OCO row and writes an update plan. Live stages are intentionally not enabled yet. |
| `Open-TosOrderRulesForFirstOrderEntryRow.ps1` | UI-open | Verifies a staged order-entry row and clicks the computed Order Rules cell. |
| `Set-TosOrderCondition.ps1` | UI-open / optional save flag | Wrapper to set Target or Stop condition in an already-open Order Rules dialog. |
| `Set-TosSubmitCondition.ps1` | UI-open / save-capable with `-AllowSave` | Low-level condition editor. It guards `Submit at` so it stays off. |
| `New-TosOcoConditionPlan.ps1` | Read-only | Builds T1/T2/stop condition plan from position levels. |
| `Click-ScreenAbsolute.ahk`, `Send-KeysGlobal.ahk`, `Wheel-ScreenAbsolute.ahk` | UI helper | Low-level AHK primitives. Use only behind validated higher-level scripts. |

## Rules

- Do not use raw AHK helpers directly for live orders unless a higher-level script has already identified the exact target row/window.
- Never enable `Submit at` for OCO condition updates.
- Live submit/cancel/replace must produce before/after artifacts in `Analysis` and must be reflected in the dashboard status.
