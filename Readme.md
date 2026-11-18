# MailboxDashboard

Exchange Online mailbox monitoring: a PowerShell collector pipeline that gathers mailbox
size, quota, archive and permission data, and a static web dashboard that reports on it.

---

## Contents

- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Installation](#installation)
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

# Or use the contextual operator menu for setup, collection, data, and dashboard actions
.\Collector\Start-MailboxDashboardMenu.ps1

# 1. Set up (creates config, folders, mailbox list template)
.\Collector\Initialize-MailboxDashboard.ps1

# 2. See the dashboard working before touching Exchange
.\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData

# 3. Browse it
.\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8080/

# 4. When you are ready, collect for real
.\Collector\Invoke-MailboxDashboardCollection.ps1
```

### Interactive operator menu

Run `.\Collector\Start-MailboxDashboardMenu.ps1` to open the PowerShell operator menu.
It shows only actions whose configuration, scripts, and required data files are available.
The menu can run setup, live collection, isolated demo-data generation, snapshot rebuild,
read-only validation, repair/cull, local dashboard hosting, and shareable-URL generation.
It also offers live replacement with synthetic data after demo files have been generated.

Live collection, live demo-data replacement, snapshot overwrite, and repair/cull require
typing `YES` at a confirmation prompt. Before live demo replacement and snapshot rebuild,
the menu creates timestamped backups alongside the affected JSON files. Repair/cull keeps
the validator's normal backups. Generate isolated demo files when you want to exercise the
generator without changing the dashboard's current data.

Scheduled jobs should continue to call the non-interactive collector scripts directly.

### Choose the mailbox collector

The menu offers separate **Exchange Online (live, full detail)** and **Graph only
(delayed report, limited detail)** collection actions. Exchange Online remains the
default for existing scheduled commands. The Graph action appears when
`Microsoft.Graph.Authentication`, app-only credentials, and the configured GUID mapping
file are available. It does not require the Exchange module or the Exchange mailbox CSV.
Both actions rebuild and validate the configured dashboard snapshot. Graph collection
requires `YES` confirmation and backs up the configured history and snapshot first.

#### Register and configure the application

Use the existing Entra application or register a dedicated collector application in the
[Entra portal](https://entra.microsoft.com/). This alternate collector uses only stable
Microsoft Graph v1.0 requests; it does not connect to Exchange Online or read messages.

#### Select and consent to Graph permissions

Grant these **application** permissions and obtain tenant administrator consent:

| Query | Endpoint | Method | Least-privileged permission | Admin consent | Purpose |
| --- | --- | --- | --- | --- | --- |
| Mailbox usage report | `/v1.0/reports/getMailboxUsageDetail(period='D7')` | GET | `Reports.Read.All` | Yes | Storage, item counts, quotas, archive presence and last activity date |
| Directory users | `/v1.0/users?$select=id,displayName,userPrincipalName,mail,proxyAddresses,assignedLicenses,assignedPlans` | GET | `User.Read.All` | Yes | Stable Graph identity, primary SMTP, display names and Exchange service-plan assignment |
| Mailbox purpose | `/v1.0/users/{id}/mailboxSettings/userPurpose` | GET | `MailboxSettings.Read` | Yes | User, linked, shared, room or equipment mailbox classification |

No `Mail.Read` permission is needed. `Mail.Send` is needed only if the existing optional
email notifications are enabled, not for collection.
See [mailbox report API](https://learn.microsoft.com/graph/api/reportroot-getmailboxusagedetail?view=graph-rest-1.0),
[list users](https://learn.microsoft.com/graph/api/user-list?view=graph-rest-1.0),
[mailbox settings](https://learn.microsoft.com/graph/api/user-get-mailboxsettings?view=graph-rest-1.0), and
[permission consent requirements](https://learn.microsoft.com/graph/permissions-reference).
Usage-report identities must be visible rather than concealed in the tenant's reports
privacy settings. Do not change those tenant-wide settings without administrator approval.
Concealed or unmatched report identities cause collection to fail rather than guessing.

#### Supply authentication and durable identity mapping

Configure `Organization`, `AppID`, and either `Thumbprint` or `ClientSecret` in the local
configuration. Graph collection uses app-only authentication independently of the
Exchange authentication menu. Keep secrets out of source control.

Copy `Collector/Config/graph-mailbox-mapping.example.csv` to
`Collector/Config/graph-mailbox-mapping.csv` and replace the example row with real values:

```csv
GraphUserId,ExchangeGuid
11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222
```

`GraphUserId` is the Entra user object ID, **not** a UPN or Exchange GUID. `ExchangeGuid`
must be the actual mailbox GUID from your existing Exchange inventory. Graph does not
provide this durable mailbox key; the script never fabricates one from the user ID.
Each ID and each Exchange GUID must occur only once. The collector queries only mapped
mailboxes; update the mapping when a mailbox is recreated or a user object is replaced.
Set `Paths.GraphMailboxMappingCsv` to use a different mapping file. Like other configured
paths, it is resolved relative to `Collector/`.

#### Run locally or from the menu

Install `Microsoft.Graph.Authentication` if it is not already installed, then use:

```powershell
# Full Graph-only flow: collect -> validate -> snapshot -> validate
.\Collector\Invoke-MailboxDashboardCollection.ps1 -Collector Graph

# Alternate collector alone (history only)
.\Collector\Collect-GraphMailboxes.ps1 -Connect

# Preview without Graph requests or data writes
.\Collector\Invoke-MailboxDashboardCollection.ps1 -Collector Graph -WhatIf

# Existing live Exchange flow is unchanged
.\Collector\Invoke-MailboxDashboardCollection.ps1
```

Graph reports typically lag by 24-48 hours and are not live mailbox statistics.
Samples use **Report Refresh Date**, not the collection time, and repeating a report
does not create duplicate samples. A newer existing Exchange sample remains the current
snapshot until Graph supplies a later report. Directory licensing reflects the directory
query time, whereas usage metrics reflect the report time.

Graph cannot supply archive size/item counts, Exchange mailbox delegation permissions,
last logon, or the existing Exchange retention/hold details. These are stored as null
with `DataAvailability` metadata and displayed as unavailable, not zero or "no permissions".
Last activity is not treated as last logon. Exchange service-plan assignment is not a
mailbox license-compliance determination: license requirement remains unknown. Known
Graph mailbox purposes provide a mailbox classification; unrecognized purposes remain
unknown rather than guessing an Exchange recipient subtype.
The dashboard displays report limitations and refresh dates.
Graph uses paged requests rather than Exchange workers, so do not use `-Parallel`,
`-ThrottleLimit`, `-BatchSize`, or `-KeepWorkerFiles`. Invalid mappings, unreadable existing history,
missing report rows, or request failures abort without partially replacing history.

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
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser   # Graph-only collection or interactive sign-in
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
    "GraphMailboxMappingCsv": ".\\Config\\graph-mailbox-mapping.csv",
    "HistoryJson":         "..\\Web\\history.json",
    "DataJson":            "..\\Web\\data.json",
    "BackupDirectory":     "..\\Web\\Backups",
    "WebRoot":             "..\\Web",
    "CollectionStatusJson":"..\\Web\\collection-status.json",
    "AlertStateJson":      ".\\Logs\\alert-state.json",
    "DemoDataJson":        "..\\Web\\demo-data.json",
    "DemoHistoryJson":     "..\\Web\\demo-history.json",
    "TempDirectory":       ".\\Temp",
    "ThreadJobsDirectory": ".\\Temp\\ThreadJobs",
    "LogDirectory":        ".\\Logs"
  },

  "Collection": {
    "BatchSize":         50,      // commit progress to disk every N mailboxes
    "MaxHistorySamples": 365,     // samples retained per mailbox
    "UseThreading":      true,
    "ThreadCount":       10
  },

  "Thresholds": {
    "CriticalPercent": 94.0,
    "WarningPercent":  85.0
  },

  "Monitoring": {
    "StaleAfterMinutes": 60
  },

  "Notifications": {
    "Enabled": false,
    "SenderMailbox": "",
    "Recipients": []
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

Configurations from the previous version still load — old root-level keys such as
`HistoryJsonPath` and `MailboxesCsvPath` are mapped onto the new `Paths` section
automatically.

`Monitoring.StaleAfterMinutes` controls when the overview marks the most recent run as stale
(default: 60 minutes). Each orchestrated run writes an aggregate-only
`Web/collection-status.json` record. It contains the run result, timings, configured stale
threshold, and step outcomes; it does not contain mailbox addresses, mailbox identifiers, or
credentials. The status file is generated output and is excluded from Git.

Email notifications are disabled by default. To enable them, set
`Notifications.Enabled` to `true`, configure `SenderMailbox` and a `Recipients` array, and
use the tenant/application and certificate thumbprint or client secret already configured
for unattended collection. Grant the app the **Microsoft Graph `Mail.Send` application
permission** and tenant admin consent before enabling delivery. The app sends as the
configured sender mailbox. Do not add this permission to an app unless the tenant
administrator has approved the access.

Notifications are sent only for a newly detected warning/critical mailbox threshold,
severity changes, resolution, or collection failure/recovery. Multiple transitions from a
run are combined into one message. Successful delivery updates
`Collector/Logs/alert-state.json`; unchanged conditions are not repeated. Failed delivery
leaves the prior state in place so the transition is retried on the next collection.
Test-data runs do not send alerts. Use `-WhatIf` to preview alert sends without sending mail
or changing alert state.

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
Before writing, it requires a valid history array, unique Exchange GUIDs, timestamped
samples, and usable current metrics for every mailbox. Any malformed record aborts the
entire rebuild and leaves the existing `data.json` untouched; empty history is also
refused unless an intentionally empty dashboard is requested with
`-AllowEmptySnapshot`. Use `Test-MailboxDashboardJSON.ps1 -Target History -Strict` to
identify history issues before rebuilding.

Licensing fields are collected from Exchange during a mailbox collection and copied into
the snapshot. After updating an older installation, run a new collection and then
`Generate-MailboxSnapshot.ps1`; records from before licensing collection will show
licensing as `Unknown`, not as a false missing-license failure.

License assignment uses Exchange's `SKUAssigned` value, not the presence of persisted
capabilities or the mailbox quota. A 50 GB quota can belong to a licensed user mailbox
or an unlicensed shared mailbox; quota alone does not establish license assignment.
An unavailable assignment value is reported as `Unknown`. Persisted capabilities are
retained as descriptive metadata, not proof of a currently assigned product SKU.

The collector explicitly requests `LastLogonTime` and saves the creation date in history
so both fields can reach the snapshot. Last logon can be empty and reflects mailbox
access, including service activity; it is not an authoritative human sign-in timestamp.

### History stops growing

Each successful collection adds a sample per mailbox, up to
`Collection.MaxHistorySamples` (365 by default). The history page uses all saved samples;
it does not impose a two-point limit. Snapshot generation does not add history samples.
Confirm that the scheduled task runs `Invoke-MailboxDashboardCollection.ps1` and that
its configured history path is the file served by the dashboard. Avoid `-TestData` on
production data because it replaces the live files.

To inspect the saved counts without changing data, use the configured history path:

```powershell
$history = Get-Content -LiteralPath '<resolved HistoryJson path>' -Raw | ConvertFrom-Json
$history.MailboxHistory | Select-Object -Property PrimarySmtpAddress,
  @{Name = 'SampleCount'; Expression = { @($_.Samples).Count }}
```

The collector stops rather than replacing unreadable, empty, or unsupported existing
history. Restore a known-good backup or convert legacy data to the nested
`MailboxHistory[] -> Samples[]` structure before retrying. Previously discarded samples
cannot be recovered by recollection or snapshot generation.

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

### Backing up validated dashboard data

`Backup-MailboxDashboard.ps1` validates the configured history and data JSON files before
creating a backup. It then copies them into a timestamped folder, verifies each copy with
SHA-256, validates the staged files, and only then finalizes the backup folder.

The destination and included files are controlled by `Paths.BackupDirectory`,
`Paths.WebRoot`, and `Backup.Sources` in `Collector\Config\dashboardConfig.json`.
The backup directory must resolve to `WebRoot\Backups`; this keeps the published copies
inside the dashboard's restricted static-file location.

```json
{
  "Paths": {
    "BackupDirectory": "..\\Web\\Backups",
    "WebRoot": "..\\Web"
  },
  "Backup": {
    "Sources": ["HistoryJson", "DataJson"]
  }
}
```

Only `HistoryJson` and `DataJson` can be included; configuration files and logs are never
copied. Run the backup, or validate and preview it without writing:

```powershell
.\Collector\Backup-MailboxDashboard.ps1
.\Collector\Backup-MailboxDashboard.ps1 -WhatIf
```

An invalid or missing source prevents a backup from being finalized. Existing backups are
not automatically pruned. Each successful run adds its file names, byte sizes, SHA-256
hashes, and validation status to `Web/Backups/backup-status.json`. The separate
`backups.html` page checks the served copies against that manifest and provides downloads.
IIS directory browsing is disabled for this folder, and URL Rewrite rules allow only the
status manifest and timestamped `history.json`/`data.json` copies. Install the IIS URL
Rewrite module when hosting with IIS; the built-in HTTP server applies the equivalent
filename allowlist without that module. The browser uses Web Crypto to check SHA-256, so
serve the dashboard over HTTPS or localhost; otherwise the copy is clearly marked as
unverified. If your existing
universal config still points at `Collector/Backups`, update both paths before running a
backup.

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
.\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8080/
```

| Page | Shows |
|---|---|
| `index.html` | Overview: totals, charts, full mailbox table |
| `scope.html` | The same overview limited to one scope |
| `mailbox.html` | One mailbox: metrics, history, delegates |
| `history.html` | Historical storage and utilisation |
| `permissions.html` | Full Access, Send As, and Send on Behalf permissions |
| `accessmap.html` | User-to-mailbox delegation map, scoped to the current filters |
| `backups.html` | Backup copies, hash/size validity, and downloads |
| `thresholds.html` | Mailboxes at or above the warning threshold |
| `validate.html` | Standalone data validation view |

### Modern view

`Web/modern/` is an alternative front end over the same `data.json`, `history.json` and
`scopes.json`. It does not replace the classic pages; both can be deployed side by side.

| Page | Shows |
|---|---|
| `modern/index.html` | KPI tiles with sparklines, storage trend, health donut, quota distribution, top consumers, logon activity, sortable mailbox table |
| `modern/mailbox.html` | One mailbox: storage history, quota gauge, created / last logon / refreshed / collector dates, licensing, delegates |

Every page shows a **QR code that links to exactly what is on screen** — scope, search,
status filter, sort, page and selected mailbox. Select **Share** to enlarge it, copy the
link or download the QR as SVG. The QR is generated in the browser by
`modern/qrcode.js`; no external service is called. Anyone scanning it still needs access
to the dashboard.

The modern view has light and dark themes (toggle in the top bar, remembered per
browser) and adapts to phone widths.

Mailbox delegation records carry the target `ExchangeGuid`; links use that GUID while the
map displays mailbox names and aliases. The map distinguishes Full Access, Send As, and
Send on Behalf with separate badges and can retain principals whose mailbox links are
hidden by the active filters. Mailbox statistics also show lifetime-average storage
consumption in GB/day: current primary plus archive storage divided by the mailbox age
from `CreatedUtc` to the latest sample. The rate is unavailable if creation/sample dates
are missing or invalid.
The overview's Collection health panel reads `collection-status.json` independently of
mailbox data. A missing or invalid status file is shown as unavailable without blocking
the rest of the dashboard. A completed run is marked stale after the threshold recorded
in that run's status artifact; failed and partial runs have their own visible states.

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

**Email alerts** use `Collector/Logs/alert-state.json` to suppress repeated notifications.
If Graph rejects a message or state cannot be saved, inspect `failures.log`; an unconfirmed
transition is retried on the next run. Confirm that the app has `Mail.Send` application
permission with admin consent and that the configured sender mailbox is valid.

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
| `Start-MailboxDashboardMenu.ps1` | Contextual operator menu for setup, collection, data and dashboard actions |
| `Invoke-MailboxDashboardCollection.ps1` | Runs the whole pipeline |
| `Invoke-MailboxDashboardAuth.ps1` | Authentication menu and Exchange Online connection |
| `Collect-ExchangeOnlineMailboxes.ps1` | Queries Exchange, appends samples to history |
| `Merge-CollectionResults.ps1` | Merges parallel worker output into history |
| `Generate-MailboxSnapshot.ps1` | Rebuilds `data.json` from history |
| `Test-MailboxDashboardJSON.ps1` | Validates, repairs and culls the JSON files |
| `Backup-MailboxDashboard.ps1` | Validates and backs up configured dashboard JSON |
| `New-MailboxDashboardTestData.ps1` | Generates synthetic data |
| `Register-EntraApp.ps1` | Creates or repairs the Entra app registration |
| `Get-ExchangeOnlineAccessToken.ps1` | Standalone token helper |
| `Modules/MailboxDashboard.Config.psm1` | Loads, validates and resolves the configuration |
| `Modules/MailboxDashboard.Common.psm1` | Paths, JSON I/O, size and date conversion, console, logging |

### Superseded — `Collector/Legacy/`

`Update-MailboxDashboard.ps1`, `HistoryCollector.ps1`, `MergeJSON.ps1`,
`Extract-HotData.ps1`, `Start-HistoryCollectorThreaded.ps1` (along with the legacy copies
still at `Collector/Update-MailboxDashboard.ps1`, `Collector/HistoryCollector.ps1`, and
`Collector/MergeJSON.ps1`).

Kept for reference. They still run, but they do not use the shared configuration, the
logging, or the validation — and `Start-HistoryCollectorThreaded.ps1` never actually
threaded: it ran the collector sequentially, then re-ran parts of the pipeline with
hardcoded paths. Use the current scripts.

### Editor & Linting

- PowerShell functions follow approved verb conventions (`PSScriptAnalyzer` `PSUseApprovedVerbs`).
- Workspace spell-checking rules and PowerShell/Exchange custom terms (`psobject`, `datetimeoffset`, and Exchange mailbox type names) are configured in `.vscode/settings.json` under `cSpell.words`.

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

**Collection health is unavailable or stale.**
Confirm the collector can write the configured `Paths.CollectionStatusJson` path, that the
static host serves `collection-status.json`, and that the latest collection completed within
`Monitoring.StaleAfterMinutes`.

**Graph alert delivery failed.**
Check `Notifications.Enabled`, `SenderMailbox`, and `Recipients`; confirm the app has
Microsoft Graph `Mail.Send` application permission and admin consent, and inspect
`Collector/Logs/failures.log` for the Graph error.

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
