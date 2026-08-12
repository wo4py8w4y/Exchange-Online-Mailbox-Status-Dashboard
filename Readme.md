# MailboxDashboard Collector Setup Walkthrough

This guide sets up the collector for delegated Exchange Online auth with a reusable local app registration.

## What this uses

- [Register-EntraApp.ps1](C:/TEMP/MailboxDashboard/Collector/Register-EntraApp.ps1)
- [Start-HistoryCollectorThreaded.ps1](C:/TEMP/MailboxDashboard/Collector/Start-HistoryCollectorThreaded.ps1)
- [HistoryCollector.ps1](C:/TEMP/MailboxDashboard/Collector/HistoryCollector.ps1)
- [Get-ExchangeOnlineAccessToken.ps1](C:/TEMP/MailboxDashboard/Collector/Get-ExchangeOnlineAccessToken.ps1)
- [dashboardConfig.json](C:/TEMP/MailboxDashboard/Collector/Config/dashboardConfig.json)

## 1. Prerequisites

- PowerShell 7+
- Microsoft Graph PowerShell modules
- ExchangeOnlineManagement module
- A tenant admin account with permission to create app registrations and grant delegated consent

Install modules if needed:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.PowerShell.ThreadJob -Scope CurrentUser
```

## 2. Create or repair the Entra app

Run:

```powershell
.\Collector\Register-EntraApp.ps1
```

This will:

- create or update the app registration
- create a client secret
- grant the Exchange Online delegated permission
- update [dashboardConfig.json](C:/TEMP/MailboxDashboard/Collector/Config/dashboardConfig.json)

  - expected output

  ```PowerShell
  PS C:\TEMP\MailboxDashboard\Collector> . .\Register-EntraApp.ps1 -ConfigPath  C:\TEMP\MailboxDashboard\Collector\Config\dashboardConfig.json -AppId 260cd5f4-a25c-4976-b1ca-2aeaf1cc3464 -TenantIdOrDomain ec445a2a-b5ba-46f6-bead-4595e9fbd4a2 -DisplayName 'exchange report'

  Confirm
  Are you sure you want to perform this action?
  Performing the operation "Update registration" on target "Entra application 'exchange report'".
  [Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help (default is "Y"): y

  Confirm
  Are you sure you want to perform this action?
  Performing the operation "Grant 'Exchange.Manage'" on target "Delegated permission grant for 'exchange report'".
  [Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help (default is "Y"): y

  Confirm
  Are you sure you want to perform this action?
  Performing the operation "Update dashboard config with AppId and tenant" on target "C:\TEMP\MailboxDashboard\Collector\Config\dashboardConfig.json".
  [Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help (default is "Y"): y


  DisplayName         : exchange report
  Tenant              : ec445a2a-b5ba-46f6-bead-4595e9fbd4a2
  AppId               : 260cd5f4-a25c-4976-b1ca-2aeaf1cc3464
  ApplicationObjectId : e2426414-bde2-430b-bb25-aee927535c2f
  ServicePrincipalId  : 3edb8884-e33b-4ef9-bc46-6e49d285d776
  RedirectUri         : http://localhost:8400/
  ExchangeScope       : Exchange.Manage
  ConfigUpdated       : True
  ```

## 3. Verify the config

Check that [dashboardConfig.json](C:/TEMP/MailboxDashboard/Collector/Config/dashboardConfig.json) contains:

- `Organization`
- `AppID`
- `ClientSecret`
- `UserPrincipalName`
- `CsvPath`
- `MailboxesCsvPath`
- `HistoryJsonPath`

## 4. Run the threaded collector

```powershell
.\Collector\Start-HistoryCollectorThreaded.ps1 -UserPrincipalName your-admin@yourtenant.onmicrosoft.com
```

The bootstrapper will:

- read the config
- open browser sign-in and create a delegated access token automatically
- split the mailbox CSV into chunks
- run [HistoryCollector.ps1](C:/TEMP/MailboxDashboard/Collector/HistoryCollector.ps1) in thread jobs
- merge the chunk output into `history.json`

## 5. Run the collector directly

If you want a single-process run:

```powershell
.\Collector\HistoryCollector.ps1
```

It will connect automatically if Exchange Online is not already connected.

If app creation fails, make sure your Graph login has permission to create apps and grant app roles.

- If token creation fails, re-run [Register-EntraApp.ps1](C:/TEMP/MailboxDashboard/Collector/Register-EntraApp.ps1) and confirm the delegated Exchange permission, redirect URI, and public client flow settings are present.
- If paths are wrong, check the relative values in [dashboardConfig.json](C:/TEMP/MailboxDashboard/Collector/Config/dashboardConfig.json).

## 7. Notes

- The app secret remains available for future app-only scenarios, but the threaded collector now uses delegated browser sign-in by default.
- The mailbox CSV should point to [mailboxes.csv](C:/TEMP/MailboxDashboard/Mailboxes/mailboxes.csv).
