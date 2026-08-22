# Portable Desktop And Laptop Setup

The coordinated TradingDashboard package contains an editable Swing Manager
checkout, a slim approved Python runtime, and guarded start/sync scripts. See
TradingDashboard `Docs\LAPTOP_DEPLOYMENT.md` for package installation.

Swing Manager is installed as source code on both Windows machines. The active
machine runs TradingDashboard, Swing Manager, and TOS locally; the other machine
must not run the live monitor.

## Code Versus Runtime Data

- GitHub synchronizes source code only.
- `Config\machine.local.json` is machine-local and ignored by Git.
- `Data` and `Analysis` are runtime output. They belong under the configured
  runtime root and are not synchronized by Git.
- OAuth tokens, Data Protection keys, credentials, TOS screenshots, and raw
  diagnostics must stay local to the machine that created them.

## Desktop Profile

The existing desktop layout remains valid. With no `Config\machine.local.json`,
runtime data continues to use the project folder:

```text
D:\AI-Chat GPT\SwingManager
```

For a separate large-data location, create `Config\machine.local.json` from
`Config\machine.example.json` and set, for example:

```json
{
  "runtimeRoot": "D:\\TradingData\\SwingManager"
}
```

## Laptop Profile

Clone only the two source repositories to the laptop, for example:

```text
C:\Trading\SwingManager
C:\Trading\TradingDashboard
```

Create `C:\Trading\SwingManager\Config\machine.local.json`:

```json
{
  "runtimeRoot": "%LOCALAPPDATA%\\SwingManager",
  "pythonPath": "C:\\Trading\\Runtime\\Python\\python.exe",
  "iraAccountNumber": "",
  "livingTrustAccountNumber": ""
}
```

The launcher derives its project path from its own location and uses this
runtime root for `Data` and `Analysis`. It does not require a D drive.

## Operating Rule

Before travel handoff is implemented, change active machines explicitly:

1. Stop Swing Manager monitoring on the outgoing machine.
2. Verify its monitor is stopped.
3. On the incoming machine, pull tested source code and run local Schwab/TOS
   readiness checks before starting the monitor.
4. Reconcile broker working orders before enabling live entries.

Account selectors belong only in the ignored machine-local profile or matching
environment variables. The package does not contain them. Current nightly JSON,
active pending-entry state, and broker state require an explicit reconciliation
handoff; they are not synchronized by Git.
