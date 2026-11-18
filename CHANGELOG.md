# Changelog

## Unreleased (UI branch, merge of `origin/asthetics`)

### Breaking changes

Anyone invoking the scripts below by their old path, or reading `data.json` / `history.json` with their own tooling, must update.

#### Scripts moved or replaced

| Old | New | Action |
|---|---|---|
| `Collector/Legacy/HistoryCollector.ps1` | `Collector/HistoryCollector.ps1` | Update the path. `Legacy/` copy is deprecated. |
| `Collector/Legacy/MergeJSON.ps1` | `Collector/MergeJSON.ps1` | Update the path. `Legacy/` copy is deprecated. |
| `Collector/Legacy/Update-MailboxDashboard.ps1` | `Collector/Update-MailboxDashboard.ps1` | Update the path. `Legacy/` copy is deprecated. |
| `Install-PrivateRepoAPI.ps1` | `Sync-MailboxDashboardFromGitHub.ps1` | Removed. Use the sync script instead. **(Confirm this mapping.)** |

#### Files moved or removed

| Old | New |
|---|---|
| `IMPLEMENTATION_PLAN.md`, `doco.md`, `Project MailboxDashboard.md` | `Collector/Legacy/Docs/` |
| `Mailboxes/Microsoft.PowerShell.ThreadJob Module.md` | `Collector/Legacy/Docs/` |
| `Mailboxes/FILESTRUCTURE.txt` | Removed. Replaced by `Collector/Legacy/Docs/FILESTRUCTURE.txt`. |
| `Web/logs/httpserver.log` | No longer tracked. `Web/logs/` is git-ignored. |

#### Configuration

- `Collector/Config/dashboardConfig.json` is no longer tracked, because it holds tenant IDs and secrets. Copy `dashboardConfig.example.json` and fill in your values.
- `Collector/Modules/MailboxDashboard.Config.psm1` now validates paths. It fails if `Paths.MailboxesCsv`, `HistoryJson` or `DataJson` is missing, if the mailbox CSV does not exist, or if a parent or working directory does not exist.
- The config module uses `?.` (null-conditional), so **PowerShell 7+ is required**.

#### JSON output (`Web/data.json`, `Web/history.json`)

> TODO: list the changed fields before release. Compare the output of the previous and current collectors, or run `Collector/Test-MailboxDashboardJSON.ps1` against old files.

Old JSON files may not load in the new UI. Regenerate them by running a collection.

### Added

- `Web/modern/`: new UI (`index.html`, `mailbox.html`, `modern.css`, `modern.js`, `qrcode.js`).
- `Collector/New-MailboxDashboardUrl.ps1`
- `Collector/Test-ExchangeOnlineCalendarDiagnostic.ps1`
- `Sync-MailboxDashboardFromGitHub.ps1`

### Changed

- `Collector/Get-ExchangeOnlineAccessToken.ps1`, `Initialize-MailboxDashboard.ps1`, `Invoke-MailboxDashboardCollection.ps1`, `Register-EntraApp.ps1`, `Test-MailboxDashboardJSON.ps1`, `Deploy-MailboxDashboard.ps1`
- `Web/index.html`, `scope.html`, `validate.html`, `styles.css`
- Setup walkthrough (`.md` and `.html`)

### Migration

1. Update any scheduled tasks or shortcuts that call `Collector/Legacy/*.ps1` to use the new `Collector/*.ps1` paths.
2. Create `Collector/Config/dashboardConfig.json` from the example file.
3. Run on PowerShell 7+.
4. Re-run a collection to regenerate `data.json` and `history.json`.
