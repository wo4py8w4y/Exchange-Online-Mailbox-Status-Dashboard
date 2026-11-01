# Copilot instructions for MailboxDashboard

## Project scope

MailboxDashboard is a PowerShell + static-web project for Exchange Online mailbox monitoring. The repo deliberately separates data collection from presentation:

- `Collector/` authenticates to Exchange Online, reads mailbox data, writes JSON history/snapshots, and validates the generated payloads.
- `Web/` is a static dashboard built from `history.json` and `data.json` plus HTML/JS/CSS. It is intended to run locally or behind IIS.
- `Mailboxes/` provides the source mailbox list (`mailboxes.csv`).

The main data flow is:

`Exchange Online -> Collector scripts -> Web/history.json -> Collector/Generate-MailboxSnapshot.ps1 -> Web/data.json -> Web/*.html + dashboard.js`

## Build, test, and validation commands

This repo does not have a formal npm/pytest/Gradle build system. Use the PowerShell scripts and the validator that already exist.

- Validate JSON files without writing changes:
  `pwsh -File .\Collector\Test-MailboxDashboardJSON.ps1`
- Validate only the history payload:
  `pwsh -File .\Collector\Test-MailboxDashboardJSON.ps1 -Target History`
- Repair recoverable JSON issues and keep the backup files:
  `pwsh -File .\Collector\Test-MailboxDashboardJSON.ps1 -Repair -Cull`
- Run the full collection pipeline against generated sample data without touching Exchange:
  `pwsh -File .\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData`
- Start the local dashboard server:
  `pwsh -File .\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8080/`

When a change affects collector output or web rendering, do the smallest targeted validation that covers both layers: validate the generated JSON, then open the relevant dashboard page in the browser.

## High-level architecture

- `Collector/Config/dashboardConfig.json` is the source of truth for tenant settings and output paths. Paths are relative to `Collector/`.
- `Mailboxes/mailboxes.csv` is the input list; supported headers include `PrimarySMTPAddress`, `Mailbox`, `EmailAddress`, and `UserPrincipalName`.
- `Collector/Invoke-MailboxDashboardCollection.ps1` is the orchestration script for the full pipeline: auth -> collection -> merge -> validate -> snapshot -> validate.
- `Collect-ExchangeOnlineMailboxes.ps1` writes mailbox samples; `Merge-CollectionResults.ps1` combines parallel worker output; `Generate-MailboxSnapshot.ps1` rebuilds `Web/data.json` from `Web/history.json`.
- `Web/dashboard.js` is the app logic for rendering the static dashboard; it intentionally normalizes multiple field-name variants to stay backward-compatible.
- `Web/validate.html` is the standalone sanity-check page for schema and data checks. Use it when testing data changes.

## Key conventions and repo-specific patterns

- Treat `ExchangeGuid` as the durable mailbox key. Mailbox SMTP addresses are not stable identifiers; renamed mailboxes must retain history through the GUID.
- Keep `history.json` and `data.json` in the shapes the dashboard expects, not a “cleaned-up” schema that breaks the browser code.
- Prefer PS 5.1-compatible syntax when possible; avoid relying on PS7-only constructs in collector scripts unless a newer feature is required.
- Preserve the established collector flow: register app, acquire token, collect, merge or regenerate snapshot, validate JSON.
- Keep config values relative to the `Collector` folder so the repo works from any clone location. Do not hardcode local absolute paths into scripts.
- `Microsoft.Graph.Authentication` must load before `ExchangeOnlineManagement`; import order matters for auth compatibility.
- `Web/theme/*.jsonc` are dashboard runtime themes, not editor settings. Keep them valid JSONC and map their tokens to CSS variables in the app.
- Preserve `mailbox` query-string behavior when moving between pages (`index.html`, `mailbox.html`, `history.html`, etc.).

## Existing repo guidance to keep

- `Readme.md` is the main operational reference for quick start, setup, and deployment.
- `Collector/Initialize-MailboxDashboard.ps1` is the setup/bootstrap script and is safe to rerun when you need to regenerate configuration or create the mailbox template.
- `Collector/Test-MailboxDashboardJSON.ps1` is the repo’s first line of defense for broken collection output; use it before assuming a JSON change is safe.
- `Web/HTTPServer.ps1` is the local browsing path when validating UI changes.
- `Collector/Temp/` contains disposable worker output and cache files; it is safe to clean if collection artifacts are stale.

## When editing this repo

- Validate the smallest relevant script or data path instead of broad “everything works” checks.
- If you touch JSON output, verify both the raw data file and the page that consumes it.
- If you touch the web UI, test via the local static server rather than inspecting the raw HTML alone.
- If you alter authentication or configuration behavior, check `Collector/Config/dashboardConfig.json` semantics before changing script defaults.

## MCP server configuration

If you want to add browser automation for UI validation, consider Playwright for smoke tests around the local `HTTPServer.ps1` flow.
