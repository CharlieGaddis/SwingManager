# Cross-Assistant Handoff Runbook

_Last updated: 2026-08-29 ET._

This SwingManager handoff mirrors TradingDashboard
`Docs\CROSS_ASSISTANT_HANDOFF.md`. Use both files together when work crosses
intraday execution, swing-trade monitoring, Thinkorswim automation, or
desktop/laptop transfer.

## Source Of Truth

- TradingDashboard repo: `CharlieGaddis/TradingDashboard`
- SwingManager repo: `CharlieGaddis/SwingManager`
- Desktop roots:
  - `D:\AI-Chat GPT\TradingDashboard`
  - `D:\AI-Chat GPT\SwingManager`
- Laptop roots:
  - `C:\Trading\TradingDashboard`
  - `C:\Trading\SwingManager`

Git carries source, scripts, and durable docs only. Do not commit Schwab
tokens, OAuth material, credentials, full account numbers, local runtime data,
TOS diagnostics, screenshots, downloaded private reports, or
`Config\machine.local.json`.

## Project Boundary

SwingManager owns Squeeze Intel swing entries, pending-entry monitoring,
nightly action queues, IRA stock routing, Living Trust option/spread routing,
and guarded TOS OCO automation for swing positions.

TradingDashboard owns intraday signal detection, dashboard-local trade
management, Schwab/IBKR execution research, broker readback helpers, and the
coordinated portable laptop package.

Cross-project dependencies:

- SwingManager relies on TradingDashboard for Schwab connection/readiness,
  quotes, order readback helpers, and package scripts.
- TradingDashboard should not rewrite SwingManager account-routing rules.
- Only one machine may run live monitoring or order-entry workflows at a time.

## Planned Broker Destination

- Charlie intends to migrate Swing Manager Living Trust option/spread
  transactions to Interactive Brokers after TradingDashboard proves the full
  paper order lifecycle and a separate live rollout is approved.
- IRA stock transactions remain on Schwab/thinkorswim for the near term.
  Continue improving account-guarded TOS stop and target maintenance for IRA
  positions independently.
- Until those gates pass, current Swing Manager Schwab/TOS production routing
  remains authoritative. Do not infer live IBKR permission from this roadmap.

## Assistant Startup Reading

Start every new SwingManager discussion from these files:

1. `Analysis\ChatUpdate.md`
2. `Wiki\README.md`
3. `Wiki\PortableTwoMachineSetup.md`
4. `Wiki\SwingManagerLiveRunbook.md`
5. `Wiki\TosOcoAutomationState.md`
6. `Wiki\CROSS_ASSISTANT_HANDOFF.md`

For cross-project work, also read these TradingDashboard files:

1. `Analysis\ChatUpdate.md`
2. `Docs\README.md`
3. `Docs\CURRENT_STATE.md`
4. `Docs\OPEN_ITEMS.md`
5. `Docs\LAPTOP_DEPLOYMENT.md`
6. `Docs\PortableTwoMachineSetup.md`
7. `Docs\CROSS_ASSISTANT_HANDOFF.md`

Before broker execution or risk-management changes, read the applicable
TradingDashboard broker/order docs as well:

1. `Docs\BROKER_LIMITATIONS.md`
2. `Docs\ORDER_MANAGEMENT.md`
3. `Docs\TradingSignalRules.md`

## What To Update

- `Analysis\ChatUpdate.md`: overwrite after meaningful work; keep it short,
  current, and free of secrets.
- `Wiki\README.md`: update durable SwingManager status and navigation.
- Specific wiki runbooks: update when a workflow, safety rule, or TOS
  automation contract changes.
- TradingDashboard docs: update when the change affects shared broker,
  package, or cross-machine operation.

Do not rely on chat history alone. Put durable decisions into repo docs.

## Sync Direction

Desktop to laptop:

```powershell
cd "D:\AI-Chat GPT\SwingManager"
git status --short --branch
git add -p
git commit -m "Describe SwingManager change"
git push origin main

cd "C:\Trading\SwingManager"
git status --short --branch
git fetch origin
git pull --ff-only origin main
```

Laptop to desktop:

```powershell
cd "C:\Trading\SwingManager"
git status --short --branch
git fetch origin
git switch -c codex/laptop-recovery-swingmanager
git add -p
git commit -m "Recover laptop SwingManager changes"
git push -u origin codex/laptop-recovery-swingmanager

cd "D:\AI-Chat GPT\SwingManager"
git fetch origin
git diff main..origin/codex/laptop-recovery-swingmanager
```

Review recovery branches before merging. Leave machine-local config, runtime
data, and broker artifacts out of Git.

## Handoff Template

Use this for the short closeout in `Analysis\ChatUpdate.md`:

```text
Timestamp:
Project:
Branch/commit:
Files changed:
Tests or checks run:
Broker safety posture:
Cross-project dependency:
Open blockers:
Next recommended step:
Docs updated:
```
