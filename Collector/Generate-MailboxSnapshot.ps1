<#
.SYNOPSIS
    Rebuilds data.json, the latest-snapshot file the dashboard reads.
.DESCRIPTION
    Takes the newest sample for every mailbox in history.json and writes it to data.json
    in the shape the web UI expects. Records are keyed on ExchangeGuid throughout.
.PARAMETER StaleAfterDays
    Report mailboxes whose newest sample is older than this. They are still written, but
    a stale snapshot usually means the collector stopped covering those mailboxes.
.PARAMETER AllowEmptySnapshot
    Permit writing an empty data.json when history explicitly contains no mailbox records.
    Without this switch, empty or unusable history leaves the existing snapshot untouched.
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
    [ValidateRange(0, 36500)]
    [int]$StaleAfterDays = 0,

    [Parameter()]
    [switch]$AllowEmptySnapshot
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

    if ($Samples -isnot [array] -or $Samples.Count -eq 0) {
        throw "Samples must be a non-empty JSON array."
    }

    $newest = $null
    $newestTime = [datetime]::MinValue

    foreach ($sample in $Samples) {
        if ($null -eq $sample -or $sample -isnot [pscustomobject]) {
            throw "Samples must contain JSON objects only."
        }

        $parsed = ConvertTo-DateTimeOrNull -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')
        if ($null -eq $parsed) {
            throw "A sample has a missing or invalid TimestampUtc."
        }

        if ($null -eq $newest -or $parsed -ge $newestTime) {
            $newestTime = $parsed
            $newest = $sample
        }
    }

    return [pscustomobject]@{ Sample = $newest; Timestamp = $newestTime }
}

function ConvertTo-SnapshotNumber {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [AllowNull()] $Value,
        [Parameter()] [double]$Minimum = 0,
        [Parameter()] [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) { return $null }
        throw "'$Name' is missing."
    }

    if ($Value -is [bool]) {
        throw "'$Name' must be numeric."
    }

    $parsed = 0.0
    if ($Value -is [string]) {
        $style = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        if (-not [double]::TryParse($Value.Trim(), $style, $culture, [ref]$parsed)) {
            throw "'$Name' is not a valid number."
        }
    }
    elseif ($Value -is [ValueType]) {
        $parsed = [double]$Value
    }
    else {
        throw "'$Name' is not a valid number."
    }

    if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or $parsed -lt $Minimum) {
        throw "'$Name' must be a finite number greater than or equal to $Minimum."
    }

    return $parsed
}

function ConvertTo-SnapshotCount {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [AllowNull()] $Value,
        [Parameter()] [switch]$AllowNull
    )

    if ($null -eq $Value -and $AllowNull) { return [int64]0 }
    if ($null -eq $Value) { throw "'$Name' is missing." }
    if ($Value -is [bool]) { throw "'$Name' must be a whole number." }

    $parsed = [decimal]0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [string]) {
        if (-not [decimal]::TryParse($Value.Trim(), $style, $culture, [ref]$parsed)) {
            throw "'$Name' is not a valid whole number."
        }
    }
    elseif ($Value -is [ValueType]) {
        try {
            $parsed = [decimal]$Value
        }
        catch {
            throw "'$Name' is outside the supported integer range."
        }
    }
    else {
        throw "'$Name' is not a valid whole number."
    }

    if ($parsed -lt 0 -or $parsed -ne [decimal]::Truncate($parsed) -or $parsed -gt [decimal][int64]::MaxValue) {
        throw "'$Name' must be a whole number within the supported range."
    }

    return [int64]$parsed
}

function ConvertTo-SnapshotBoolean {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [AllowNull()] $Value,
        [Parameter()] [switch]$DefaultFalse
    )

    if ($null -eq $Value -and $DefaultFalse) { return $false }
    if ($Value -is [bool]) { return $Value }

    $text = ([string]$Value).Trim()
    switch -Regex ($text) {
        '^(true|1|yes)$'  { return $true }
        '^(false|0|no)$'  { return $false }
        default { throw "'$Name' must be a boolean." }
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

    if ($Permissions -isnot [array]) {
        throw "'Permissions' must be an array or null."
    }

    return @(
        foreach ($permission in @($Permissions)) {
            if ($null -eq $permission -or $permission -isnot [pscustomobject]) {
                throw "Permissions must contain JSON objects only."
            }

            $rightsProperty = $permission.PSObject.Properties['AccessRights']
            if ($null -eq $rightsProperty) { $rightsProperty = $permission.PSObject.Properties['accessRights'] }
            $rights = $null
            if ($null -ne $rightsProperty) { $rights = $rightsProperty.Value }
            if ($null -eq $rights) { $rights = @() }
            if ($rights -isnot [array]) { throw "Permission AccessRights must be an array." }

            [pscustomobject]@{
                User         = [string](Get-PropertyValueOrNull -Object $permission -Name 'User')
                AccessRights = @($rights | ForEach-Object { [string]$_ })
                Deny         = ConvertTo-SnapshotBoolean -Name 'Permission.Deny' -Value (Get-PropertyValueOrNull -Object $permission -Name 'Deny') -DefaultFalse
                IsInherited  = ConvertTo-SnapshotBoolean -Name 'Permission.IsInherited' -Value (Get-PropertyValueOrNull -Object $permission -Name 'IsInherited') -DefaultFalse
            }
        }
    )
}

function ConvertTo-SnapshotRecord {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Sample,
        [Parameter(Mandatory)] [string]$ExchangeGuid
    )

    $availability = Get-PropertyValueOrNull -Object $Sample -Name 'DataAvailability'
    $isGraph = $null -ne $availability -and (Get-PropertyValueOrNull -Object $availability -Name 'Source') -eq 'MicrosoftGraph'
    $unavailable = @(Get-PropertyValueOrNull -Object $availability -Name 'UnavailableFields')
    $sizeGb = ConvertTo-SnapshotNumber -Name 'SizeGB' -Value (Get-PropertyValueOrNull -Object $Sample -Name 'SizeGB')
    $itemCount = ConvertTo-SnapshotCount -Name 'ItemCount' -Value (Get-PropertyValueOrNull -Object $Sample -Name 'ItemCount')
    $quotaRaw = Get-PropertyValueOrNull -Object $Sample -Name 'QuotaGB'
    $quotaGb = if ($null -eq $quotaRaw -or [string]$quotaRaw -eq 'Unlimited') {
        $null
    }
    else {
        ConvertTo-SnapshotNumber -Name 'QuotaGB' -Value $quotaRaw -Minimum ([double]::Epsilon)
    }

    $usagePercent = $null
    if ($null -ne $quotaGb) {
        $usagePercent = [math]::Round((($sizeGb / $quotaGb) * 100), 2)
        if ([double]::IsNaN($usagePercent) -or [double]::IsInfinity($usagePercent)) {
            throw "The calculated UsagePercent is outside the supported numeric range."
        }
    }

    $archiveEnabled = ConvertTo-SnapshotBoolean -Name 'ArchiveEnabled' `
        -Value (Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveEnabled') -DefaultFalse
    $archiveSize = ConvertTo-SnapshotNumber -Name 'ArchiveSizeGB' `
        -Value (Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveSizeGB') -AllowNull
    $archiveItems = ConvertTo-SnapshotCount -Name 'ArchiveItemCount' `
        -Value (Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveItemCount') -AllowNull
    if ($null -eq $archiveSize) { $archiveSize = 0.0 }
    if ($isGraph) {
        if ($null -eq (Get-PropertyValueOrNull -Object $Sample -Name 'ArchiveEnabled')) { $archiveEnabled = $null }
        if ($unavailable -contains 'ArchiveSizeGB') { $archiveSize = $null }
        if ($unavailable -contains 'ArchiveItemCount') { $archiveItems = $null }
    }

    $smtpAddress = [string](Get-PropertyValueOrNull -Object $Entry -Name 'PrimarySmtpAddress')
    $displayName = [string](Get-PropertyValueOrNull -Object $Entry -Name 'DisplayName')
    $permissionsProperty = $Entry.PSObject.Properties['Permissions']
    $permissionsValue = $null
    if ($null -ne $permissionsProperty) { $permissionsValue = $permissionsProperty.Value }
    $retentionChangesProperty = $Entry.PSObject.Properties['RetentionPolicyChangeHistory']
    $licenseChangesProperty = $Entry.PSObject.Properties['LicenseAssignmentHistory']
    $retentionChanges = @()
    $licenseChanges = @()
    if ($null -ne $retentionChangesProperty) { $retentionChanges = $retentionChangesProperty.Value }
    if ($null -ne $licenseChangesProperty) { $licenseChanges = $licenseChangesProperty.Value }
    if ([string]::IsNullOrWhiteSpace($smtpAddress)) {
        throw "'PrimarySmtpAddress' is missing."
    }
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $smtpAddress }

    $result = [pscustomobject]@{
        ExchangeGuid       = $ExchangeGuid
        PrimarySmtpAddress = $smtpAddress
        DisplayName        = $displayName
        Licensing          = Get-PropertyValueOrNull -Object $Entry -Name 'Licensing'
        Retention          = Get-PropertyValueOrNull -Object $Entry -Name 'Retention'
        RetentionPolicyChangeHistory = @($retentionChanges)
        LicenseAssignmentHistory = @($licenseChanges)
        current            = [pscustomobject]@{
            totalGB          = $sizeGb
            itemCount        = $itemCount
            quotaGB          = $quotaGb
            usagePercent     = $usagePercent
            lastLogonTime    = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $Sample -Name 'LastLogonTime')
            archiveEnabled   = $archiveEnabled
            archiveSizeGB    = $archiveSize
            archiveItemCount = $archiveItems
            sampleTimestamp  = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $Sample -Name 'TimestampUtc')
        }
        permissions        = @(Convert-PermissionSet -Permissions $permissionsValue)
    }
    if ($isGraph) {
        $sampleLicensing = Get-PropertyValueOrNull -Object $Sample -Name 'Licensing'
        if ($null -ne $sampleLicensing) { $result.Licensing = $sampleLicensing }
        $result | Add-Member -NotePropertyName DataAvailability -NotePropertyValue $availability
        $result.current | Add-Member -NotePropertyName lastActivityDate -NotePropertyValue (Get-PropertyValueOrNull -Object $Sample -Name 'LastActivityDate')
        $result.current | Add-Member -NotePropertyName permissionCount -NotePropertyValue $null
        if ($unavailable -contains 'Permissions') { $result.permissions = $null }
        if ($unavailable -contains 'Retention') { $result.Retention = $null }
        if ($null -ne $result.Licensing) {
            if ($unavailable -contains 'RecipientTypeDetails') {
                $result.Licensing | Add-Member -NotePropertyName RecipientTypeDetails -NotePropertyValue $null -Force
            }
            if ($unavailable -contains 'LicenseRequired') {
                $result.Licensing | Add-Member -NotePropertyName LicenseRequired -NotePropertyValue $null -Force
                $result.Licensing | Add-Member -NotePropertyName IsLicenseCompliant -NotePropertyValue $null -Force
            }
        }
    }
    return $result
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

$fullHistoryPath = [System.IO.Path]::GetFullPath($resolvedHistoryPath)
$fullDataPath = [System.IO.Path]::GetFullPath($resolvedDataPath)
if ([string]::Equals($fullHistoryPath, $fullDataPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "History and snapshot paths resolve to the same file ('$fullHistoryPath'); refusing to overwrite the source history."
}

Write-Stage "Generating snapshot"

if (-not (Test-Path -LiteralPath $resolvedHistoryPath)) {
    throw "History file not found at '$resolvedHistoryPath'. Run the collector first."
}

$history = Read-MailboxJson -Path $resolvedHistoryPath
if ($null -eq $history) {
    throw "History file '$resolvedHistoryPath' is empty."
}

$historyProperty = $history.PSObject.Properties['MailboxHistory']
if ($history -isnot [pscustomobject] -or $null -eq $historyProperty) {
    throw "History file '$resolvedHistoryPath' must be an object with a 'MailboxHistory' array."
}

$entriesValue = $historyProperty.Value
if ($entriesValue -isnot [array]) {
    throw "History file '$resolvedHistoryPath' has a missing or invalid 'MailboxHistory' array."
}

$entries = @($entriesValue)
if ($entries.Count -eq 0 -and -not $AllowEmptySnapshot) {
    throw "History contains no mailboxes. No snapshot was written. Pass -AllowEmptySnapshot only when an empty dashboard is intentional."
}

Write-Detail "Source: $resolvedHistoryPath ($($entries.Count) mailboxes)"
Write-Detail "Target: $resolvedDataPath"

$snapshots = [System.Collections.Generic.List[object]]::new()
$validationErrors = [System.Collections.Generic.List[string]]::new()
$seenGuids = @{}
$skipped = 0
$stale = 0
$staleCutoff = if ($StaleAfterDays -gt 0) { (Get-Date).ToUniversalTime().AddDays(-$StaleAfterDays) } else { $null }
$newestOverall = [datetime]::MinValue
$counter = 0

foreach ($entry in $entries) {
    $counter++
    $label = "history[$counter]"

    try {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
            throw "Mailbox records must be JSON objects."
        }

        $guidRaw = [string](Get-PropertyValueOrNull -Object $entry -Name 'ExchangeGuid')
        $label = [string](Get-PropertyValueOrNull -Object $entry -Name 'PrimarySmtpAddress')
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $guidRaw }
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($guidRaw, [ref]$parsedGuid)) {
            throw "'ExchangeGuid' is missing or is not a valid GUID."
        }

        $guid = $parsedGuid.ToString('D')
        $guidKey = $parsedGuid.ToString('N')
        if ($seenGuids.ContainsKey($guidKey)) {
            throw "Duplicate ExchangeGuid '$guid'."
        }
        $seenGuids[$guidKey] = $counter

        $samplesProperty = $entry.PSObject.Properties['Samples']
        if ($null -eq $samplesProperty) {
            throw "'Samples' is missing."
        }
        $latest = Get-LatestSample -Samples $samplesProperty.Value
        $sample = $latest.Sample

        $snapshot = ConvertTo-SnapshotRecord -Entry $entry -Sample $sample -ExchangeGuid $guid
        $snapshots.Add($snapshot)
    }
    catch {
        $skipped++
        $message = $_.Exception.Message
        $validationErrors.Add("$label - $message")
        Write-Item -Name $label -Index $counter -Total $entries.Count -Status "FAILED - $message"
        continue
    }

    $timestampParsed = $latest.Timestamp
    if ($timestampParsed -gt $newestOverall) { $newestOverall = $timestampParsed }
    if ($null -ne $staleCutoff -and $timestampParsed -lt $staleCutoff) {
        $stale++
        Write-Item -Name $label -Index $counter -Total $entries.Count -Status "STALE - newest sample $($timestampParsed.ToString('yyyy-MM-dd'))"
        continue
    }

    Write-Item -Name $label -Index $counter -Total $entries.Count
}

if ($validationErrors.Count -gt 0) {
    $examples = @($validationErrors | Select-Object -First 5) -join '; '
    throw "Snapshot aborted: $($validationErrors.Count) invalid mailbox record(s) were found. No changes were written to '$resolvedDataPath'. $examples"
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
        -RecordDetail $(if ($stale -gt 0) { "$stale stale" } else { $null }) `
        -Depth 20
}

Write-Detail "Snapshot covers $($snapshots.Count) of $($entries.Count) mailboxes."

if ($stale -gt 0) {
    Write-Notice "$stale mailbox(es) have not been collected in the last $StaleAfterDays day(s)."
}

if ($stale -eq 0) {
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
