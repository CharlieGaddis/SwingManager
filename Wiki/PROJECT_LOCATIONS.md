# Project Locations

Desktop source roots:

- TradingDashboard: `D:\AI-Chat GPT\TradingDashboard`
- Swing Manager: `D:\AI-Chat GPT\SwingManager`

Portable laptop source roots may live on another local drive, such as
`C:\Trading\SwingManager` and `C:\Trading\TradingDashboard`. Launch scripts
must derive their project location from their own file location rather than a
fixed drive letter.

Windows user-profile services, including `%LOCALAPPDATA%` data-protection key
storage, remain local runtime dependencies. They are not source-code locations
and must not be copied between machines.
