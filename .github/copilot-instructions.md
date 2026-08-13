# Copilot Instructions for MailboxDashboard

## Project shape

MailboxDashboard is an Exchange Online mailbox monitoring app with a PowerShell collector pipeline and a static web dashboard.

- `Collector/` gathers mailbox history and current snapshots from Exchange Online.
- `Web/` serves the dashboard, charts, mailbox detail view, validation page, and theme assets.
- The key data flow is:
  `Exchange Online -> Collector scripts -> history.json / data.json -> Web UI`

## Repo map and file criticality

### Root

- `Project MailboxDashboard.md` - project summary and architecture notes. **Important**, but not runtime-critical.
- `Install-PrivateRepoAPI.ps1` - environment/bootstrap helper. **Optional**.
- `.hintrc` - hint/lint config. **Optional**.
- `.github/copilot-instructions.md` - this file. **Important**.

### Collector/

- `Collector/Config/dashboardConfig.json` - collector configuration and paths. **Critical**.
- `Collector/Register-EntraApp.ps1` - creates/repairs the Entra app registration. **Critical**.
- `Collector/Get-ExchangeOnlineAccessToken.ps1` - token acquisition helper. **Critical**.
- `Collector/HistoryCollector.ps1` - main collector. **Critical**.
- `Collector/Start-HistoryCollectorThreaded.ps1` - orchestration wrapper for the collector. **Critical**.
- `Collector/MergeJSON.ps1` - merges threaded output into `history.json` and regenerates `data.json`. **Critical** when using threaded collection.
- `Collector/Extract-HotData.ps1` - rebuilds `data.json` from `history.json`. **Critical** for regenerating the web snapshot.
- `Collector/Temp/*` - thread-job output, scratch files, merged intermediate JSON. **Disposable** and safe to delete/recreate.
- `Collector/Setup-Walkthrough.md` / `.html` - setup docs. **Optional**.

### Web/

- `Web/index.html` - overview dashboard. **Critical**.
- `Web/history.html` - mailbox history page. **Critical**.
- `Web/permissions.html` - permissions page. **Critical**.
- `Web/thresholds.html` - threshold page. **Critical**.
- `Web/mailbox.html` - single-mailbox detail page. **Critical**.
- `Web/validate.html` - standalone validation page. **Important**.
- `Web/dashboard.js` - all client-side app logic. **Critical**.
- `Web/styles.css` - all dashboard styling. **Critical**.
- `Web/HTTPServer.ps1` - local static file server. **Critical** for local browsing.
- `Web/data.json` - latest snapshot for the dashboard. **Generated; recreatable**.
- `Web/history.json` - historical mailbox data. **Generated; recreatable**.
- `Web/theme/*.jsonc` - runtime dashboard themes. **Important**; delete only if you are intentionally dropping themes.
- `Web/*.old.*`, `Web/*Copy*`, `Web/*.orig*`, `Web/.tmp`, `Web/*.log` - backups/scratch/transcripts. **Safe to delete**.

### Mailboxes/

- `Mailboxes/mailboxes.csv` - source mailbox list for collection. **Critical input**.
- `Mailboxes/FILESTRUCTURE.txt` - reference only. **Optional**.

## Data and schema conventions

- Treat `ExchangeGuid` as the durable mailbox key. SMTP addresses can change.
- Keep `history.json` in the nested shape already used by the dashboard:
  `MailboxHistory[] -> Samples[]`
- Keep `data.json` as the latest-snapshot file used for the current dashboard view.
- When changing collector output, validate both the generated JSON and the dashboard reader together.
- Preserve backward-compatible field normalization in `Web/dashboard.js`; it intentionally accepts multiple property-name variants.

## PowerShell conventions

- Keep scripts compatible with the repo’s PowerShell runtime.
- Avoid relying on PS7-only syntax when a PS5-compatible equivalent exists.
- Prefer explicit null checks over `??` when writing collector code that must run broadly.
- Keep the collector flow consistent:
  - `Register-EntraApp.ps1` for app setup
  - `Get-ExchangeOnlineAccessToken.ps1` for auth
  - `Start-HistoryCollectorThreaded.ps1` / `HistoryCollector.ps1` for collection
  - `MergeJSON.ps1` or `Extract-HotData.ps1` for regeneration

## Web UI conventions

- The dashboard is a static app with multiple views:
  `index.html`, `history.html`, `permissions.html`, `thresholds.html`, `mailbox.html`, and `validate.html`.
- Preserve the `mailbox` query-string parameter when navigating between pages.
- Search is designed for large mailbox sets; keep ranking, selection, and drill-down behavior intact.
- Table pages use shared pagination and export controls; keep the 10/20/50/100 page-size pattern consistent.
- `Web/theme/*.jsonc` are runtime dashboard themes, not editor themes. Load them as app data and map theme tokens to CSS variables.

## Useful parameters

### `Collector/Register-EntraApp.ps1`

- `-ConfigPath` - alternate config file path.
- `-TenantIdOrDomain` - target tenant.
- `-AppId` - update an existing app registration.
- `-DisplayName` - app display name.
- `-RedirectUri` - loopback redirect URI.
- `-CreateIfMissing`
- `-NoConfigUpdate`
- supports `-WhatIf` / `-Confirm`

Example:

```powershell
pwsh -File .\Collector\Register-EntraApp.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json -DisplayName "MailboxDashboard Collector" -WhatIf
```

### `Collector/Get-ExchangeOnlineAccessToken.ps1`

- `-ConfigPath`
- `-UserPrincipalName`
- `-ClientId`
- `-TenantIdOrDomain`
- `-ClientSecret`
- `-RedirectUri`
- `-TimeoutSeconds`
- `-AuthenticationMode Delegated|AppOnly|Auto`

Example:

```powershell
pwsh -File .\Collector\Get-ExchangeOnlineAccessToken.ps1 -UserPrincipalName admin@tenant.onmicrosoft.com -AuthenticationMode Delegated
```

### `Collector/Start-HistoryCollectorThreaded.ps1`

- `-ConfigPath`
- `-BatchSize`
- `-CsvPath`
- `-HistoryJsonPath`
- `-HotDataJsonPath`
- `-TimestampUtc`

Example:

```powershell
pwsh -File .\Collector\Start-HistoryCollectorThreaded.ps1 -UserPrincipalName admin@tenant.onmicrosoft.com -BatchSize 100
```

### `Collector/HistoryCollector.ps1`

- same path overrides as above, plus `-BatchSize`

Example:

```powershell
pwsh -File .\Collector\HistoryCollector.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json -BatchSize 50
```

### `Collector/MergeJSON.ps1`

- `-TempDir`
- `-HistoryPath`
- `-HotDataPath`

### `Collector/Extract-HotData.ps1`

- `-HistoryPath`
- `-HotDataPath`

### `Web/HTTPServer.ps1`

- `-RootPath`
- `-Prefix`

Example:

```powershell
pwsh -File .\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8080/
```

## Troubleshooting

- If the dashboard is empty, check that both `Web/history.json` and `Web/data.json` were regenerated from the latest collector run.
- If history looks right but the overview is wrong, verify `Extract-HotData.ps1` or `MergeJSON.ps1` output the expected `data.json` schema.
- If app registration or token creation fails, check `Collector/Config/dashboardConfig.json` for `Organization`, `AppID`, `ClientSecret`, and `UserPrincipalName`.
- If local browsing returns 404s, make sure `Web/HTTPServer.ps1` is running and that you are using `http://localhost:8080/`.
- If collector output is missing permissions, verify the collector wrote `Permissions` into `history.json` before regenerating `data.json`.
- If threaded collection fails, inspect `Collector/Temp/ThreadJobs/` and rerun merge/regeneration after fixing the failed batch.
- If a theme does not appear, confirm the file exists under `Web/theme/` and contains valid JSONC with a `type` and `colors`.

## Validation expectations

- Prefer the smallest targeted validation that covers the changed area.
- For JSON or collector changes, verify the generated file and then check the dashboard page that consumes it.
- For web changes, validate in the browser against `http://localhost:8080/` rather than assuming a file-only edit is enough.
