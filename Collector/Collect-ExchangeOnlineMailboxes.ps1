<#
.SYNOPSIS
    Collects Exchange Online mailbox metrics and appends them to the history file.
.DESCRIPTION
    Reads the mailbox list, queries Exchange Online for size, quota, item count,
    permissions, and archive metrics, then appends one sample per mailbox to
    history.json keyed on ExchangeGuid.

    Requires an existing Exchange Online session - run Invoke-MailboxDashboardAuth.ps1
    first, or use -Connect to authenticate here.

    With -OutputPath the script writes only the mailboxes it collected to a standalone
    file instead of merging into history.json, which is how threaded collection produces
    its per-worker output for Merge-CollectionResults.ps1.
.PARAMETER Identity
    Collect only these addresses instead of every row in the CSV.
.PARAMETER Skip / -First
    Take a slice of the mailbox list, used to divide work between threads.
.EXAMPLE
    .\Collect-ExchangeOnlineMailboxes.ps1
    Collects every mailbox in the CSV and appends to history.json.
.EXAMPLE
    .\Collect-ExchangeOnlineMailboxes.ps1 -Identity user@contoso.com -Connect
    Authenticates, then collects a single mailbox.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string[]]$Identity,

    [Parameter()]
    [int]$Skip = 0,

    [Parameter()]
    [int]$First = 0,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BatchSize,

    [Parameter()]
    [string]$TimestampUtc,

    [Parameter()]
    [switch]$Connect,

    [Parameter()]
    [ValidateSet('Certificate', 'Interactive', 'Delegated', 'Auto')]
    [string]$AuthenticationMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

function Convert-PermissionSet {
<#
.SYNOPSIS
    Reduces raw mailbox permissions to the fields the dashboard displays.
#>
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

            [pscustomobject]@{
                User         = [string]$permission.User
                AccessRights = @($permission.AccessRights | ForEach-Object { [string]$_ })
                Deny         = [bool]$permission.Deny
            }
        }
    )
}

function Get-MailboxIdentityList {
<#
.SYNOPSIS
    Builds the list of addresses to collect from the CSV, honouring the slice parameters.
#>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [string[]]$Only,
        [Parameter()] [int]$SkipCount,
        [Parameter()] [int]$TakeCount
    )

    if ($null -ne $Only -and $Only.Count -gt 0) {
        return @($Only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Mailbox CSV not found at '$Path'."
    }

    $rows = @(Import-Csv -LiteralPath $Path)

    if ($rows.Count -eq 0) {
        return @()
    }

    $columns = @($rows[0].PSObject.Properties.Name)
    $addressColumn = @('PrimarySMTPAddress', 'PrimarySmtpAddress', 'Mailbox', 'EmailAddress', 'UserPrincipalName') |
        Where-Object { $columns -contains $_ } |
        Select-Object -First 1

    if ($null -eq $addressColumn) {
        throw "Mailbox CSV '$Path' needs an address column (PrimarySMTPAddress, Mailbox, EmailAddress, or UserPrincipalName). Found: $($columns -join ', ')."
    }

    $addresses = @(
        foreach ($row in $rows) {
            $value = [string]$row.$addressColumn
            if (-not [string]::IsNullOrWhiteSpace($value)) { $value.Trim() }
        }
    )

    if ($SkipCount -gt 0) {
        $addresses = @($addresses | Select-Object -Skip $SkipCount)
    }

    if ($TakeCount -gt 0) {
        $addresses = @($addresses | Select-Object -First $TakeCount)
    }

    return $addresses
}

function Get-QuotaGigabytes {
<#
.SYNOPSIS
    Returns the send/receive quota in GB, or $null when the mailbox is unlimited.
#>
    param(
        [Parameter()] $MailboxInfo
    )

    if ($null -eq $MailboxInfo -or $MailboxInfo.PSObject.Properties.Name -notcontains 'ProhibitSendReceiveQuota') {
        return $null
    }

    $quota = $MailboxInfo.ProhibitSendReceiveQuota

    if ($null -eq $quota -or [string]$quota -eq 'Unlimited') {
        return $null
    }

    $quotaGb = Convert-BytesToGigabytes -Bytes (Convert-ExoSizeToBytes -Value $quota) -Precision 2

    if ($quotaGb -le 0) {
        return $null
    }

    return $quotaGb
}

function Get-ArchiveMetric {
    param(
        [Parameter(Mandatory)] [string]$MailboxIdentity,
        [Parameter()] $MailboxInfo
    )

    $result = [pscustomobject]@{
        Enabled   = $false
        SizeGB    = 0.0
        ItemCount = [int64]0
    }

    $hasArchiveGuid = $false
    if ($MailboxInfo.PSObject.Properties.Name -contains 'ArchiveGuid' -and $null -ne $MailboxInfo.ArchiveGuid) {
        $hasArchiveGuid = ([string]$MailboxInfo.ArchiveGuid -ne [string][guid]::Empty)
    }

    $hasArchiveStatus = $false
    if ($MailboxInfo.PSObject.Properties.Name -contains 'ArchiveStatus' -and $null -ne $MailboxInfo.ArchiveStatus) {
        $hasArchiveStatus = ([string]$MailboxInfo.ArchiveStatus -ne 'None')
    }

    if (-not ($hasArchiveGuid -or $hasArchiveStatus)) {
        return $result
    }

    $result.Enabled = $true

    try {
        $archiveStats = Get-EXOMailboxStatistics -Identity $MailboxIdentity -Archive -ErrorAction Stop
        if ($null -ne $archiveStats) {
            $result.SizeGB = Convert-BytesToGigabytes -Bytes (Convert-ExoSizeToBytes -Value $archiveStats.TotalItemSize) -Precision 2
            $result.ItemCount = [int64]$archiveStats.ItemCount
        }
    }
    catch {
        # An enabled archive with unreadable statistics is common; keep the zeros.
        Write-Notice "Archive enabled for $MailboxIdentity but statistics were unavailable."
    }

    return $result
}

function Get-MailboxSample {
<#
.SYNOPSIS
    Queries Exchange Online for one mailbox and returns its record and sample.
#>
    param(
        [Parameter(Mandatory)] [string]$MailboxIdentity,
        [Parameter(Mandatory)] [string]$Timestamp
    )

    $mailboxInfo = Get-EXOMailbox -Identity $MailboxIdentity -Properties ExchangeGuid, ArchiveGuid, ArchiveStatus, ProhibitSendReceiveQuota -ErrorAction Stop
    $stats = Get-EXOMailboxStatistics -Identity $MailboxIdentity -ErrorAction Stop

    $sizeGb = Convert-BytesToGigabytes -Bytes (Convert-ExoSizeToBytes -Value $stats.TotalItemSize) -Precision 2
    $quotaGb = Get-QuotaGigabytes -MailboxInfo $mailboxInfo

    $usagePercent = $null
    if ($null -ne $quotaGb -and $quotaGb -gt 0) {
        $usagePercent = [math]::Round((($sizeGb / $quotaGb) * 100), 2)
    }

    $rawPermissions = @(
        Get-EXOMailboxPermission -Identity $MailboxIdentity -ErrorAction Stop |
            Where-Object { $_.IsInherited -eq $false -and $_.User -notmatch "NT AUTHORITY\\SELF|S-1-5-" }
    )
    $permissions = Convert-PermissionSet -Permissions $rawPermissions

    $archive = Get-ArchiveMetric -MailboxIdentity $MailboxIdentity -MailboxInfo $mailboxInfo

    $lastLogonTime = $null
    if ($stats.PSObject.Properties.Name -contains 'LastLogonTime' -and $stats.LastLogonTime) {
        try {
            $lastLogonTime = ([datetime]$stats.LastLogonTime).ToUniversalTime().ToString("o")
        }
        catch {
            $lastLogonTime = $null
        }
    }

    $sample = [pscustomobject]@{
        TimestampUtc     = $Timestamp
        SizeGB           = $sizeGb
        ItemCount        = [int64]$stats.ItemCount
        PermissionCount  = $permissions.Count
        QuotaGB          = $quotaGb
        UsagePercent     = $usagePercent
        LastLogonTime    = $lastLogonTime
        ArchiveEnabled   = $archive.Enabled
        ArchiveSizeGB    = $archive.SizeGB
        ArchiveItemCount = $archive.ItemCount
    }

    return [pscustomobject]@{
        ExchangeGuid       = [string]$mailboxInfo.ExchangeGuid
        PrimarySmtpAddress = [string]$mailboxInfo.PrimarySmtpAddress
        DisplayName        = [string]$mailboxInfo.DisplayName
        Permissions        = @($permissions)
        Sample             = $sample
    }
}

function Save-CollectionProgress {
    param(
        [Parameter(Mandatory)] $Records,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Timestamp,
        [Parameter(Mandatory)] [string]$Source,
        [Parameter()] [string]$Detail
    )

    $document = [pscustomobject]@{
        GeneratedUtc   = $Timestamp
        MailboxHistory = @($Records)
    }

    Write-MailboxJson `
        -InputObject $document `
        -Path $Path `
        -Source $Source `
        -RecordCount @($Records).Count `
        -RecordDetail $Detail `
        -Depth 100
}

# --- Entry point -------------------------------------------------------------

$configParams = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $configParams.AuthenticationMode = $AuthenticationMode }

$config = Import-MailboxDashboardConfig @configParams

$resolvedCsvPath = if ($PSBoundParameters.ContainsKey('CsvPath')) {
    Resolve-MailboxPath -Path $CsvPath -BaseDirectory $PWD.Path
}
else {
    $config.ResolvedPaths.MailboxesCsv
}

$resolvedHistoryPath = if ($PSBoundParameters.ContainsKey('HistoryJsonPath')) {
    Resolve-MailboxPath -Path $HistoryJsonPath -BaseDirectory $PWD.Path
}
else {
    $config.ResolvedPaths.HistoryJson
}

$isSliceOutput = -not [string]::IsNullOrWhiteSpace($OutputPath)
$resolvedOutputPath = if ($isSliceOutput) {
    Resolve-MailboxPath -Path $OutputPath -BaseDirectory $PWD.Path
}
else {
    $resolvedHistoryPath
}

$effectiveBatchSize = if ($PSBoundParameters.ContainsKey('BatchSize')) { $BatchSize } else { [int]$config.Collection.BatchSize }

$timestamp = if ($PSBoundParameters.ContainsKey('TimestampUtc')) {
    ([datetimeoffset]::Parse($TimestampUtc)).ToUniversalTime().ToString("o")
}
else {
    (Get-Date).ToUniversalTime().ToString("o")
}

if ($Connect) {
    . (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-MailboxDashboardAuth.ps1")
    $connectParams = @{ Config = $config }
    if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $connectParams.Mode = $AuthenticationMode }
    $null = Connect-MailboxDashboard @connectParams
}

Write-Stage "Collecting mailboxes"

try {
    $null = Get-EXOMailbox -ResultSize 1 -ErrorAction Stop
}
catch {
    throw "Exchange Online is not connected. Run Invoke-MailboxDashboardAuth.ps1 first, or add -Connect."
}

$identities = @(Get-MailboxIdentityList -Path $resolvedCsvPath -Only $Identity -SkipCount $Skip -TakeCount $First)

if ($identities.Count -eq 0) {
    Write-Notice "No mailboxes to collect."
    return [pscustomobject]@{
        Collected = 0; Failed = 0; Skipped = 0; TimestampUtc = $timestamp; OutputPath = $resolvedOutputPath
    }
}

$sourceLabel = if ($null -ne $Identity -and $Identity.Count -gt 0) { "-Identity parameter" } else { $resolvedCsvPath }
Write-Detail "Source: $sourceLabel ($($identities.Count) mailboxes)"
Write-Detail "Target: $resolvedOutputPath"

# A slice writes only what it collects; a full run merges into the existing history.
$records = [System.Collections.Generic.List[psobject]]::new()
$recordIndex = @{}

if (-not $isSliceOutput) {
    $existing = $null
    try {
        $existing = Read-MailboxJson -Path $resolvedHistoryPath
    }
    catch {
        Write-Notice "Existing history could not be read; starting a new file."
    }

    if ($null -ne $existing -and $existing.PSObject.Properties.Name -contains 'MailboxHistory') {
        foreach ($entry in @($existing.MailboxHistory)) {
            if ($null -eq $entry) { continue }
            $records.Add($entry)

            $guid = [string](Get-PropertyValueOrNull -Object $entry -Name 'ExchangeGuid')
            if (-not [string]::IsNullOrWhiteSpace($guid)) {
                $recordIndex[$guid.ToLowerInvariant()] = $entry
            }
        }
        Write-Detail "Loaded $($records.Count) existing mailbox record(s)."
    }
}

$maxSamples = [int]$config.Collection.MaxHistorySamples
$collected = 0
$failed = 0
$skipped = 0
$counter = 0

foreach ($identityValue in $identities) {
    $counter++

    if ([string]::IsNullOrWhiteSpace($identityValue)) {
        $skipped++
        Write-Item -Name "<blank row>" -Index $counter -Total $identities.Count -Status "SKIPPED"
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($identityValue, "Collect mailbox metrics")) {
        continue
    }

    try {
        $result = Get-MailboxSample -MailboxIdentity $identityValue -Timestamp $timestamp

        if ([string]::IsNullOrWhiteSpace($result.ExchangeGuid)) {
            throw "Exchange Online returned no ExchangeGuid for '$identityValue'."
        }

        $key = $result.ExchangeGuid.ToLowerInvariant()

        if ($recordIndex.ContainsKey($key)) {
            $entry = $recordIndex[$key]

            $samples = [System.Collections.Generic.List[psobject]]::new()
            if ($entry.PSObject.Properties.Name -contains 'Samples' -and $null -ne $entry.Samples) {
                foreach ($existingSample in @($entry.Samples)) { $samples.Add($existingSample) }
            }
            $samples.Add($result.Sample)

            if ($samples.Count -gt $maxSamples) {
                $samples = [System.Collections.Generic.List[psobject]](@($samples | Select-Object -Last $maxSamples))
            }

            $entry.PrimarySmtpAddress = $result.PrimarySmtpAddress
            $entry.DisplayName = $result.DisplayName
            $entry.Permissions = $result.Permissions
            $entry.Samples = @($samples)
        }
        else {
            $entry = [pscustomobject]@{
                ExchangeGuid       = $result.ExchangeGuid
                PrimarySmtpAddress = $result.PrimarySmtpAddress
                DisplayName        = $result.DisplayName
                Permissions        = $result.Permissions
                Samples            = @($result.Sample)
            }

            $records.Add($entry)
            $recordIndex[$key] = $entry
        }

        $collected++

        $quotaText = if ($null -eq $result.Sample.QuotaGB) { "unlimited" } else { "$($result.Sample.QuotaGB)GB" }
        Write-Item -Name "$identityValue  $($result.Sample.SizeGB)GB / $quotaText" -Index $counter -Total $identities.Count
    }
    catch {
        $failed++
        Write-Item -Name $identityValue -Index $counter -Total $identities.Count -Status "FAILED - $($_.Exception.Message)"
        Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0) -Context "Collecting $identityValue"
    }

    $isBatchBoundary = ($counter % $effectiveBatchSize) -eq 0
    if ($isBatchBoundary -and $counter -lt $identities.Count) {
        Write-Detail "Batch commit at $counter/$($identities.Count)"
        Save-CollectionProgress `
            -Records $records `
            -Path $resolvedOutputPath `
            -Timestamp $timestamp `
            -Source "Exchange Online (batch commit $counter/$($identities.Count))" `
            -Detail "$collected collected so far"
    }
}

Save-CollectionProgress `
    -Records $records `
    -Path $resolvedOutputPath `
    -Timestamp $timestamp `
    -Source "Exchange Online (Get-EXOMailbox / Get-EXOMailboxStatistics / Get-EXOMailboxPermission)" `
    -Detail "$collected collected, $failed failed"

Write-Detail "Collected $collected of $($identities.Count); $failed failed, $skipped skipped."

if ($failed -gt 0) {
    Write-Notice "$failed mailbox(es) failed - see the failure log for details."
}
else {
    Write-Success "Collection completed cleanly."
}

[pscustomobject]@{
    Collected    = $collected
    Failed       = $failed
    Skipped      = $skipped
    Requested    = $identities.Count
    TimestampUtc = $timestamp
    OutputPath   = $resolvedOutputPath
    IsSlice      = $isSliceOutput
}
