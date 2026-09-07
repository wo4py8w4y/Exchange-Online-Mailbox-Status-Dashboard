<#
.SYNOPSIS
    Generates synthetic mailbox data so the dashboard can be exercised without Exchange.
.DESCRIPTION
    Produces history.json and data.json in the same shape the real collector writes,
    including growth trends, archives, permissions, over-quota and unlimited-quota
    mailboxes, so every dashboard feature has something to display.

    By default it writes to the demo paths in the configuration and leaves real data
    untouched. Use -Live to overwrite the actual dashboard files.
.PARAMETER MailboxCount
    How many synthetic mailboxes to create.
.PARAMETER Days
    How many days of history to generate, one sample per day.
.PARAMETER Live
    Write to the real history.json and data.json instead of the demo files.
.EXAMPLE
    .\New-MailboxDashboardTestData.ps1
    Writes 250 mailboxes with 30 days of history to the demo files.
.EXAMPLE
    .\New-MailboxDashboardTestData.ps1 -MailboxCount 50 -Days 90 -Live
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateRange(1, 100000)]
    [int]$MailboxCount = 250,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$Days = 30,

    [Parameter()]
    [string]$Domain = "contoso.com",

    [Parameter()]
    [int]$Seed = 20260907,

    [Parameter()]
    [switch]$Live,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$DataJsonPath,

    [Parameter()]
    [switch]$WriteCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

$script:Random = [System.Random]::new($Seed)

$script:Departments = @(
    "Finance", "Payroll", "Facilities", "Procurement", "Legal", "Records",
    "Service Desk", "Infrastructure", "Housing", "Projects", "Communications", "Fleet"
)

$script:Teams = @(
    "Admin", "Support", "Enquiries", "Reporting", "Operations", "Shared",
    "Approvals", "Intake", "Archive", "Coordination"
)

$script:Sites = @("Brisbane", "Cairns", "Townsville", "Toowoomba", "Rockhampton", "Mackay")

$script:AccessRights = @(
    @("FullAccess"),
    @("SendAs"),
    @("FullAccess", "SendAs"),
    @("ReadPermission"),
    @("SendOnBehalf")
)

function Get-RandomDouble {
    param(
        [Parameter(Mandatory)] [double]$Minimum,
        [Parameter(Mandatory)] [double]$Maximum
    )

    return $Minimum + ($script:Random.NextDouble() * ($Maximum - $Minimum))
}

function Get-RandomItem {
    param(
        [Parameter(Mandatory)] $Items
    )

    $array = @($Items)
    return $array[$script:Random.Next(0, $array.Count)]
}

function New-MailboxProfile {
<#
.SYNOPSIS
    Invents one mailbox and the behaviour its history should follow.
#>
    param(
        [Parameter(Mandatory)] [int]$Index
    )

    $department = Get-RandomItem -Items $script:Departments
    $team = Get-RandomItem -Items $script:Teams
    $site = Get-RandomItem -Items $script:Sites

    $displayName = "$department $team $site"
    $localPart = ("{0}.{1}{2:D3}" -f $department.Replace(" ", ""), $team, $Index).ToLowerInvariant()

    # A deliberate spread so the dashboard has healthy, warning, critical, over-quota
    # and unlimited mailboxes to render rather than one uniform band.
    $roll = $script:Random.Next(0, 100)
    $usageProfile = if ($roll -lt 4) { "over-quota" }
        elseif ($roll -lt 10) { "critical" }
        elseif ($roll -lt 20) { "warning" }
        elseif ($roll -lt 24) { "unlimited" }
        elseif ($roll -lt 30) { "dormant" }
        else { "healthy" }

    $quotaGb = if ($usageProfile -eq "unlimited") { $null } else { Get-RandomItem -Items @(50, 50, 50, 100, 100, 25) }

    $startUsage = switch ($usageProfile) {
        "over-quota" { Get-RandomDouble -Minimum 1.02 -Maximum 1.45 }
        "critical"   { Get-RandomDouble -Minimum 0.90 -Maximum 0.97 }
        "warning"    { Get-RandomDouble -Minimum 0.78 -Maximum 0.89 }
        "dormant"    { Get-RandomDouble -Minimum 0.01 -Maximum 0.05 }
        "unlimited"  { Get-RandomDouble -Minimum 0.10 -Maximum 0.60 }
        default      { Get-RandomDouble -Minimum 0.05 -Maximum 0.70 }
    }

    $referenceQuota = if ($null -eq $quotaGb) { 100 } else { $quotaGb }

    $archiveEnabled = $script:Random.Next(0, 100) -lt 45

    # Growth is a fraction of quota per day; kept low so a long history does not
    # push most of the tenant over quota by the last sample.
    $dailyGrowth = switch ($usageProfile) {
        "dormant"    { Get-RandomDouble -Minimum 0.0000 -Maximum 0.0002 }
        "over-quota" { Get-RandomDouble -Minimum 0.0002 -Maximum 0.0010 }
        "critical"   { Get-RandomDouble -Minimum 0.0001 -Maximum 0.0008 }
        "warning"    { Get-RandomDouble -Minimum 0.0002 -Maximum 0.0012 }
        default      { Get-RandomDouble -Minimum 0.0003 -Maximum 0.0030 }
    }

    return [pscustomobject]@{
        ExchangeGuid   = [guid]::NewGuid().ToString()
        DisplayName    = $displayName
        SmtpAddress    = "$localPart@$Domain"
        UsageProfile   = $usageProfile
        QuotaGB        = $quotaGb
        StartSizeGB    = [math]::Round(($referenceQuota * $startUsage), 2)
        DailyGrowthGB  = [math]::Round(($referenceQuota * $dailyGrowth), 3)
        ArchiveEnabled = $archiveEnabled
        StartItemCount = $script:Random.Next(500, 90000)
        LastLogonDays  = if ($usageProfile -eq "dormant") { $script:Random.Next(120, 900) } else { $script:Random.Next(0, 14) }
    }
}

function New-PermissionSet {
    param(
        [Parameter(Mandatory)] $MailboxProfile
    )

    $roll = $script:Random.Next(0, 100)
    $count = if ($roll -lt 45) { 0 } elseif ($roll -lt 80) { $script:Random.Next(1, 5) } else { $script:Random.Next(5, 25) }

    if ($count -eq 0) {
        return @()
    }

    return @(
        for ($i = 1; $i -le $count; $i++) {
            [pscustomobject]@{
                User         = ("delegate{0:D2}.{1}@{2}" -f $i, (Get-RandomItem -Items $script:Teams).ToLowerInvariant(), $Domain)
                AccessRights = @(Get-RandomItem -Items $script:AccessRights)
                Deny         = $false
                IsInherited  = $false
            }
        }
    )
}

function New-MailboxHistoryRecord {
    param(
        [Parameter(Mandatory)] $MailboxProfile,
        [Parameter(Mandatory)] [datetime]$StartDate,
        [Parameter(Mandatory)] [int]$SampleCount
    )

    # @() guards the single-permission case, which would otherwise arrive as a scalar.
    $permissions = @(New-PermissionSet -MailboxProfile $MailboxProfile)
    $samples = [System.Collections.Generic.List[object]]::new()

    $sizeGb = [double]$MailboxProfile.StartSizeGB
    $itemCount = [int64]$MailboxProfile.StartItemCount
    $archiveSizeGb = if ($MailboxProfile.ArchiveEnabled) { Get-RandomDouble -Minimum 0.5 -Maximum 40 } else { 0.0 }
    $archiveItems = if ($MailboxProfile.ArchiveEnabled) { $script:Random.Next(1000, 200000) } else { 0 }

    for ($day = 0; $day -lt $SampleCount; $day++) {
        $timestamp = $StartDate.AddDays($day)

        # Random walk with an upward bias so charts show a believable trend.
        $jitter = Get-RandomDouble -Minimum -0.02 -Maximum 0.02
        $sizeGb = [math]::Max(0.01, $sizeGb + $MailboxProfile.DailyGrowthGB + $jitter)
        $itemCount = [int64][math]::Max(1, $itemCount + $script:Random.Next(-40, 260))

        if ($MailboxProfile.ArchiveEnabled) {
            $archiveSizeGb = [math]::Max(0, $archiveSizeGb + (Get-RandomDouble -Minimum -0.02 -Maximum 0.12))
            $archiveItems += $script:Random.Next(0, 120)
        }

        $roundedSize = [math]::Round($sizeGb, 2)
        $usagePercent = if ($null -eq $MailboxProfile.QuotaGB) { $null } else { [math]::Round((($roundedSize / $MailboxProfile.QuotaGB) * 100), 2) }

        $lastLogon = if ($day -eq ($SampleCount - 1)) {
            $timestamp.AddDays(-$MailboxProfile.LastLogonDays).ToString("o")
        }
        else {
            $timestamp.AddDays(-1).ToString("o")
        }

        $samples.Add([pscustomobject]@{
            TimestampUtc     = $timestamp.ToString("o")
            SizeGB           = $roundedSize
            ItemCount        = $itemCount
            PermissionCount  = $permissions.Count
            QuotaGB          = $MailboxProfile.QuotaGB
            UsagePercent     = $usagePercent
            LastLogonTime    = $lastLogon
            ArchiveEnabled   = $MailboxProfile.ArchiveEnabled
            ArchiveSizeGB    = [math]::Round($archiveSizeGb, 2)
            ArchiveItemCount = [int64]$archiveItems
        })
    }

    return [pscustomobject]@{
        ExchangeGuid       = $MailboxProfile.ExchangeGuid
        PrimarySmtpAddress = $MailboxProfile.SmtpAddress
        DisplayName        = $MailboxProfile.DisplayName
        Permissions        = $permissions
        Samples            = @($samples)
    }
}

# --- Entry point -------------------------------------------------------------

$configParams = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
$config = Import-MailboxDashboardConfig @configParams -SkipValidation

$resolvedHistoryPath = if ($PSBoundParameters.ContainsKey('HistoryJsonPath')) {
    Resolve-MailboxPath -Path $HistoryJsonPath -BaseDirectory $PWD.Path
}
elseif ($Live) {
    $config.ResolvedPaths.HistoryJson
}
else {
    $config.ResolvedPaths.DemoHistoryJson
}

$resolvedDataPath = if ($PSBoundParameters.ContainsKey('DataJsonPath')) {
    Resolve-MailboxPath -Path $DataJsonPath -BaseDirectory $PWD.Path
}
elseif ($Live) {
    $config.ResolvedPaths.DataJson
}
else {
    $config.ResolvedPaths.DemoDataJson
}

Write-Stage "Generating test data"

if ($Live) {
    Write-Attention "Writing to the LIVE dashboard files - real collected data will be overwritten."
}

Write-Detail "Mailboxes: $MailboxCount, history: $Days day(s), seed: $Seed"
Write-Detail "History: $resolvedHistoryPath"
Write-Detail "Data   : $resolvedDataPath"

if (-not $PSCmdlet.ShouldProcess("$resolvedHistoryPath and $resolvedDataPath", "Write synthetic dashboard data")) {
    return
}

$startDate = (Get-Date).ToUniversalTime().Date.AddDays(-($Days - 1))
$records = [System.Collections.Generic.List[object]]::new()
$snapshots = [System.Collections.Generic.List[object]]::new()

for ($i = 1; $i -le $MailboxCount; $i++) {
    $mailboxProfile = New-MailboxProfile -Index $i
    $record = New-MailboxHistoryRecord -MailboxProfile $mailboxProfile -StartDate $startDate -SampleCount $Days

    $records.Add($record)

    $latest = $record.Samples[-1]
    $snapshots.Add([pscustomobject]@{
        ExchangeGuid       = $record.ExchangeGuid
        PrimarySmtpAddress = $record.PrimarySmtpAddress
        DisplayName        = $record.DisplayName
        current            = [pscustomobject]@{
            totalGB          = $latest.SizeGB
            itemCount        = $latest.ItemCount
            quotaGB          = $latest.QuotaGB
            usagePercent     = $latest.UsagePercent
            lastLogonTime    = $latest.LastLogonTime
            archiveEnabled   = $latest.ArchiveEnabled
            archiveSizeGB    = $latest.ArchiveSizeGB
            archiveItemCount = $latest.ArchiveItemCount
            sampleTimestamp  = $latest.TimestampUtc
        }
        permissions        = $record.Permissions
    })

    Write-Item -Name "$($record.PrimarySmtpAddress)  $($latest.SizeGB)GB" -Index $i -Total $MailboxCount
}

$generatedUtc = $startDate.AddDays($Days - 1).ToString("o")

Write-MailboxJson `
    -InputObject ([pscustomobject]@{ GeneratedUtc = $generatedUtc; MailboxHistory = @($records) }) `
    -Path $resolvedHistoryPath `
    -Source "New-MailboxDashboardTestData.ps1 (synthetic, seed $Seed)" `
    -RecordCount $records.Count `
    -RecordDetail "$Days day(s) of samples" `
    -Depth 100

Write-MailboxJson `
    -InputObject ([pscustomobject]@{ GeneratedUtc = $generatedUtc; Mailboxes = @($snapshots) }) `
    -Path $resolvedDataPath `
    -Source "New-MailboxDashboardTestData.ps1 (synthetic, seed $Seed)" `
    -RecordCount $snapshots.Count `
    -Depth 20

if ($WriteCsv) {
    $csvPath = Join-Path -Path (Split-Path -Path $resolvedHistoryPath -Parent) -ChildPath "demo-mailboxes.csv"
    $records | Select-Object @{ Name = "PrimarySMTPAddress"; Expression = { $_.PrimarySmtpAddress } } |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    Write-Detail "Wrote mailbox list to $csvPath"
}

$profileCounts = $records | Group-Object -Property { 
    $sample = $_.Samples[-1]
    if ($null -eq $sample.QuotaGB) { "unlimited" }
    elseif ($sample.UsagePercent -ge 100) { "over quota" }
    elseif ($sample.UsagePercent -ge 94) { "critical" }
    elseif ($sample.UsagePercent -ge 85) { "warning" }
    else { "healthy" }
}

foreach ($group in ($profileCounts | Sort-Object -Property Name)) {
    Write-Detail "$($group.Name): $($group.Count)"
}

Write-Success "Test data ready."

[pscustomobject]@{
    Mailboxes    = $records.Count
    Days         = $Days
    Seed         = $Seed
    GeneratedUtc = $generatedUtc
    HistoryPath  = $resolvedHistoryPath
    DataPath     = $resolvedDataPath
    IsLive       = [bool]$Live
}
