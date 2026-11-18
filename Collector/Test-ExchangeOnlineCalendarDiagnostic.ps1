#Requires -Version 7.0

<#
.SYNOPSIS
    Collects a read-only Exchange Online calendar, event, and routing diagnostic.
.DESCRIPTION
    Resolves one or more mailboxes, then reports calendar folder statistics,
    calendar permissions, publishing settings, resource booking settings, mailbox
    forwarding/routing properties, and optional calendar items and message traces.

    Exchange Online is used for mailbox, folder, publishing, permissions,
    processing, and routing data. Calendar items require an existing Microsoft
    Graph connection and the -IncludeCalendarItems switch.
.PARAMETER Identity
    Mailbox SMTP addresses, aliases, GUIDs, or other Exchange identities.
.PARAMETER CsvPath
    CSV containing a PrimarySMTPAddress, PrimarySmtpAddress, Mailbox,
    EmailAddress, or UserPrincipalName column.
.PARAMETER ConfigPath
    MailboxDashboard configuration path used for authentication and CSV defaults.
.PARAMETER OutputDirectory
    Directory for CSV, JSON, and log outputs.
.PARAMETER StartDate
    Inclusive UTC start for calendar items and message trace.
.PARAMETER EndDate
    Exclusive UTC end for calendar items and message trace.
.PARAMETER IncludeCalendarItems
    Query Microsoft Graph calendar view for each resolved mailbox.
.PARAMETER IncludeMessageTrace
    Query Get-MessageTraceV2 when available. Exchange Online limits trace windows.
.PARAMETER Connect
    Connect with the repository authentication helper when no Exchange session exists.
.PARAMETER Disconnect
    Disconnect Exchange Online after the diagnostic completes.
.EXAMPLE
    .\Test-ExchangeOnlineCalendarDiagnostic.ps1 -Identity room@contoso.com
.EXAMPLE
    .\Test-ExchangeOnlineCalendarDiagnostic.ps1 -CsvPath .\Mailboxes\mailboxes.csv -IncludeCalendarItems
.NOTES
    Requires ExchangeOnlineManagement and Exchange administrator permissions suitable
    for the requested cmdlets. Calendar items additionally require Graph calendar
    read permission and access to each target mailbox. Read-only; no settings change.

    Changelog: 2026-09-30 - Initial read-only calendar, event, and routing diagnostic.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string[]]$Identity,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$OutputDirectory = '.\CalendarDiagnostic',

    [Parameter()]
    [datetime]$StartDate = (Get-Date).ToUniversalTime().AddDays(-30),

    [Parameter()]
    [datetime]$EndDate = (Get-Date).ToUniversalTime().AddDays(1),

    [Parameter()]
    [switch]$IncludeCalendarItems,

    [Parameter()]
    [switch]$IncludeMessageTrace,

    [Parameter()]
    [switch]$Connect,

    [Parameter()]
    [switch]$Disconnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectorRoot = $PSScriptRoot
Import-Module (Join-Path $collectorRoot 'Modules\MailboxDashboard.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $collectorRoot 'Modules\MailboxDashboard.Config.psm1') -Force -DisableNameChecking

function Get-InputIdentities {
    param(
        [string[]]$Requested,
        [string]$Path,
        $Config
    )

    if (@($Requested).Count -gt 0) {
        return @($Requested | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    $csv = if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $Path
    }
    else {
        $Config.ResolvedPaths.MailboxesCsv
    }

    if (-not (Test-Path -LiteralPath $csv)) {
        throw "Mailbox CSV not found at '$csv'. Supply -Identity or -CsvPath."
    }

    $rows = @(Import-Csv -LiteralPath $csv)
    if ($rows.Count -eq 0) { return @() }

    $columns = @($rows[0].PSObject.Properties.Name)
    $column = @('PrimarySMTPAddress', 'PrimarySmtpAddress', 'Mailbox', 'EmailAddress', 'UserPrincipalName') |
        Where-Object { $columns -contains $_ } | Select-Object -First 1
    if ($null -eq $column) {
        throw "CSV '$csv' has no supported mailbox identity column. Found: $($columns -join ', ')."
    }

    return @($rows | ForEach-Object { [string]$_.$column } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } | Select-Object -Unique)
}

function Invoke-OptionalDiagnosticStep {
    param(
        [Parameter(Mandatory)] [string]$Operation,
        [Parameter(Mandatory)] [string]$MailboxIdentity,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]]$Errors
    )

    try {
        return & $ScriptBlock
    }
    catch {
        $Errors.Add([pscustomobject]@{
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Operation    = $Operation
            Identity     = $MailboxIdentity
            Error        = $_.Exception.Message
        })
        Write-Warning "${Operation} failed for ${MailboxIdentity}: $($_.Exception.Message)"
        return $null
    }
}

function Convert-ExchangeSizeToText {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [string]$Value
}

if ($EndDate -le $StartDate) {
    throw 'EndDate must be later than StartDate.'
}

$configParams = @{}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $configParams.ConfigPath = $ConfigPath }
$config = Import-MailboxDashboardConfig @configParams -SkipValidation
$identities = @(Get-InputIdentities -Requested $Identity -Path $CsvPath -Config $config)
if ($identities.Count -eq 0) { throw 'No mailbox identities were supplied.' }

$resolvedOutput = Resolve-MailboxPath -Path $OutputDirectory -BaseDirectory $PWD.Path
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$errors = [System.Collections.Generic.List[object]]::new()
$summary = [System.Collections.Generic.List[object]]::new()
$calendarFolders = [System.Collections.Generic.List[object]]::new()
$calendarPermissions = [System.Collections.Generic.List[object]]::new()
$calendarProcessing = [System.Collections.Generic.List[object]]::new()
$routing = [System.Collections.Generic.List[object]]::new()
$calendarItems = [System.Collections.Generic.List[object]]::new()
$messageTrace = [System.Collections.Generic.List[object]]::new()
$connectedHere = $false

try {
    if ($Connect -or -not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) {
        . (Join-Path $collectorRoot 'Invoke-MailboxDashboardAuth.ps1')
        Connect-MailboxDashboard -Config $config | Out-Null
        $connectedHere = $true
    }

    foreach ($requestedIdentity in $identities) {
        if ([string]::IsNullOrWhiteSpace($requestedIdentity)) { continue }

        $mailbox = Invoke-OptionalDiagnosticStep -Operation 'Resolve mailbox' -MailboxIdentity $requestedIdentity -Errors $errors -ScriptBlock {
            Get-EXOMailbox -Identity $requestedIdentity -Properties ExchangeGuid,PrimarySmtpAddress,DisplayName,Alias,RecipientTypeDetails,ResourceCapacity,EmailAddresses,ForwardingSmtpAddress,ForwardingAddress,DeliverToMailboxAndForward,GrantSendOnBehalfTo,HiddenFromAddressListsEnabled,EmailAddressPolicyEnabled -ErrorAction Stop
        }
        if ($null -eq $mailbox) { continue }

        $guid = [string]$mailbox.ExchangeGuid
        if ([string]::IsNullOrWhiteSpace($guid)) {
            $errors.Add([pscustomobject]@{ TimestampUtc = (Get-Date).ToUniversalTime().ToString('o'); Operation = 'Resolve mailbox'; Identity = $requestedIdentity; Error = 'ExchangeGuid was empty.' })
            continue
        }

        $smtp = [string]$mailbox.PrimarySmtpAddress
        $calendarIdentity = "$guid`:\Calendar"
        $folderStats = Invoke-OptionalDiagnosticStep -Operation 'Get calendar folder statistics' -MailboxIdentity $guid -Errors $errors -ScriptBlock {
            @(Get-EXOMailboxFolderStatistics -Identity $guid -FolderScope Calendar -ErrorAction Stop)
        }
        foreach ($folder in @($folderStats)) {
            $calendarFolders.Add([pscustomobject]@{
                ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; DisplayName = $mailbox.DisplayName
                FolderPath = [string]$folder.FolderPath; FolderType = [string]$folder.FolderType
                Name = [string]$folder.Name; ItemsInFolder = $folder.ItemsInFolder
                FolderSize = Convert-ExchangeSizeToText $folder.FolderSize
            })
        }

        $folderPermission = Invoke-OptionalDiagnosticStep -Operation 'Get calendar permissions' -MailboxIdentity $guid -Errors $errors -ScriptBlock {
            @(Get-MailboxFolderPermission -Identity $calendarIdentity -ErrorAction Stop)
        }
        foreach ($permission in @($folderPermission)) {
            $calendarPermissions.Add([pscustomobject]@{
                ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; Folder = 'Calendar'
                User = [string]$permission.User; AccessRights = @($permission.AccessRights) -join ', '
                SharingPermissionFlags = @($permission.SharingPermissionFlags) -join ', '
            })
        }

        $published = Invoke-OptionalDiagnosticStep -Operation 'Get calendar publishing settings' -MailboxIdentity $guid -Errors $errors -ScriptBlock {
            Get-MailboxCalendarFolder -Identity $calendarIdentity -ErrorAction Stop
        }
        $processing = Invoke-OptionalDiagnosticStep -Operation 'Get calendar processing settings' -MailboxIdentity $guid -Errors $errors -ScriptBlock {
            Get-CalendarProcessing -Identity $guid -ErrorAction Stop
        }
        if ($null -ne $processing) {
            $calendarProcessing.Add([pscustomobject]@{
                ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; RecipientTypeDetails = [string]$mailbox.RecipientTypeDetails
                AutomateProcessing = $processing.AutomateProcessing; ProcessExternalMeetingMessages = $processing.ProcessExternalMeetingMessages
                AllBookInPolicy = $processing.AllBookInPolicy; AllRequestInPolicy = $processing.AllRequestInPolicy
                AllRequestOutOfPolicy = $processing.AllRequestOutOfPolicy; AllowConflicts = $processing.AllowConflicts
                BookingWindowInDays = $processing.BookingWindowInDays; MaximumDurationInMinutes = $processing.MaximumDurationInMinutes
                ResourceDelegates = @($processing.ResourceDelegates) -join ', '
                BookInPolicy = @($processing.BookInPolicy) -join ', '; RequestInPolicy = @($processing.RequestInPolicy) -join ', '
                RequestOutOfPolicy = @($processing.RequestOutOfPolicy) -join ', '
            })
        }

        $routing.Add([pscustomobject]@{
            ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; DisplayName = $mailbox.DisplayName
            RecipientTypeDetails = [string]$mailbox.RecipientTypeDetails
            ForwardingSmtpAddress = [string]$mailbox.ForwardingSmtpAddress
            ForwardingAddress = [string]$mailbox.ForwardingAddress
            DeliverToMailboxAndForward = $mailbox.DeliverToMailboxAndForward
            GrantSendOnBehalfTo = @($mailbox.GrantSendOnBehalfTo) -join ', '
            HiddenFromAddressListsEnabled = $mailbox.HiddenFromAddressListsEnabled
            EmailAddressPolicyEnabled = $mailbox.EmailAddressPolicyEnabled
            EmailAddresses = @($mailbox.EmailAddresses) -join ', '
        })

        if ($IncludeCalendarItems) {
            $graphUser = Invoke-OptionalDiagnosticStep -Operation 'Resolve Graph calendar user' -MailboxIdentity $smtp -Errors $errors -ScriptBlock {
                Get-MgUser -UserId $smtp -Property Id,DisplayName,Mail,UserPrincipalName -ErrorAction Stop
            }
            if ($null -ne $graphUser) {
                $events = Invoke-OptionalDiagnosticStep -Operation 'Get calendar view' -MailboxIdentity $guid -Errors $errors -ScriptBlock {
                    Get-MgUserCalendarView -UserId $graphUser.Id -StartDateTime $StartDate.ToUniversalTime().ToString('o') -EndDateTime $EndDate.ToUniversalTime().ToString('o') -All -ErrorAction Stop
                }
                foreach ($event in @($events)) {
                    $calendarItems.Add([pscustomobject]@{
                        ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; EventId = [string]$event.Id
                        Subject = [string]$event.Subject; Start = [string]$event.Start.DateTime; StartTimeZone = [string]$event.Start.TimeZone
                        End = [string]$event.End.DateTime; EndTimeZone = [string]$event.End.TimeZone
                        IsAllDay = $event.IsAllDay; IsCancelled = $event.IsCancelled; IsOnlineMeeting = $event.IsOnlineMeeting
                        OnlineMeetingProvider = [string]$event.OnlineMeetingProvider; Organizer = [string]$event.Organizer.EmailAddress.Address
                        Location = [string]$event.Location.DisplayName; AttendeeCount = @($event.Attendees).Count
                        ShowAs = [string]$event.ShowAs; Sensitivity = [string]$event.Sensitivity
                        CreatedDateTime = [string]$event.CreatedDateTime; LastModifiedDateTime = [string]$event.LastModifiedDateTime
                    })
                }
            }
        }

        if ($IncludeMessageTrace -and (Get-Command Get-MessageTraceV2 -ErrorAction SilentlyContinue)) {
            $traces = Invoke-OptionalDiagnosticStep -Operation 'Get message trace' -MailboxIdentity $smtp -Errors $errors -ScriptBlock {
                @(Get-MessageTraceV2 -RecipientAddress $smtp -StartDate $StartDate.ToUniversalTime() -EndDate $EndDate.ToUniversalTime() -ErrorAction Stop)
            }
            foreach ($trace in @($traces)) {
                $messageTrace.Add([pscustomobject]@{
                    ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; Received = $trace.Received
                    SenderAddress = [string]$trace.SenderAddress; RecipientAddress = [string]$trace.RecipientAddress
                    Subject = [string]$trace.Subject; Status = [string]$trace.Status; MessageTraceId = [string]$trace.MessageTraceId
                })
            }
        }

        $summary.Add([pscustomobject]@{
            ExchangeGuid = $guid; PrimarySmtpAddress = $smtp; DisplayName = $mailbox.DisplayName
            RecipientTypeDetails = $mailbox.RecipientTypeDetails; CalendarFolderCount = @($folderStats).Count
            CalendarPermissionCount = @($folderPermission).Count; CalendarItemsFound = @($calendarItems | Where-Object ExchangeGuid -eq $guid).Count
            CalendarPublished = if ($null -eq $published) { $null } else { $published.PublishEnabled }
            PublishedDetailLevel = if ($null -eq $published) { $null } else { [string]$published.DetailLevel }
            PublishedCalendarUrl = if ($null -eq $published) { $null } else { [string]$published.PublishedCalendarUrl }
            ForwardingConfigured = (-not [string]::IsNullOrWhiteSpace([string]$mailbox.ForwardingSmtpAddress)) -or $null -ne $mailbox.ForwardingAddress
            MessageTraceCount = @($messageTrace | Where-Object ExchangeGuid -eq $guid).Count
        })
    }
}
finally {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $summary | Sort-Object PrimarySmtpAddress | Export-Csv (Join-Path $resolvedOutput "CalendarSummary-$stamp.csv") -NoTypeInformation -Encoding UTF8
    $calendarFolders | Export-Csv (Join-Path $resolvedOutput "CalendarFolders-$stamp.csv") -NoTypeInformation -Encoding UTF8
    $calendarPermissions | Export-Csv (Join-Path $resolvedOutput "CalendarPermissions-$stamp.csv") -NoTypeInformation -Encoding UTF8
    $calendarProcessing | Export-Csv (Join-Path $resolvedOutput "CalendarProcessing-$stamp.csv") -NoTypeInformation -Encoding UTF8
    $routing | Export-Csv (Join-Path $resolvedOutput "Routing-$stamp.csv") -NoTypeInformation -Encoding UTF8
    if ($IncludeCalendarItems) { $calendarItems | Export-Csv (Join-Path $resolvedOutput "CalendarItems-$stamp.csv") -NoTypeInformation -Encoding UTF8 }
    if ($IncludeMessageTrace) { $messageTrace | Export-Csv (Join-Path $resolvedOutput "MessageTrace-$stamp.csv") -NoTypeInformation -Encoding UTF8 }
    $errors | Export-Csv (Join-Path $resolvedOutput "Errors-$stamp.csv") -NoTypeInformation -Encoding UTF8

    [pscustomobject]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
        StartDate = $StartDate.ToUniversalTime().ToString('o'); EndDate = $EndDate.ToUniversalTime().ToString('o')
        RequestedIdentities = $identities.Count; MailboxesResolved = $summary.Count
        CalendarItems = $calendarItems.Count; MessageTraces = $messageTrace.Count; Errors = $errors.Count
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $resolvedOutput "Manifest-$stamp.json") -Encoding UTF8

    if ($Disconnect -and $connectedHere -and (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Write-Output "Calendar diagnostic complete: $resolvedOutput"