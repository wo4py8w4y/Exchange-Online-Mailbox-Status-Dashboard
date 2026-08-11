[CmdletBinding()]
param(
    [string]$TempDir = ".\Temp\ThreadJobs",
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

function New-EmptyHistoryData {
    return [pscustomobject]@{
        GeneratedUtc   = ""
        MailboxHistory = @()
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

function Convert-HistoryToHotData {
    param(
        [Parameter(Mandatory)]
        [psobject[]]$MailboxHistory,

        [Parameter()]
        [string]$GeneratedUtc
    )

    $mailboxes = foreach ($entry in $MailboxHistory) {
        $samples = @($entry.Samples)
        if ($samples.Count -eq 0) {
            continue
        }

        $latestSample = $samples[-1]
        [pscustomobject]@{
            ExchangeGuid       = [string]$entry.ExchangeGuid
            PrimarySmtpAddress = [string]$entry.PrimarySmtpAddress
            DisplayName        = [string]$entry.DisplayName
            current            = [pscustomobject]@{
                totalGB          = if ($null -ne $latestSample.SizeGB) { [double]$latestSample.SizeGB } else { 0.0 }
                itemCount        = if ($null -ne $latestSample.ItemCount) { [int64]$latestSample.ItemCount } else { 0 }
                quotaGB          = if ($null -ne $latestSample.QuotaGB) { [double]$latestSample.QuotaGB } else { $null }
                usagePercent     = if ($null -ne $latestSample.UsagePercent) { [double]$latestSample.UsagePercent } else { $null }
                lastLogonTime    = $latestSample.LastLogonTime
                archiveEnabled   = [bool]$latestSample.ArchiveEnabled
                archiveSizeGB    = if ($null -ne $latestSample.ArchiveSizeGB) { [double]$latestSample.ArchiveSizeGB } else { 0.0 }
                archiveItemCount = if ($null -ne $latestSample.ArchiveItemCount) { [int64]$latestSample.ArchiveItemCount } else { 0 }
            }
            permissions        = @($entry.Permissions)
        }
    }

    return [pscustomobject]@{
        GeneratedUtc = $GeneratedUtc
        Mailboxes    = @($mailboxes)
    }
}

Write-Host "Merging threaded mailbox JSON files..." -ForegroundColor Cyan

$resolvedTempDir = Resolve-AbsolutePath -Path $TempDir
$resolvedHistoryPath = Resolve-AbsolutePath -Path $HistoryPath
$resolvedHotDataPath = Resolve-AbsolutePath -Path $HotDataPath

$threadFiles = @(Get-ChildItem -LiteralPath $resolvedTempDir -Filter "*.json" -File -ErrorAction Stop)
if ($threadFiles.Count -eq 0) {
    throw "No thread files found in '$resolvedTempDir'. Run Start-HistoryCollectorThreaded.ps1 first."
}

$historyPayload = if (Test-Path -LiteralPath $resolvedHistoryPath) {
    try {
        Get-Content -LiteralPath $resolvedHistoryPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Existing history.json was invalid. Rebuilding from thread output."
        New-EmptyHistoryData
    }
}
else {
    New-EmptyHistoryData
}

$historyIndex = @{}
$mailboxHistory = [System.Collections.Generic.List[object]]::new()
foreach ($entry in @($historyPayload.MailboxHistory)) {
    if ($null -eq $entry) {
        continue
    }

    $mailboxHistory.Add($entry)
    if ($entry.ExchangeGuid) {
        $historyIndex[[string]$entry.ExchangeGuid] = $entry
    }
}

$generatedUtc = [string]$historyPayload.GeneratedUtc

foreach ($file in $threadFiles) {
    $rawData = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $exchangeGuid = [string]$rawData.ExchangeGuid
    if ([string]::IsNullOrWhiteSpace($exchangeGuid)) {
        Write-Warning "Skipping '$($file.Name)' because ExchangeGuid was empty."
        continue
    }

    $usagePercent = if ($null -ne $rawData.UsagePercent) {
        [double]$rawData.UsagePercent
    }
    elseif ($rawData.QuotaGB -gt 0) {
        [math]::Round(([double]$rawData.SizeGB / [double]$rawData.QuotaGB) * 100, 2)
    }
    else {
        $null
    }

    $sample = [pscustomobject]@{
        TimestampUtc     = $rawData.TimestampUtc
        SizeGB           = if ($null -ne $rawData.SizeGB) { [double]$rawData.SizeGB } else { 0.0 }
        ItemCount        = if ($null -ne $rawData.ItemCount) { [int64]$rawData.ItemCount } else { 0 }
        PermissionCount  = if ($rawData.Permissions) { @($rawData.Permissions).Count } else { 0 }
        QuotaGB          = if ($null -ne $rawData.QuotaGB) { [double]$rawData.QuotaGB } else { $null }
        UsagePercent     = $usagePercent
        LastLogonTime    = $rawData.LastLogonTime
        ArchiveEnabled   = [bool]$rawData.ArchiveEnabled
        ArchiveSizeGB    = if ($null -ne $rawData.ArchiveSizeGB) { [double]$rawData.ArchiveSizeGB } else { 0.0 }
        ArchiveItemCount = if ($null -ne $rawData.ArchiveItemCount) { [int64]$rawData.ArchiveItemCount } else { 0 }
    }

    if ($historyIndex.ContainsKey($exchangeGuid)) {
        $entry = $historyIndex[$exchangeGuid]
        $sampleList = [System.Collections.Generic.List[object]]::new()
        foreach ($existingSample in @($entry.Samples)) {
            $sampleList.Add($existingSample)
        }

        $sampleList.Add($sample)
        $entry.PrimarySmtpAddress = [string]$rawData.PrimarySmtpAddress
        $entry.DisplayName = [string]$rawData.DisplayName
        $entry.Permissions = Convert-PermissionSet -Permissions $rawData.Permissions
        $entry.Samples = @($sampleList)
    }
    else {
        $entry = [pscustomobject]@{
            ExchangeGuid       = $exchangeGuid
            PrimarySmtpAddress = [string]$rawData.PrimarySmtpAddress
            DisplayName        = [string]$rawData.DisplayName
            Permissions        = Convert-PermissionSet -Permissions $rawData.Permissions
            Samples            = @($sample)
        }

        $mailboxHistory.Add($entry)
        $historyIndex[$exchangeGuid] = $entry
    }

    if ($rawData.TimestampUtc) {
        $generatedUtc = [string]$rawData.TimestampUtc
    }
}

$historyOutput = [pscustomobject]@{
    GeneratedUtc   = $generatedUtc
    MailboxHistory = @($mailboxHistory)
}
$hotDataOutput = Convert-HistoryToHotData -MailboxHistory @($mailboxHistory) -GeneratedUtc $generatedUtc

$historyOutput | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resolvedHistoryPath -Encoding utf8
$hotDataOutput | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedHotDataPath -Encoding utf8

Write-Host "Merged $($threadFiles.Count) file(s), updated '$resolvedHistoryPath', and regenerated '$resolvedHotDataPath'." -ForegroundColor Green
