# MailboxDashboard

Exchange Online mailbox monitoring: a PowerShell collector pipeline that gathers mailbox
size, quota, archive and permission data, and a static web dashboard that reports on it.

---

## Contents

- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Installation](#installation)
- [Setup walkthrough](#setup-walkthrough)
- [Configuration](#configuration)
- [Running a collection](#running-a-collection)
- [Validating and repairing data](#validating-and-repairing-data)
- [Test data](#test-data)
- [The web dashboard](#the-web-dashboard)
- [Mailbox scopes](#mailbox-scopes)
- [Themes](#themes)
- [Scheduling](#scheduling)
- [Deployment](#deployment)
- [Logging](#logging)
- [Git and secrets](#git-and-secrets)
- [Script reference](#script-reference)
- [Troubleshooting](#troubleshooting)

---

## How it works

```
Exchange Online
      |
      v
Collect-ExchangeOnlineMailboxes.ps1     one sample per mailbox, per run
      |
      v
Merge-CollectionResults.ps1             only when collecting in parallel
      |
      v
Web/history.json                        every sample ever collected
      |
      v
Generate-MailboxSnapshot.ps1            newest sample per mailbox
      |
      v
Web/data.json                           what the dashboard reads
      |
      v
Web/*.html + dashboard.js
```

`Invoke-MailboxDashboardCollection.ps1` runs that whole chain for you. Every step is also
a standalone script you can run on its own.

**ExchangeGuid is the mailbox key.** SMTP addresses change; the GUID does not. Everything —
history merging, snapshot generation, and the dashboard's own lookups — is keyed on it, so
a renamed mailbox keeps its history instead of splitting into two records.

---

## Quick start

```powershell
git clone <your-repo-url> C:\Deploy\MailboxDashboard
Set-Location C:\Deploy\MailboxDashboard

# 1. Set up (creates config, folders, mailbox list template)
.\Collector\Initialize-MailboxDashboard.ps1

# 2. See the dashboard working before touching Exchange
.\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData

# 3. Browse it
.\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8888/

# 4. When you are ready, collect for real
.\Collector\Invoke-MailboxDashboardCollection.ps1
```

---

## Installation
*TLDR ? Just go to [./Collector/Setup-Walkthough.md](https://github.com/wo4py8w4y/MailboxDashboard/blob/main/Collector/Setup-Walkthrough.md)*


### Prerequisites

- Windows with PowerShell 5.1 or later (PowerShell 7 recommended)
- An Exchange Online administrator account
- Permission to create or update an Entra app registration
- IIS or another static host if you are publishing beyond localhost

### Modules

```powershell
Install-Module ExchangeOnlineManagement       -Scope CurrentUser   # required
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # interactive sign-in
Install-Module graph.auth.lite                -Scope CurrentUser   # interactive OAuth/PKCE
Install-Module Microsoft.PowerShell.ThreadJob -Scope CurrentUser   # parallel collection
```

Only `ExchangeOnlineManagement` is mandatory. `Initialize-MailboxDashboard.ps1` reports
which of the others are missing and what each is needed for.

> **Import order matters.** `Microsoft.Graph.Authentication` must load *before*
> `ExchangeOnlineManagement`, or the two disagree over the `Microsoft.Identity` assembly
> version. The scripts already do this; keep the order if you write your own.

### Setup

```powershell
.\Collector\Initialize-MailboxDashboard.ps1
```

It checks prerequisites, creates the folder structure, writes
`Collector/Config/dashboardConfig.json` from the shipped example, prompts for your tenant
details, and creates a mailbox list template. It is safe to re-run — nothing is overwritten
unless you pass `-Force`.

Unattended:

```powershell
.\Collector\Initialize-MailboxDashboard.ps1 `
    -Organization contoso.onmicrosoft.com `
    -AppId 00000000-0000-0000-0000-000000000000 `
    -AuthenticationMode Certificate `
    -Unattended
```

### Entra app registration

```powershell
.\Collector\Register-EntraApp.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json
```

Or let the setup wizard do it with `-RegisterEntraApp`.

### Setup walkthrough

For a step-by-step first installation, see
[`Collector/Setup-Walkthrough.md`](Collector/Setup-Walkthrough.md). It covers setup,
authentication choices, test data, a real collection, validation, and local hosting.

---

## Configuration

Everything lives in `Collector/Config/dashboardConfig.json`. A template with placeholder
values ships as `dashboardConfig.example.json`.

**All paths are relative to the `Collector` folder**, so the same configuration works on
any machine regardless of where the repository is cloned.

```jsonc
{
  "Version": "2.0",

  "Organization": "contoso.onmicrosoft.com",   // tenant ID or primary domain
  "AppID": "00000000-...",                     // Entra application (client) ID
  "ClientSecret": "",                          // app-only secret
  "Thumbprint": "",                            // or a certificate thumbprint
  "UserPrincipalName": "admin@contoso.com",

  "Authentication": {
    "Mode": "Auto"                             // Certificate | Interactive | Delegated | Auto
  },

  "Paths": {
    "MailboxesCsv":        "..\\Mailboxes\\mailboxes.csv",
    "HistoryJson":         "..\\Web\\history.json",
    "DataJson":            "..\\Web\\data.json",
    "DemoDataJson":        "..\\Web\\demo-data.json",
    "DemoHistoryJson":     "..\\Web\\demo-history.json",
    "TempDirectory":       ".\\Temp",
    "ThreadJobsDirectory": ".\\Temp\\ThreadJobs",
    "LogDirectory":        ".\\Logs"
  },

  "Collection": {
    "BatchSize":         50,      // commit progress to disk every N mailboxes
    "MaxHistorySamples": 365,     // samples retained per mailbox
    "UseThreading":      true,     // legacy/default preference; use -Parallel to opt in
    "ThreadCount":       10
  },

  "Thresholds": {
    "CriticalPercent": 94.0,
    "WarningPercent":  85.0
  },

  "Validation": {
    "PreValidateCsv":     true,
    "PostValidateJson":   true,
    "AutoRepairErrors":   false,
    "CullInvalidRecords": true
  },

  "Logging": {
    "Enabled":          true,
    "LogFile":          ".\\Logs\\failures.log",
    "ExportAuditFile":  ".\\Logs\\exports.log",
    "IncludeVariables": true
  },

  "Console": {
    "ShowProgress": true,
    "UseColour":    true,   // set false for scheduled tasks
    "ShowPerItem":  true,   // false prints every ItemInterval-th mailbox instead
    "ItemInterval": 25
  }
}
```

The orchestrator collects sequentially unless `-Parallel` is supplied. When parallel
collection is enabled, `ThreadCount` supplies the default worker count and
`-ThrottleLimit` can override it. Configurations from the previous version still load — old root-level keys such as
`HistoryJsonPath` and `MailboxesCsvPath` are mapped onto the new `Paths` section
automatically.

### Mailbox list

Put the mailboxes to collect in `Mailboxes/mailboxes.csv`:

```csv
PrimarySMTPAddress
first.mailbox@contoso.com
second.mailbox@contoso.com
```

`PrimarySMTPAddress`, `Mailbox`, `EmailAddress` and `UserPrincipalName` are all accepted as
the column name.

### Authentication modes

| Mode | Needs | Use it for |
|---|---|---|
| `Certificate` | `AppID` + `ClientSecret` or `Thumbprint` | Scheduled tasks, parallel collection |
| `Interactive` | `AppID` + `graph.auth.lite` | Manual runs; opens a browser sign-in |
| `Delegated` | `UserPrincipalName` | An admin session that is already signed in |
| `Auto` | — | Shows a menu at the start of each run |

`Auto` prints:

```
  +------------------------------------+
  |  MailboxDashboard Authentication   |
  +------------------------------------+
  |  1) Certificate (app-only)         |
  |  2) Interactive (OAuth / PKCE)     |
  |  3) Delegated (user sign-in)       |
  |  Q) Quit                           |
  +------------------------------------+
```

Options the configuration cannot support are greyed out with the reason.

> Interactive sign-in uses the Windows Web Account Manager. **The sign-in window can open
> behind an embedded terminal** — if a run appears to hang at "Authenticating", check
> behind your editor window.

Set `Authentication.Mode` to a specific value for unattended runs so no menu appears.

---

## Running a collection

### The whole pipeline

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1
```

Runs: authenticate → collect → validate history → generate snapshot → validate snapshot,
then prints a per-step summary with timings.

| Parameter | Effect |
|---|---|
| `-AuthenticationMode <mode>` | Override the configured mode for this run |
| `-Parallel` | Split the mailbox list across worker threads |
| `-ThrottleLimit <n>` | Worker count (default: `Collection.ThreadCount`) |
| `-BatchSize <n>` | Commit progress every N mailboxes |
| `-Identity <addresses>` | Collect only these mailboxes |
| `-TestData` | Build from generated data; never contacts Exchange |
| `-Repair` | Let validation fix and cull bad records |
| `-SkipValidation` | Skip both validation passes |
| `-KeepWorkerFiles` | Do not delete worker output after merging |

### Parallel collection

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1 -Parallel -ThrottleLimit 8
```

Each worker opens its own app-only Exchange Online session, so **parallel collection
requires certificate or client-secret authentication**. Interactive would prompt once per
worker, so the orchestrator refuses that combination rather than half-working.

Workers write to `Collector/Temp/ThreadJobs/worker-NN.json` and never touch `history.json`
directly; `Merge-CollectionResults.ps1` combines them afterwards. If a worker dies, its
slice is missing but every other slice still merges.

### Individual steps

```powershell
# Collect only
.\Collector\Collect-ExchangeOnlineMailboxes.ps1 -Connect

# One mailbox
.\Collector\Collect-ExchangeOnlineMailboxes.ps1 -Identity user@contoso.com -Connect

# Merge worker output into history
.\Collector\Merge-CollectionResults.ps1

# Rebuild data.json from history.json
.\Collector\Generate-MailboxSnapshot.ps1
```

`Generate-MailboxSnapshot.ps1` is safe to run at any time — it only re-reads history, so it
is the quickest way to refresh the dashboard after editing or repairing history data.

---

## Validating and repairing data

```powershell
# Report only - changes nothing
.\Collector\Test-MailboxDashboardJSON.ps1

# Fix what can be fixed, backing up first
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair

# Also remove records that cannot be fixed
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair -Cull

# Fail the run if anything is wrong - for scheduled tasks
.\Collector\Test-MailboxDashboardJSON.ps1 -Strict
```

**Detected:** missing or malformed `ExchangeGuid`, duplicate mailboxes, duplicate sample
timestamps, unparseable dates, missing or non-numeric values, negative values, quota of
zero, usage that disagrees with size ÷ quota, and mailboxes with no samples.

**Repaired:** numeric strings converted to numbers, negatives clamped to zero, usage
recalculated, timestamps normalised to ISO 8601, booleans coerced, empty display names
filled from the address, samples sorted and trimmed to `MaxHistorySamples`.

**Culled** (with `-Cull`): records with no usable GUID, duplicates, unparseable timestamps,
zero quota, and records left with no samples.

Every repair writes `<file>.bak` first unless you pass `-NoBackup`.

Two things are deliberately **not** treated as errors:

- **A mailbox over its quota.** 156% usage is a real and important finding, so it is
  reported as a warning and the value is never clamped.
- **An unlimited quota.** Stored as `null`, which is a real state, not a fault.

`-Strict` exits with code 1 when anything is wrong, so a scheduled task can stop before
publishing bad data.

---

## Test data

Exercise the entire dashboard without an Exchange connection:

```powershell
# Write demo files, leaving real data alone
.\Collector\New-MailboxDashboardTestData.ps1

# 500 mailboxes, 90 days of history
.\Collector\New-MailboxDashboardTestData.ps1 -MailboxCount 500 -Days 90

# Overwrite the real dashboard files
.\Collector\New-MailboxDashboardTestData.ps1 -Live
```

The generated tenant deliberately contains healthy, warning, critical, over-quota,
unlimited-quota and dormant mailboxes, with archives, delegates and believable growth
trends, so every chart and table has something to show. `-Seed` makes a run reproducible.

To build the dashboard end to end without Exchange:

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData
```

> `-TestData` and `-Live` **overwrite `Web/history.json` and `Web/data.json`**. Back them up
> first if they hold collected data you care about.

---

## The web dashboard

```powershell
.\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8888/
```

| Page | Shows |
|---|---|
| `index.html` | Overview: totals, charts, full mailbox table |
| `scope.html` | The same overview limited to one scope |
| `mailbox.html` | One mailbox: metrics, history, delegates |
| `history.html` | Historical storage and utilisation |
| `permissions.html` | Delegate permissions across mailboxes |
| `thresholds.html` | Mailboxes at or above the warning threshold |
| `validate.html` | Standalone data validation view |

### Finding and sorting

Every table has a filter box supporting `*` and `?` wildcards. Without wildcards it is a
plain substring search.

| Query | Matches |
|---|---|
| `payroll` | anything containing "payroll" |
| `*payroll*` | the same, explicitly |
| `qbuild*` | display name or address starting with "qbuild" |
| `*@chde.qld.gov.au` | everything in that domain |
| `finance?@contoso.com` | `finance1@`, `financeX@` — exactly one character |

Matching covers display name, SMTP address and ExchangeGuid. On the permissions page it
also matches the delegate, so `*@contoso.com` finds every mailbox a delegate has rights on.

Click any column heading to sort; click again to reverse. Text columns start A→Z, numbers
and dates start highest-first. Empty values always sort last so "N/A" rows never crowd out
real data.

**The filter, sort and scope travel with you.** They are held in the URL and written into
every navigation link, so moving from the overview to Permissions keeps your result set —
and any filtered view is a shareable link:

```
index.html?scope=hpw&q=qbuild*&sort=usagePercent&dir=desc
```

---

## Mailbox scopes

A scope is a saved filter that lets different teams or sites see only their own mailboxes,
from the same dataset. Scopes are defined in `Web/scopes.json`:

```jsonc
{
  "defaultScope": "all",
  "scopes": [
    { "id": "all", "name": "All Mailboxes", "rules": {} },

    {
      "id": "brisbane",
      "name": "Brisbane Site",
      "description": "Mailboxes owned by the Brisbane office.",
      "rules": {
        "includeSmtp":        ["*@brisbane.contoso.com", "reception.bne@*"],
        "includeDisplayName": ["*Brisbane*"],
        "includeGuids":       ["9a15e38d-3f07-497a-ac97-33cea1eadb90"],
        "excludeSmtp":        ["*test*"],
        "minSizeGB":          0,
        "minUsagePercent":    0
      }
    }
  ]
}
```

| Rule | Meaning |
|---|---|
| `includeGuids` | Exact ExchangeGuid values — the most durable way to pin a list |
| `includeSmtp` | Address patterns; `*` and `?` wildcards, or `re:` for a regex |
| `includeDisplayName` | Display-name patterns, same wildcard rules |
| `excludeSmtp` / `excludeDisplayName` | Applied after includes; excludes always win |
| `minSizeGB` | Only mailboxes at or above this primary size |
| `minUsagePercent` | Only mailboxes at or above this quota usage |

A scope with no include rules matches everything. Matching is case-insensitive.

### Giving a team their own report

**A shared link** — `scope.html?scope=brisbane`. The scope picker stays visible so they can
switch.

**A dedicated page** — copy `scope.html` to `site-brisbane.html` and pin the scope on the
body tag:

```html
<body data-page="overview" data-scope="brisbane">
```

A pinned page has a clean URL and **no scope picker**, so the recipient only ever sees their
own mailboxes. Change the `<h1>` to name the report and you are done.

> Scopes are a presentation filter, not a security boundary. The browser still downloads the
> full `data.json`. If a team must not see other mailboxes at all, publish them a separate
> site with its own data files.

---

## Themes

The theme picker is in the header of every page. Themes are defined in
`Web/theme/themes.json` — one file, plain colours, no build step:

```jsonc
{
  "themes": [
    {
      "id": "cyberpunk",
      "name": "Cyberpunk",
      "type": "dark",
      "colors": {
        "bg": "#0a0118",           "panel": "#150b2e",         "panelAlt": "#1f1145",
        "textPrimary": "#f2e9ff",  "textSecondary": "#a98bfa", "border": "#3d2170",
        "headerFrom": "#ff007a",   "headerTo": "#7c3aed",      "headerText": "#ffffff",
        "navLink": "#22d3ee",      "navLinkHover": "#7df9ff",
        "chartPrimary": "#ff007a", "chartSecondary": "#22d3ee",
        "chartSuccess": "#39ff14", "chartWarning": "#ffd400",
        "chartDanger": "#ff3864",  "chartMuted": "#6d5f9c"
      }
    }
  ]
}
```

To add one, copy a block, give it a unique `id`, and change the colours. The picker rebuilds
itself from the file on page load. Any CSS colour works — hex, `rgb()`, `hsl()`.

Included: Cyberpunk, Terminal, PowerShell, Matrix, Amber CRT, Synthwave, Nord, Dracula,
Solarized Dark, Solarized Light, High Contrast, Blueprint, Paper, plus the original
VS Code-derived themes in `Web/theme/*.jsonc`.

The chosen theme is remembered per browser.

---

## Scheduling

Use certificate authentication and turn off colour so the log stays readable:

```jsonc
"Authentication": { "Mode": "Certificate" },
"Console": { "ShowProgress": true, "UseColour": false, "ShowPerItem": false, "ItemInterval": 250 }
```

Register a daily task:

```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Deploy\MailboxDashboard\Collector\Invoke-MailboxDashboardCollection.ps1" -Parallel -Repair' `
    -WorkingDirectory "C:\Deploy\MailboxDashboard"

$trigger = New-ScheduledTaskTrigger -Daily -At 2am

Register-ScheduledTask -TaskName "MailboxDashboard collection" `
    -Action $action -Trigger $trigger -RunLevel Highest `
    -Description "Nightly Exchange Online mailbox collection"
```

To stop a bad run from publishing, gate on validation:

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1 -SkipValidation
.\Collector\Test-MailboxDashboardJSON.ps1 -Strict
if ($LASTEXITCODE -ne 0) { throw "Validation failed; not publishing." }
.\Deploy-MailboxDashboard.ps1 -DestinationRoot \\webserver\wwwroot\MailboxDashboard
```

---

## Deployment

```powershell
.\Deploy-MailboxDashboard.ps1 -DestinationRoot C:\inetpub\wwwroot\MailboxDashboard
```

Copies the site to the destination, merging existing JSON data rather than replacing it, and
excluding logs, temp files and backups. Supports `-WhatIf`.

For IIS, publish only the `Web` folder — the collector does not need to be on the web
server. `web.config` sets the correct MIME type for `.json`.

A minimal published site is:

```
Web/
  *.html  dashboard.js  styles.css  web.config
  data.json  history.json
  scopes.json
  theme/
```

---

## Logging

Nothing is written while a run succeeds, apart from one line per export.

**`Collector/Logs/exports.log`** — every JSON write:

```
[EXPORT] 2026-09-07 14:31:02Z  Collect-ExchangeOnlineMailboxes.ps1
  Records : 412 written (388 updated, 24 added)
  Target  : ..\Web\history.json
  Source  : Exchange Online (Get-EXOMailbox / Get-EXOMailboxStatistics)
```

A write of zero records is logged too — a silent empty export is exactly the failure this is
meant to catch.

**`Collector/Logs/failures.log`** — written only when something throws:

```
[FAILURE] 2026-09-07 14:22:31Z
Context: Collecting carol@contoso.com
Script : Collect-ExchangeOnlineMailboxes.ps1
Line   : 231
Command: Get-EXOMailbox -Identity $MailboxIdentity -Properties ExchangeGuid, ...
Error  : The operation couldn't be performed because object 'carol@contoso.com' couldn't be found.
Type   : Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException
Variables:
  $counter         = 4
  $identityValue   = carol@contoso.com
  $ClientSecret    = ***REDACTED***
StackTrace:
  at Get-MailboxSample, Collect-ExchangeOnlineMailboxes.ps1: line 231
```

You get the failing script, **the line number**, the command, the local variables at that
moment, and the stack trace. Any variable whose name looks like a secret — matching
`secret`, `password`, `token`, `thumbprint`, `credential` or `apikey` — is redacted.

A failed mailbox never stops the run; the collector records the failure and continues.

---

## Git and secrets

`Collector/Config/dashboardConfig.json` holds your tenant ID, application ID and client
secret. It is **excluded by `.gitignore`** and is no longer tracked. Commit
`dashboardConfig.example.json` instead, which carries placeholders only.

Also excluded: collected data (`Web/history.json`, `Web/data.json`), demo data, the mailbox
list, logs, thread-job output, and backup files.

To untrack them in an existing clone without deleting anything:

```powershell
git rm --cached Collector/Config/dashboardConfig.json
git rm --cached Web/history.json Web/data.json
git rm --cached Mailboxes/mailboxes.csv Mailboxes/mailboxes.json
git commit -m "Stop tracking configuration and collected data"
```

> **If a secret has already been committed, removing the file does not remove it from
> history.** Anyone with the repository can still read it from an earlier commit. Rotate the
> secret in Entra — that is the only thing that actually revokes it.
>
> Purging it from history as well needs a rewrite (`git filter-repo` or BFG) and a
> force-push that every clone must recover from. Rotating is usually enough; purge only if
> the repository is public or the secret cannot be rotated.

Prefer a certificate thumbprint over a client secret where you can — nothing sensitive is
then stored in the configuration at all.

`Initialize-MailboxDashboard.ps1` warns you if it finds a secret in a file git is tracking.

---

## Script reference

### Current pipeline — `Collector/`

| Script | Purpose |
|---|---|
| `Initialize-MailboxDashboard.ps1` | First-run setup: prerequisites, folders, config, mailbox list |
| `Invoke-MailboxDashboardCollection.ps1` | Runs the whole pipeline |
| `Invoke-MailboxDashboardAuth.ps1` | Authentication menu and Exchange Online connection |
| `Collect-ExchangeOnlineMailboxes.ps1` | Queries Exchange, appends samples to history |
| `Merge-CollectionResults.ps1` | Merges parallel worker output into history |
| `Generate-MailboxSnapshot.ps1` | Rebuilds `data.json` from history |
| `Test-MailboxDashboardJSON.ps1` | Validates, repairs and culls the JSON files |
| `New-MailboxDashboardTestData.ps1` | Generates synthetic data |
| `Register-EntraApp.ps1` | Creates or repairs the Entra app registration |
| `Get-ExchangeOnlineAccessToken.ps1` | Standalone token helper |
| `Modules/MailboxDashboard.Config.psm1` | Loads, validates and resolves the configuration |
| `Modules/MailboxDashboard.Common.psm1` | Paths, JSON I/O, size and date conversion, console, logging |

### Superseded — `Collector/Legacy/`

`Update-MailboxDashboard.ps1`, `HistoryCollector.ps1`, `MergeJSON.ps1`,
`Extract-HotData.ps1`, `Start-HistoryCollectorThreaded.ps1`.

Kept for reference. They still run, but they do not use the shared configuration, the
logging, or the validation — and `Start-HistoryCollectorThreaded.ps1` never actually
threaded: it ran the collector sequentially, then re-ran parts of the pipeline with
hardcoded paths. Use the current scripts.

### Web — `Web/`

| File | Purpose |
|---|---|
| `dashboard.js` | All client-side logic |
| `styles.css` | All styling |
| `scopes.json` | Scope definitions |
| `theme/themes.json` | Colour themes |
| `HTTPServer.ps1` | Local static file server |
| `web.config` | IIS MIME types |

---

## Troubleshooting

**The dashboard is empty.**
Check that `Web/data.json` exists and has mailboxes. Rebuild it with
`.\Collector\Generate-MailboxSnapshot.ps1`, which is quick and needs no Exchange
connection.

**History looks right but the overview does not.**
`data.json` is stale. Regenerate it as above — it always takes the newest sample per
mailbox.

**A run seems to hang at "Authenticating".**
The Windows sign-in window is probably behind your editor. Look for it in the taskbar. For
unattended runs use `Authentication.Mode = "Certificate"`.

**"Parallel collection requires certificate or client-secret authentication."**
Working as intended — each worker needs its own app-only session, and interactive would
prompt once per worker. Either set a client secret or thumbprint, or drop `-Parallel`.

**Assembly or type-load errors on connect.**
`Microsoft.Graph.Authentication` must import before `ExchangeOnlineManagement`. Start a
fresh PowerShell session and let the scripts do the importing.

**Permissions page shows counts but no delegates.**
History collected by the older scripts stored `PermissionCount` but not the permission
detail. The current collector writes the full array, so the page fills in after the next
collection. Existing history cannot be backfilled without re-querying Exchange.

**Mailbox sizes show as 0.**
A symptom of the old size parser, which only understood the
`"1.5 GB (1,610,612,736 bytes)"` form and returned 0 for a bare `"4.993 GB"`. The current
`Convert-ExoSizeToBytes` handles both, plus raw byte counts and `ByteQuantifiedSize`
objects. Re-collect to correct the affected samples.

**A mailbox shows over 100% usage.**
That is real, not a bug. The collector and validator deliberately preserve it instead of
clamping to the quota, because an over-quota mailbox is the thing you most want to see.

**Timestamps look wrong after editing history by hand.**
Timestamps must be ISO 8601. `ConvertFrom-Json` turns them into `DateTime` objects, and
writing those back out with `[string]` produces locale-specific text such as
`2/09/2026 12:00:00 AM`, which another machine will misread. Run
`.\Collector\Test-MailboxDashboardJSON.ps1 -Repair` to normalise them.

**A scope shows no mailboxes.**
Check the rules in `Web/scopes.json`. Remember excludes beat includes, and that
`minUsagePercent` combines with the include patterns rather than replacing them.

**Local browsing returns 404.**
Confirm `HTTPServer.ps1` is running and that you are using the same port as `-Prefix`.

**Something failed and you want the detail.**
`Collector/Logs/failures.log` has the script, line number, variables and stack trace for
every failure.
