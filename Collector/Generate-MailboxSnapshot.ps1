<#
.SYNOPSIS
    Rebuilds data.json, the latest-snapshot file the dashboard reads.
.DESCRIPTION
    Takes the newest sample for every mailbox in history.json and writes it to data.json
    in the shape the web UI expects. Records are keyed on ExchangeGuid throughout.
.PARAMETER StaleAfterDays
    Report mailboxes whose newest sample is older than this. They are still written, but
    a stale snapshot usually means the collector stopped covering those mailboxes.
.EXAMPLE
    .\Generate-MailboxSnapshot.ps1
    Rebuilds data.json from the configured history file.
.EXAMPLE
    .\Generate-MailboxSnapshot.ps1 -StaleAfterDays 7
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$DataJsonPath,

    [Parameter()]
    [int]$StaleAfterDays = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

function Get-LatestSample {
<#
.SYNOPSIS
    Returns the newest sample for a mailbox.
.DESCRIPTION
    Samples are normally stored in order, but a merge from several thread jobs can leave
    them unsorted, so the newest is chosen by timestamp rather than by position.
#>
    param(
        [Parameter()]
        $Samples
    )

    $list = @($Samples | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) {
        return $null
    }

    $newest = $null
    $newestTime = [datetime]::MinValue
    $sawTimestamp = $false

    foreach ($sample in $list) {
        $parsed = ConvertTo-DateTimeOrNull -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')

        if ($null -ne $parsed) {
            $sawTimestamp = $true
            if ($parsed -ge $newestTime) {
                $newestTime = $parsed
                $newest = $sample
            }
        }
    }

    if (-not $sawTimestamp) {
        return $list[-1]
    }

    return $newest
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
            if ($null -eq $permission) { continue }

            $rights = Get-PropertyValueOrNull -Object $permission -Name 'AccessRights'
            if ($null -eq $rights) { $rights = Get-PropertyValueOrNull -Object $permission -Name 'accessRights' }

            [pscustomobject]@{
                User         = [string](Get-PropertyValueOrNull -Object $permission -Name 'User')
                AccessRights = @($rights | ForEach-Object { [string]$_ })
                Deny         = [bool](Get-PropertyValueOrNull -Object $permission -Name 'Deny')
                IsInherited  = [bool](Get-PropertyValueOrNull -Object $permission -Name 'IsInherited')
            }
        }
    )
}

function ConvertTo-SnapshotRecord {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Sample
    )

    $sizeGb = [double](Get-PropertyValueOrNull -Object $Sample -Name 'SizeGB')
    $quotaRaw = Get-PropertyValueOrNull -Object $Sample -Name 'QuotaGB'
    $quotaGb = if ($null -eq $quotaRaw -or [string]$quotaRaw -eq 'Unlimited') { $null } else { [double]$quotaRaw }

    $usagePercent = Get-PropertyValueOrNull -Object $Sample -Name 'UsagePercent'
    if ($null -eq $usagePercent -and $null -ne $quotaGb -and $quotaGb -gt 0) {
        $usagePercent = [math]::Round((($sizeGb / $quotaGb) * 100), 2)
    }

    return [pscustomobject]@{
        ExchangeGuid       = [string](Get-PropertyValueOrNull -Object $Entry -Name 'ExchangeGuid')
        PrimarySmtpAddress = [string](Get-PropertyValueOrNull -Object $Entry -Name 'PrimarySmtpAddress')
        DisplayName        = [string](Get-PropertyValueOrNull -Object $Entry -Name 'DisplayName')
        Licensing          = Get-PropertyValueOrNull -Object $Entry -Name 'Licensing'
        current            = [pscustomobject]@{
            totalGB          = $sizeGb
            itemCount        = [int64](Get-PropertyValueOrNull -Object $Sample -Name 'ItemCount')
            quotaGB          = $quotaGb
            usagePercent     = $usagePercent
            lastLogonTime    = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $Sample -Name 'LastLogonTime')
            archiveEnabled   = [bool](Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveEnabled')
            archiveSizeGB    = [double](Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveSizeGB')
            archiveItemCount = [int64](Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveItemCount')
            sampleTimestamp  = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $Sample -Name 'TimestampUtc')
        }
        permissions        = Convert-PermissionSet -Permissions (Get-PropertyValueOrNull -Object $Entry -Name 'Permissions')
    }
}

# --- Entry point -------------------------------------------------------------

$configParams = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
$config = Import-MailboxDashboardConfig @configParams -SkipValidation

$resolvedHistoryPath = if ($PSBoundParameters.ContainsKey('HistoryJsonPath')) {
    Resolve-MailboxPath -Path $HistoryJsonPath -BaseDirectory $PWD.Path
}
else {
    $config.ResolvedPaths.HistoryJson
}

$resolvedDataPath = if ($PSBoundParameters.ContainsKey('DataJsonPath')) {
    Resolve-MailboxPath -Path $DataJsonPath -BaseDirectory $PWD.Path
}
else {
    $config.ResolvedPaths.DataJson
}

Write-Stage "Generating snapshot"

if (-not (Test-Path -LiteralPath $resolvedHistoryPath)) {
    throw "History file not found at '$resolvedHistoryPath'. Run the collector first."
}

$history = Read-MailboxJson -Path $resolvedHistoryPath
if ($null -eq $history) {
    throw "History file '$resolvedHistoryPath' is empty."
}

$entries = @(Get-PropertyValueOrNull -Object $history -Name 'MailboxHistory')
if ($entries.Count -eq 0) {
    Write-Notice "History contains no mailboxes; data.json will be empty."
}

Write-Detail "Source: $resolvedHistoryPath ($($entries.Count) mailboxes)"
Write-Detail "Target: $resolvedDataPath"

$snapshots = [System.Collections.Generic.List[object]]::new()
$skipped = 0
$stale = 0
$staleCutoff = if ($StaleAfterDays -gt 0) { (Get-Date).ToUniversalTime().AddDays(-$StaleAfterDays) } else { $null }
$newestOverall = [datetime]::MinValue
$counter = 0

foreach ($entry in $entries) {
    $counter++

    if ($null -eq $entry) {
        $skipped++
        continue
    }

    $guid = [string](Get-PropertyValueOrNull -Object $entry -Name 'ExchangeGuid')
    $label = [string](Get-PropertyValueOrNull -Object $entry -Name 'PrimarySmtpAddress')
    if ([string]::IsNullOrWhiteSpace($label)) { $label = $guid }

    if ([string]::IsNullOrWhiteSpace($guid)) {
        $skipped++
        Write-Item -Name $label -Index $counter -Total $entries.Count -Status "SKIPPED - no ExchangeGuid"
        continue
    }

    $sample = Get-LatestSample -Samples (Get-PropertyValueOrNull -Object $entry -Name 'Samples')

    if ($null -eq $sample) {
        $skipped++
        Write-Item -Name $label -Index $counter -Total $entries.Count -Status "SKIPPED - no samples"
        continue
    }

    try {
        $snapshots.Add((ConvertTo-SnapshotRecord -Entry $entry -Sample $sample))
    }
    catch {
        $skipped++
        Write-Item -Name $label -Index $counter -Total $entries.Count -Status "FAILED - $($_.Exception.Message)"
        Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0) -Context "Building snapshot for $label"
        continue
    }

    $timestampParsed = ConvertTo-DateTimeOrNull -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')
    if ($null -ne $timestampParsed) {
        if ($timestampParsed -gt $newestOverall) { $newestOverall = $timestampParsed }
        if ($null -ne $staleCutoff -and $timestampParsed -lt $staleCutoff) {
            $stale++
            Write-Item -Name $label -Index $counter -Total $entries.Count -Status "STALE - newest sample $($timestampParsed.ToString('yyyy-MM-dd'))"
            continue
        }
    }

    Write-Item -Name $label -Index $counter -Total $entries.Count
}

$generatedUtc = if ($newestOverall -gt [datetime]::MinValue) {
    $newestOverall.ToUniversalTime().ToString("o")
}
else {
    ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $history -Name 'GeneratedUtc')
}

if ([string]::IsNullOrWhiteSpace($generatedUtc)) {
    $generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
}

if ($PSCmdlet.ShouldProcess($resolvedDataPath, "Write snapshot")) {
    $document = [pscustomobject]@{
        GeneratedUtc = $generatedUtc
        Mailboxes    = @($snapshots)
    }

    Write-MailboxJson `
        -InputObject $document `
        -Path $resolvedDataPath `
        -Source "$resolvedHistoryPath (latest sample per ExchangeGuid)" `
        -RecordCount $snapshots.Count `
        -RecordDetail $(if ($skipped -gt 0) { "$skipped skipped" } else { $null }) `
        -Depth 20
}

Write-Detail "Snapshot covers $($snapshots.Count) of $($entries.Count) mailboxes."

if ($skipped -gt 0) {
    Write-Notice "$skipped mailbox(es) had no usable sample and were left out."
}

if ($stale -gt 0) {
    Write-Notice "$stale mailbox(es) have not been collected in the last $StaleAfterDays day(s)."
}

if ($skipped -eq 0 -and $stale -eq 0) {
    Write-Success "Snapshot generated cleanly."
}

[pscustomobject]@{
    MailboxesRead    = $entries.Count
    MailboxesWritten = $snapshots.Count
    Skipped          = $skipped
    Stale            = $stale
    GeneratedUtc     = $generatedUtc
    DataPath         = $resolvedDataPath
}
