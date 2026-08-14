# MailboxDashboard

Exchange Online mailbox monitoring with a PowerShell collector pipeline and a static web dashboard.

## Overview

MailboxDashboard collects mailbox usage, quota, archive, and permission data from Exchange Online and publishes two JSON files for the dashboard:

- `Web/history.json` - historical mailbox samples
- `Web/data.json` - latest mailbox snapshot used by the web UI

Recommended data flow:

1. Exchange Online
2. `Collector/Start-HistoryCollectorThreaded.ps1`
3. `Collector/MergeJSON.ps1`
4. `Collector/Extract-HotData.ps1`
5. `Web/history.json`
6. `Web/data.json`
7. `Web/*.html` + `Web/dashboard.js`

## Repository layout

- `Collector/` - Exchange Online collection, merge, auth, and configuration scripts
- `Web/` - static dashboard pages, styles, themes, and local HTTP server
- `Mailboxes/` - mailbox input CSV

Key files:

- `Collector/Config/dashboardConfig.json`
- `Collector/Register-EntraApp.ps1`
- `Collector/Get-ExchangeOnlineAccessToken.ps1`
- `Collector/HistoryCollector.ps1`
- `Collector/Start-HistoryCollectorThreaded.ps1`
- `Collector/MergeJSON.ps1`
- `Collector/Extract-HotData.ps1`
- `Collector/Update-MailboxDashboard.ps1`
- `Web/dashboard.js`
- `Web/index.html`
- `Web/mailbox.html`
- `Web/history.html`
- `Web/permissions.html`
- `Web/thresholds.html`
- `Web/validate.html`
- `Web/HTTPServer.ps1`

## Prerequisites

- Windows with PowerShell 7+
- Exchange Online admin access
- Permission to create or update an Entra app registration
- IIS or another static web host if deploying beyond local testing

Install required modules:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.PowerShell.ThreadJob -Scope CurrentUser
```

## 1. Clone the repository

```powershell
git clone <your-repo-url> C:\Deploy\MailboxDashboard
Set-Location C:\Deploy\MailboxDashboard
```

## 2. Configure the collector

Update `Collector/Config/dashboardConfig.json` with your tenant and path settings.

Required settings:

- `Organization`
- `AppID`
- `ClientSecret`
- `UserPrincipalName`
- `MailboxesCsvPath`
- `HistoryJsonPath`
- `HotDataJsonPath`

Do not commit real secrets back to the repository.

## 3. Prepare the mailbox list

Populate `Mailboxes/mailboxes.csv` with the mailboxes you want to collect.

Required column for the current scripts:

- `PrimarySMTPAddress` for `HistoryCollector.ps1`
- `Mailbox` for `Update-MailboxDashboard.ps1`

If you standardize on one collector path, keep the CSV header aligned with that script.

## 4. Create or repair the Entra app

Run:

```powershell
pwsh -File .\Collector\Register-EntraApp.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json
```

This updates the local collector configuration and prepares delegated Exchange Online access for the recommended threaded flow.

## 5. Recommended full data build

The recommended production path is the threaded historical collector plus regeneration.

### 5.1 Run the threaded collector

```powershell
pwsh -File .\Collector\Start-HistoryCollectorThreaded.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json
```

This will:

- authenticate to Exchange Online
- split the mailbox list into batches
- collect mailbox metrics in parallel
- write worker output under `Collector/Temp/`

### 5.2 Merge worker output and rebuild hot data

If the threaded launcher does not already complete this step in your environment, run:

```powershell
pwsh -File .\Collector\MergeJSON.ps1 -TempDir .\Collector\Temp\ThreadJobs -HistoryPath .\Web\history.json -HotDataPath .\Web\data.json
pwsh -File .\Collector\Extract-HotData.ps1 -HistoryPath .\Web\history.json -HotDataPath .\Web\data.json
```

### 5.3 Alternative single-process run

For smaller runs or troubleshooting:

```powershell
Connect-ExchangeOnline
pwsh -File .\Collector\HistoryCollector.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json
```

### 5.4 Legacy all-in-one collector

The repository also contains:

```powershell
pwsh -File .\Collector\Update-MailboxDashboard.ps1
```

Use this only when you specifically want the legacy orchestrator path. The threaded history-first pipeline is the preferred deployment flow.

## 6. Deploy the web site

### Option A: Full repo deployment script

Use the deployment helper to copy the repo's deployable content to a target root such as `F:\Website\Qbuild-Mon`.

```powershell
pwsh -File .\Deploy-MailboxDashboard.ps1
```

If you already know the target root, you can pass it directly:

```powershell
pwsh -File .\Deploy-MailboxDashboard.ps1 -DestinationRoot F:\Website\Qbuild-Mon
```

The script:

- prompts for the deployment root when `-DestinationRoot` is omitted
- preserves the repository folder structure under the target root
- copies updated files only
- best-effort merges live destination `Web\data.json` and `Web\history.json` with the repository copies by mailbox record before writing them
- excludes `.git`, `.github`, `.vs`, `Collector\Temp`, `Collector\Logs`, and web backup or scratch files

For JSON merge behavior:

- mailbox records are matched by `ExchangeGuid` first and SMTP address second
- `history.json` samples are merged by timestamp when possible
- newer payloads are preferred when the repository and destination both contain the same mailbox
- missing fields are backfilled from the other copy on a best-effort basis
- if a JSON merge fails, the script warns and falls back to the normal file copy behavior

Use `-WhatIf` for a dry run:

```powershell
pwsh -File .\Deploy-MailboxDashboard.ps1 -DestinationRoot F:\Website\Qbuild-Mon -WhatIf
```

### Option B: Local static server

```powershell
pwsh -File .\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8080/
```

Open:

- `http://localhost:8080/`
- `http://localhost:8080/validate.html`

### Option C: IIS deployment

Copy the `Web/` folder contents to your IIS site root, for example:

```powershell
Copy-Item .\Web\* F:\Website\Qbuild-Mon\Web -Recurse -Force
```

Confirm the deployed site includes:

- `index.html`
- `mailbox.html`
- `history.html`
- `permissions.html`
- `thresholds.html`
- `validate.html`
- `dashboard.js`
- `styles.css`
- `data.json`
- `history.json`
- `theme\*.jsonc`

## 7. Validate the deployment

### 7.1 Browser validation

Open `validate.html` on the deployed site and confirm:

- page availability checks pass
- `data.json` and `history.json` load
- schema checks pass
- theme files parse
- `dashboard.js` syntax check passes

### 7.2 Manual spot checks

Verify that:

- dashboard totals are non-zero for known active mailboxes
- mailbox detail pages match current storage values
- history tables show the same latest sample as current cards
- thresholds show the same usage percentages as mailbox detail pages
- archive storage values are consistent across overview and mailbox pages

## 8. Typical update workflow from git

On an existing deployment host:

```powershell
Set-Location C:\Deploy\MailboxDashboard
git pull
pwsh -File .\Collector\Start-HistoryCollectorThreaded.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json
pwsh -File .\Collector\Extract-HotData.ps1 -HistoryPath .\Web\history.json -HotDataPath .\Web\data.json
pwsh -File .\Deploy-MailboxDashboard.ps1 -DestinationRoot F:\Website\Qbuild-Mon
```

Then reload:

- the dashboard home page
- one mailbox details page
- `validate.html`

## 9. Troubleshooting

### Dashboard shows `0.00 GB`

Check:

- `Web/data.json` contains the expected current values
- `Web/history.json` contains the latest sample
- the deployed `Web/dashboard.js` matches the repository version
- the site was refreshed after deployment

### History looks correct but overview or mailbox pages do not

Check:

- `Extract-HotData.ps1` regenerated `data.json`
- the deployed `dashboard.js` supports the current payload shape

### Archive values differ across pages

Check:

- latest history samples contain `ArchiveSizeGB`
- `data.json` contains archive values for the mailbox
- the collector path being used is not mixing stale deployed files with newly generated JSON

### A mailbox disappeared from history

Check:

- whether the collector run failed for that mailbox
- whether the mailbox identity changed
- whether an older `history.json` was copied over the new one

## 10. Recommended operating model

For the most stable results:

1. Keep `ExchangeGuid` as the durable mailbox key
2. Use the threaded historical collector as the primary ingestion path
3. Regenerate `data.json` from `history.json`
4. Deploy both JSON files with the current web assets
5. Use `validate.html` after every release
