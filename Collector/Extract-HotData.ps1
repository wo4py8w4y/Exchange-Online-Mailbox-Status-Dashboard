[CmdletBinding()]
param (
    [string]$HistoryPath = "..\Web\history.json",
    [string]$HotDataPath = "..\Web\data.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [string]$BaseDirectory = $PSScriptRoot
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $Path))
}

function New-EmptyHotData {
    param(
        [string]$GeneratedUtc
    )

    return [pscustomobject]@{
        GeneratedUtc = $GeneratedUtc
        Mailboxes    = @()
    }
}

function Convert-PermissionSet {
    param(
        [Parameter()]
        $Permissions
    )

    if ($null -eq $Permissions) {
        return @()
    }

    return @(
        foreach ($permission in @($Permissions)) {
            if ($null -eq $permission) {
                continue
            }

            [pscustomobject]@{
                User         = [string]$permission.User
                AccessRights = @($permission.AccessRights)
                IsInherited  = [bool]$permission.IsInherited
                Deny         = [bool]$permission.Deny
            }
        }
    )
}

Write-Host "Extracting hot data from mailbox history..." -ForegroundColor Cyan

$resolvedHistoryPath = Resolve-AbsolutePath -Path $HistoryPath
$resolvedHotDataPath = Resolve-AbsolutePath -Path $HotDataPath

if (-not (Test-Path -LiteralPath $resolvedHistoryPath)) {
    throw "History file not found at '$resolvedHistoryPath'."
}

$historyPayload = Get-Content -LiteralPath $resolvedHistoryPath -Raw | ConvertFrom-Json
$mailboxHistory = @($historyPayload.MailboxHistory)

$hotDataPayload = New-EmptyHotData -GeneratedUtc ([string]$historyPayload.GeneratedUtc)
$mailboxes = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $mailboxHistory) {
    if ($null -eq $entry) {
        continue
    }

    $samples = @($entry.Samples)
    if ($samples.Count -eq 0) {
        continue
    }

    $latestSample = $samples[-1]
    $permissions = if ($entry.PSObject.Properties.Name -contains "Permissions") {
        Convert-PermissionSet -Permissions $entry.Permissions
    }
    elseif ($latestSample.PSObject.Properties.Name -contains "Permissions") {
        Convert-PermissionSet -Permissions $latestSample.Permissions
    }
    else {
        @()
    }

    $mailboxes.Add([pscustomobject]@{
        ExchangeGuid       = [string]$entry.ExchangeGuid
        PrimarySmtpAddress = [string]$entry.PrimarySmtpAddress
        DisplayName        = [string]$entry.DisplayName
        current            = [pscustomobject]@{
            totalGB         = if ($null -ne $latestSample.SizeGB) { [double]$latestSample.SizeGB } else { 0.0 }
            itemCount       = if ($null -ne $latestSample.ItemCount) { [int64]$latestSample.ItemCount } else { 0 }
            quotaGB         = if ($null -ne $latestSample.QuotaGB) { [double]$latestSample.QuotaGB } else { $null }
            usagePercent    = if ($null -ne $latestSample.UsagePercent) { [double]$latestSample.UsagePercent } else { $null }
            lastLogonTime   = if ($latestSample.PSObject.Properties.Name -contains "LastLogonTime") { $latestSample.LastLogonTime } else { $null }
            archiveEnabled  = [bool]$latestSample.ArchiveEnabled
            archiveSizeGB   = if ($null -ne $latestSample.ArchiveSizeGB) { [double]$latestSample.ArchiveSizeGB } else { 0.0 }
            archiveItemCount = if ($null -ne $latestSample.ArchiveItemCount) { [int64]$latestSample.ArchiveItemCount } else { 0 }
        }
        permissions        = $permissions
    })
}

$hotDataPayload.Mailboxes = @($mailboxes | Sort-Object -Property @{ Expression = { $_.displayName } }, @{ Expression = { $_.primarySmtpAddress } })

$outputDirectory = Split-Path -Path $resolvedHotDataPath -Parent
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$hotDataPayload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedHotDataPath -Encoding utf8

Write-Host "Wrote $($hotDataPayload.Mailboxes.Count) current mailbox records to '$resolvedHotDataPath'." -ForegroundColor Green
