# Copilot Instructions for MailboxDashboard

## Project shape

MailboxDashboard is an Exchange Online mailbox monitoring app with a PowerShell collector
pipeline and a static web dashboard.

- `Collector/` authenticates, collects mailbox samples, validates JSON, and creates the current snapshot.
- `Web/` serves the dashboard, charts, mailbox detail views, validation page, themes, scopes, and generated JSON.
- The normal flow is:
  `Initialize-MailboxDashboard.ps1 -> Invoke-MailboxDashboardCollection.ps1 -> history.json -> data.json -> Web UI`

## Current files

- `Readme.md` - primary operator and architecture guide.
- `Collector/Config/dashboardConfig.json` - local configuration; never commit it.
- `Collector/Config/dashboardConfig.example.json` - safe configuration template.
- `Collector/Initialize-MailboxDashboard.ps1` - first-run setup.
- `Collector/Register-EntraApp.ps1` - Entra app registration helper.
- `Collector/Invoke-MailboxDashboardAuth.ps1` - authentication selection and Exchange connection.
- `Collector/Invoke-MailboxDashboardCollection.ps1` - current end-to-end collection pipeline.
- `Collector/Collect-ExchangeOnlineMailboxes.ps1` - current mailbox collector.
- `Collector/Merge-CollectionResults.ps1` - merges `-Parallel` worker output.
- `Collector/Generate-MailboxSnapshot.ps1` - rebuilds `data.json` from `history.json`.
- `Collector/Test-MailboxDashboardJSON.ps1` - validates, repairs, and culls generated data.
- `Collector/New-MailboxDashboardTestData.ps1` - synthetic data generator.
- `Collector/Modules/` - shared configuration, JSON, path, console, and logging helpers.
- `Collector/Legacy/` - superseded scripts and archived documentation. Do not use it for new work.

## Data conventions

- Treat `ExchangeGuid` as the durable mailbox key. SMTP addresses can change.
- Keep `history.json` in the nested `MailboxHistory[] -> Samples[]` shape.
- Keep `data.json` as the latest-snapshot file consumed by the current dashboard.
- When changing collector output, validate both generated JSON files and the dashboard reader.
- Preserve backward-compatible field normalization in `Web/dashboard.js`.

## PowerShell conventions

- Keep scripts compatible with the repository's supported PowerShell runtime.
- Use explicit null checks where broad PowerShell compatibility matters.
- Resolve configured paths through `MailboxDashboard.Config.psm1`; do not add hardcoded repository paths.
- Use `Invoke-MailboxDashboardCollection.ps1` for the full flow. Collection is sequential by default.
- Use `-Parallel` only with certificate or client-secret authentication. `-ThrottleLimit` controls worker count and defaults to `Collection.ThreadCount`.
- Use `Merge-CollectionResults.ps1` for worker output and `Generate-MailboxSnapshot.ps1` to rebuild `data.json`.
- Update operator documentation when a command, configuration field, or workflow changes.
- Keep console progress and failure/export logging consistent with the shared common module.

## Configuration

Paths in `dashboardConfig.json` are resolved relative to `Collector/`. Preserve the current
sections: `Authentication`, `Paths`, `Collection`, `Thresholds`, `Validation`, `Logging`,
and `Console`. Legacy root-level path names remain supported by the config loader for
existing installations.

## Useful commands

```powershell
.\Collector\Initialize-MailboxDashboard.ps1
.\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData
.\Collector\Invoke-MailboxDashboardCollection.ps1 -Parallel -ThrottleLimit 8
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair -Cull
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair -RestoreSamplesFromData
.\Collector\Generate-MailboxSnapshot.ps1
.\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8888/
```

## Web conventions

- Preserve the `mailbox` query-string parameter when navigating between pages.
- Preserve search ranking, selection, filtering, sorting, scope, and drill-down behavior.
- Table pages use the shared 10/20/50/100 page-size pattern and export controls.
- `Web/theme/*.jsonc` are runtime dashboard themes, not editor themes.
- Validate web changes in a browser against `http://localhost:8888/`.

## Troubleshooting

- If the dashboard is empty, check `Web/history.json` and `Web/data.json`, then run the snapshot generator and validator.
- If history is correct but the overview is stale, run `Generate-MailboxSnapshot.ps1`.
- If authentication fails, check `Organization`, `AppID`, and the selected authentication mode.
- If parallel collection fails, inspect `Collector/Temp/ThreadJobs/` and the failure log.
- If local browsing returns 404, confirm `HTTPServer.ps1` serves `Web` and the URL uses port `8888`.
- If a theme does not appear, confirm its file exists under `Web/theme/` and contains valid JSONC.

## Validation

Prefer the smallest targeted check for the changed area. For collector or JSON changes, run
`Test-MailboxDashboardJSON.ps1` and verify the dashboard page that consumes the data. Do not
edit generated JSON as a substitute for fixing the collector or snapshot path.
