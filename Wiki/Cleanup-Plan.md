# Swing Manager Cleanup Plan

Last updated: 2026-08-12 22:45 ET

## Goal

Make Swing Manager durable as an application project: source-controlled, documented, and free of misleading duplicate/stale notes.

## Do Not Delete Yet

Do not delete TOS screenshots, JAB tree dumps, or old workflow notes until the equivalent behavior exists in guarded scripts and has been tested. Many Analysis files are noisy, but they are still evidence for coordinates, accessibility paths, and order-state verification.

## Immediate Cleanup Already Done

- Replaced stale `Wiki\README.md` that claimed the real project files were missing.
- Updated `Wiki\Tomorrow-Live-Runbook.md` with tonight's tested workflow and Schwab auth blocker.
- Added/updated `Wiki\TosOcoAutomationState.md` with OCO, IRA stock-stop, and new-position requirements.
- Added dashboard workflow controls for JSON upload and TOS preflight.`r`n- Consolidated duplicate `Open-TosOrderRulesForFirstOrderEntryRow.ps1` into `tools\`.`r`n- Deleted two stray CSV artifacts that were accidentally saved in `tools\`.`r`n- Added `tools\README.md` with safety levels.

## Confusing/Duplicate Code To Consolidate

1. `Open-TosOrderRulesForFirstOrderEntryRow.ps1`
2. `tools\Open-TosOrderRulesForFirstOrderEntryRow.ps1`

These appear to be duplicate or near-duplicate versions. Keep one canonical copy under `tools\` after comparing behavior.

3. `Invoke-TosOcoUpdateQueue.ps1`

Currently tells the user to open Order Rules manually. Once `tools\Update-TosExistingOcoCondition.ps1` grows live stages, either retire this script or make it call the new wrapper.

4. `Analysis\SetTosSubmitCondition-Notes.md` and related older notes

Some notes say save is impossible or not implemented. The code has evolved. Keep historical notes only if clearly marked historical.

## Generated Artifacts To Ignore In Git

Most `Analysis` outputs are generated and should not be committed unless intentionally promoted to documentation.

Recommended tracked docs:

- `Wiki\*.md`
- selected high-value design notes copied from `Analysis` into `Wiki` if still needed

Recommended ignored artifacts:

- `Analysis\*.csv`
- `Analysis\*.json`
- `Analysis\*.txt`
- `Analysis\*.png`
- timestamped reports and tree dumps
- `Data\`

## Next Code Cleanup Steps

1. Compare root vs `tools\Open-TosOrderRulesForFirstOrderEntryRow.ps1`.
2. Keep the better/canonical version in `tools\`.
3. Remove or archive the duplicate only after confirming no dashboard/script references it.
4. Add a `tools\README.md` that lists supported scripts and their safety level:
   - read-only
   - dry-run
   - opens TOS UI
   - can save
   - can submit
5. Add bounded Working Orders scroll/search as a script instead of chat guidance.
6. Add IRA stock-stop update queue and status output.
7. Add initial risk setup status for new fills.

## GitHub Recommendation

Yes, set up a private GitHub repository for Swing Manager.

Suggested repo name: `SwingManager`

Before first push:

1. Confirm `.gitignore` excludes generated artifacts and private runtime state.
2. Make first local commit with current app source and wiki.
3. Create private GitHub repo.
4. Add remote `origin`.
5. Push `master` or rename to `main` and push.

Do not commit secrets, Schwab tokens, account hashes, `Data\`, or generated TOS screenshots/tree dumps unless explicitly needed and scrubbed.

