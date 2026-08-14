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
        '$schema'      = "./dashboard.schema.json"
        SchemaVersion  = "2026-08-14"
        GeneratedUtc   = ""
        RetentionPolicies = @()
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
        [string]$GeneratedUtc,

        [Parameter()]
        [psobject[]]$RetentionPolicies = @()
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
            retention          = if ($entry.PSObject.Properties.Name -contains "Retention") { $entry.Retention } else { $null }
            licensing          = if ($entry.PSObject.Properties.Name -contains "Licensing") { $entry.Licensing } else { $null }
            mailboxMaintenance = if ($entry.PSObject.Properties.Name -contains "MailboxMaintenance") { $entry.MailboxMaintenance } else { $null }
            lastCleanupSuccessUtc = if ($entry.PSObject.Properties.Name -contains "LastCleanupSuccessUtc") { $entry.LastCleanupSuccessUtc } else { $null }
            cleanupStatus = if ($entry.PSObject.Properties.Name -contains "CleanupStatus") { $entry.CleanupStatus } else { $null }
            daysSinceSuccessfulCleanup = if ($entry.PSObject.Properties.Name -contains "DaysSinceSuccessfulCleanup") { $entry.DaysSinceSuccessfulCleanup } else { $null }
            permissions        = @($entry.Permissions)
        }
    }

    return [pscustomobject]@{
        '$schema' = "./dashboard.schema.json"
        SchemaVersion = "2026-08-14"
        GeneratedUtc = $GeneratedUtc
        RetentionPolicies = @($RetentionPolicies)
        Mailboxes    = @($mailboxes)
    }
}

function Get-RetentionPolicyNameForEntry {
    param(
        [Parameter(Mandatory)]
        [psobject]$Entry
    )

    if ($Entry.PSObject.Properties.Name -contains "Retention" -and $null -ne $Entry.Retention) {
        $retention = $Entry.Retention
        if ($retention.PSObject.Properties.Name -contains "RetentionPolicy" -and -not [string]::IsNullOrWhiteSpace([string]$retention.RetentionPolicy)) {
            return [string]$retention.RetentionPolicy
        }
    }

    return $null
}

function Build-RetentionPolicyCatalog {
    param(
        [Parameter(Mandatory)]
        [psobject[]]$MailboxHistory,

        [Parameter()]
        [psobject[]]$SeedPolicies = @()
    )

    $seedIndex = @{}
    foreach ($seedPolicy in @($SeedPolicies)) {
        if ($null -eq $seedPolicy -or [string]::IsNullOrWhiteSpace([string]$seedPolicy.Name)) {
            continue
        }

        $seedIndex[[string]$seedPolicy.Name.ToLowerInvariant()] = $seedPolicy
    }

    $mailboxCountsByPolicy = @{}
    foreach ($entry in $MailboxHistory) {
        if ($null -eq $entry) {
            continue
        }

        $policyName = Get-RetentionPolicyNameForEntry -Entry $entry
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            continue
        }

        $policyKey = $policyName.ToLowerInvariant()
        if (-not $mailboxCountsByPolicy.ContainsKey($policyKey)) {
            $mailboxCountsByPolicy[$policyKey] = [pscustomobject]@{
                Name  = $policyName
                Count = 0
            }
        }

        $mailboxCountsByPolicy[$policyKey].Count += 1
    }

    $catalogKeys = @($seedIndex.Keys + $mailboxCountsByPolicy.Keys | Sort-Object -Unique)
    $catalog = foreach ($catalogKey in $catalogKeys) {
        $mailboxCount = if ($mailboxCountsByPolicy.ContainsKey($catalogKey)) { [int]$mailboxCountsByPolicy[$catalogKey].Count } else { 0 }
        if ($seedIndex.ContainsKey($catalogKey)) {
            $seedPolicy = $seedIndex[$catalogKey]
            [pscustomobject]@{
                Name                    = [string]$seedPolicy.Name
                IsKnownPolicy           = if ($seedPolicy.PSObject.Properties.Name -contains "IsKnownPolicy") { [bool]$seedPolicy.IsKnownPolicy } else { $true }
                MailboxCount            = $mailboxCount
                IsDefaultPolicy         = if ($seedPolicy.PSObject.Properties.Name -contains "IsDefaultPolicy") { $seedPolicy.IsDefaultPolicy } else { $null }
                RetentionId             = if ($seedPolicy.PSObject.Properties.Name -contains "RetentionId") { $seedPolicy.RetentionId } else { $null }
                RetentionPolicyTagLinks = if ($seedPolicy.PSObject.Properties.Name -contains "RetentionPolicyTagLinks") { @($seedPolicy.RetentionPolicyTagLinks) } else { @() }
                TagCount                = if ($seedPolicy.PSObject.Properties.Name -contains "TagCount" -and $null -ne $seedPolicy.TagCount) { [int]$seedPolicy.TagCount } else { 0 }
                Comment                 = if ($seedPolicy.PSObject.Properties.Name -contains "Comment") { $seedPolicy.Comment } else { $null }
            }
        }
        else {
            [pscustomobject]@{
                Name                    = [string]$mailboxCountsByPolicy[$catalogKey].Name
                IsKnownPolicy           = $false
                MailboxCount            = $mailboxCount
                IsDefaultPolicy         = $null
                RetentionId             = $null
                RetentionPolicyTagLinks = @()
                TagCount                = 0
                Comment                 = "Policy is assigned to one or more mailboxes but was not returned in source metadata."
            }
        }
    }

    return @($catalog | Sort-Object -Property @{ Expression = { -1 * [int]$_.MailboxCount } }, @{ Expression = { [string]$_.Name } })
}

function Apply-RetentionPolicyDetailsToMailboxHistory {
    param(
        [Parameter(Mandatory)]
        [psobject[]]$MailboxHistory,

        [Parameter(Mandatory)]
        [psobject[]]$RetentionPolicies
    )

    $policyIndex = @{}
    foreach ($policy in $RetentionPolicies) {
        if ($null -eq $policy -or [string]::IsNullOrWhiteSpace([string]$policy.Name)) {
            continue
        }

        $policyIndex[[string]$policy.Name.ToLowerInvariant()] = $policy
    }

    foreach ($entry in $MailboxHistory) {
        if ($null -eq $entry -or -not ($entry.PSObject.Properties.Name -contains "Retention") -or $null -eq $entry.Retention) {
            continue
        }

        $policyName = Get-RetentionPolicyNameForEntry -Entry $entry
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            $entry.Retention.RetentionPolicyDetails = $null
            continue
        }

        $policyKey = $policyName.ToLowerInvariant()
        if (-not $policyIndex.ContainsKey($policyKey)) {
            $entry.Retention.RetentionPolicyDetails = [pscustomobject]@{
                Name            = $policyName
                IsKnownPolicy   = $false
                MailboxCount    = 0
                IsDefaultPolicy = $null
                RetentionId     = $null
                TagCount        = 0
                Comment         = "Policy was not found in retention policy catalog."
            }
            continue
        }

        $policy = $policyIndex[$policyKey]
        $entry.Retention.RetentionPolicyDetails = [pscustomobject]@{
            Name            = [string]$policy.Name
            IsKnownPolicy   = [bool]$policy.IsKnownPolicy
            MailboxCount    = [int]$policy.MailboxCount
            IsDefaultPolicy = $policy.IsDefaultPolicy
            RetentionId     = $policy.RetentionId
            TagCount        = if ($null -ne $policy.TagCount) { [int]$policy.TagCount } else { 0 }
            Comment         = $policy.Comment
        }
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
        if ($rawData.PSObject.Properties.Name -contains "Retention") { $entry.Retention = $rawData.Retention }
        if ($rawData.PSObject.Properties.Name -contains "Licensing") { $entry.Licensing = $rawData.Licensing }
        if ($rawData.PSObject.Properties.Name -contains "MailboxMaintenance") { $entry.MailboxMaintenance = $rawData.MailboxMaintenance }
        if ($rawData.PSObject.Properties.Name -contains "LastCleanupSuccessUtc") { $entry.LastCleanupSuccessUtc = $rawData.LastCleanupSuccessUtc }
        if ($rawData.PSObject.Properties.Name -contains "CleanupStatus") { $entry.CleanupStatus = $rawData.CleanupStatus }
        if ($rawData.PSObject.Properties.Name -contains "DaysSinceSuccessfulCleanup") { $entry.DaysSinceSuccessfulCleanup = $rawData.DaysSinceSuccessfulCleanup }
        $entry.Samples = @($sampleList)
    }
    else {
        $entry = [pscustomobject]@{
            ExchangeGuid       = $exchangeGuid
            PrimarySmtpAddress = [string]$rawData.PrimarySmtpAddress
            DisplayName        = [string]$rawData.DisplayName
            Permissions        = Convert-PermissionSet -Permissions $rawData.Permissions
            Retention          = if ($rawData.PSObject.Properties.Name -contains "Retention") { $rawData.Retention } else { $null }
            Licensing          = if ($rawData.PSObject.Properties.Name -contains "Licensing") { $rawData.Licensing } else { $null }
            MailboxMaintenance = if ($rawData.PSObject.Properties.Name -contains "MailboxMaintenance") { $rawData.MailboxMaintenance } else { $null }
            LastCleanupSuccessUtc = if ($rawData.PSObject.Properties.Name -contains "LastCleanupSuccessUtc") { $rawData.LastCleanupSuccessUtc } else { $null }
            CleanupStatus = if ($rawData.PSObject.Properties.Name -contains "CleanupStatus") { $rawData.CleanupStatus } else { $null }
            DaysSinceSuccessfulCleanup = if ($rawData.PSObject.Properties.Name -contains "DaysSinceSuccessfulCleanup") { $rawData.DaysSinceSuccessfulCleanup } else { $null }
            Samples            = @($sample)
        }

        $mailboxHistory.Add($entry)
        $historyIndex[$exchangeGuid] = $entry
    }

    if ($rawData.TimestampUtc) {
        $generatedUtc = [string]$rawData.TimestampUtc
    }
}

$seedRetentionPolicies = if ($historyPayload.PSObject.Properties.Name -contains "RetentionPolicies") { @($historyPayload.RetentionPolicies) } else { @() }
$retentionPolicies = Build-RetentionPolicyCatalog -MailboxHistory @($mailboxHistory) -SeedPolicies @($seedRetentionPolicies)
Apply-RetentionPolicyDetailsToMailboxHistory -MailboxHistory @($mailboxHistory) -RetentionPolicies @($retentionPolicies)

$historyOutput = [pscustomobject]@{
    '$schema'      = "./dashboard.schema.json"
    SchemaVersion  = "2026-08-14"
    GeneratedUtc   = $generatedUtc
    RetentionPolicies = @($retentionPolicies)
    MailboxHistory = @($mailboxHistory)
}
$hotDataOutput = Convert-HistoryToHotData -MailboxHistory @($mailboxHistory) -GeneratedUtc $generatedUtc -RetentionPolicies @($retentionPolicies)

$historyOutput | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resolvedHistoryPath -Encoding utf8
$hotDataOutput | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedHotDataPath -Encoding utf8

Write-Host "Merged $($threadFiles.Count) file(s), updated '$resolvedHistoryPath', and regenerated '$resolvedHotDataPath'." -ForegroundColor Green
