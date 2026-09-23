# MailboxDashboard setup walkthrough

This guide prepares the current MailboxDashboard collector and local static dashboard.
The normal entry point is `Invoke-MailboxDashboardCollection.ps1`; the older collector
scripts are retained only under `Collector/Legacy` for reference.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 (PowerShell 7 is recommended)
- Exchange Online administrator access
- Permission to create or update an Entra app registration when using `Register-EntraApp.ps1`
- `ExchangeOnlineManagement` PowerShell module

Optional modules are reported by the setup script:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module graph.auth.lite -Scope CurrentUser
Install-Module Microsoft.PowerShell.ThreadJob -Scope CurrentUser
```

Only `ExchangeOnlineManagement` is required for a sequential Exchange collection.
`Microsoft.PowerShell.ThreadJob` is required only when `-Parallel` is used.

## 1. Initialize the installation

From the repository root, run:

```powershell
.\Collector\Initialize-MailboxDashboard.ps1
```

The wizard creates or checks the configuration, required folders, and
`Mailboxes/mailboxes.csv`. It does not overwrite an existing configuration unless
`-Force` is supplied.

For unattended setup:

```powershell
.\Collector\Initialize-MailboxDashboard.ps1 `
    -Organization contoso.onmicrosoft.com `
    -AppId 00000000-0000-0000-0000-000000000000 `
    -AuthenticationMode Certificate `
    -Unattended
```

Replace the sample mailbox rows in `Mailboxes/mailboxes.csv` with the mailboxes to
collect. The accepted address column names include `PrimarySMTPAddress`, `Mailbox`,
`EmailAddress`, and `UserPrincipalName`.

## 2. Configure authentication

Edit `Collector/Config/dashboardConfig.json`, or let initialization populate its basic
values. The important settings are:

- `Organization`: tenant ID or primary domain
- `AppID`: Entra application (client) ID
- `Authentication.Mode`: `Certificate`, `Interactive`, `Delegated`, or `Auto`
- `ClientSecret` or `Thumbprint` for certificate/app-only collection
- `UserPrincipalName` for delegated collection

For a new app registration, run:

```powershell
.\Collector\Register-EntraApp.ps1 `
    -ConfigPath .\Collector\Config\dashboardConfig.json
```

Use certificate or client-secret authentication for scheduled or parallel collection.
Use `Interactive` or `Delegated` for a manual run. `Auto` displays the authentication
menu at runtime.

## 3. Test without Exchange Online

Generate synthetic data and build both dashboard JSON files:

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData
```

This overwrites `Web/history.json` and `Web/data.json`. Use it only when replacing the
current dashboard data is acceptable.

To generate demo files without replacing the live files:

```powershell
.\Collector\New-MailboxDashboardTestData.ps1
```

## 4. Run a real collection

The sequential collection path is the default:

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1
```

Useful overrides include:

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1 `
    -AuthenticationMode Certificate `
    -Identity user@contoso.com `
    -BatchSize 50
```

For app-only parallel collection:

```powershell
.\Collector\Invoke-MailboxDashboardCollection.ps1 `
    -Parallel `
    -ThrottleLimit 8
```

Parallel workers write temporary files under `Collector/Temp/ThreadJobs`; the pipeline
merges successful worker output before generating the snapshot. `-Parallel` requires
certificate or client-secret authentication.

## 5. Validate and repair data

The pipeline validates generated files unless `-SkipValidation` is supplied. Run the
validator directly when investigating or repairing existing data:

```powershell
# Report problems without changing files
.\Collector\Test-MailboxDashboardJSON.ps1

# Repair recoverable values and write backups first
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair

# Repair and remove records that cannot be repaired
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair -Cull

# Restore empty history samples from matching data.json snapshots
.\Collector\Test-MailboxDashboardJSON.ps1 -Repair -RestoreSamplesFromData

# Return a failure exit code when any issue is found
.\Collector\Test-MailboxDashboardJSON.ps1 -Strict
```

If history is correct but the overview is stale, rebuild only the current snapshot:

```powershell
.\Collector\Generate-MailboxSnapshot.ps1
```

Licensing status is collected from Exchange and copied into `data.json`. After upgrading
an older installation, run a fresh collection before expecting licensing assignments to
appear; older records are shown as unknown when licensing metadata is absent.

## 6. Browse the dashboard locally

Start the static server from the repository root:

```powershell
.\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8888/
```

Open <http://localhost:8888/>. The published `Web` folder contains the HTML, JavaScript,
CSS, theme files, scopes, and generated JSON consumed by the dashboard.

## Troubleshooting

- If authentication appears to stop, check whether the sign-in window opened behind the
  terminal or editor.
- If parallel collection is rejected, use `-Parallel` only with certificate or client-secret
  authentication and install `Microsoft.PowerShell.ThreadJob`.
- If the dashboard is empty, confirm `Web/history.json` and `Web/data.json` exist, then run
  `Generate-MailboxSnapshot.ps1` and `Test-MailboxDashboardJSON.ps1`.
- If a collection fails, inspect `Collector/Logs/failures.log` and
  `Collector/Logs/exports.log`.
- If the server returns 404, confirm that it is serving the `Web` folder and that the browser
  URL uses the same port as `-Prefix`.

For the complete configuration reference and deployment instructions, see the repository
[README](../Readme.md).
