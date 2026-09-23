<#
.SYNOPSIS
    Merges collector output files into history.json.
.DESCRIPTION
    Combines the JSON files produced by threaded collection into the history file,
    keyed on ExchangeGuid. Two input shapes are accepted:

      - a slice document written by Collect-ExchangeOnlineMailboxes.ps1 -OutputPath,
        containing a MailboxHistory array
      - a single flat mailbox record, as produced by the legacy threaded collector

    Samples carrying a timestamp that a mailbox already has are treated as a re-run of
    that collection and replace the existing sample rather than duplicating it.
.PARAMETER RemoveProcessed
    Deletes the input files, but only after history.json has been written successfully.
.EXAMPLE
    .\Merge-CollectionResults.ps1
    Merges everything in the configured thread-jobs directory into history.json.
.EXAMPLE
    .\Merge-CollectionResults.ps1 -InputPath .\Temp\Batch3 -RemoveProcessed
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$InputPath,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$Filter = "*.json",

    [Parameter()]
    [int]$MaxHistorySamples,

    [Parameter()]
    [switch]$RemoveProcessed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

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
            }
        }
    )
}

function ConvertTo-HistoryRecord {
<#
.SYNOPSIS
    Normalises a flat single-mailbox record into a history record with one sample.
#>
    param(
        [Parameter(Mandatory)]
        $Raw
    )

    $exchangeGuid = [string](Get-PropertyValueOrNull -Object $Raw -Name 'ExchangeGuid')
    if ([string]::IsNullOrWhiteSpace($exchangeGuid)) {
        return $null
    }

    $sizeGb = [double](Get-NumericOrDefault -Value (Get-PropertyValueOrNull -Object $Raw -Name 'SizeGB') -Default 0.0)
    $quotaRaw = Get-PropertyValueOrNull -Object $Raw -Name 'QuotaGB'
    $quotaGb = if ($null -eq $quotaRaw -or [string]$quotaRaw -eq 'Unlimited') { $null } else { [double]$quotaRaw }

    $usagePercent = Get-PropertyValueOrNull -Object $Raw -Name 'UsagePercent'
    if ($null -eq $usagePercent -and $null -ne $quotaGb -and $quotaGb -gt 0) {
        $usagePercent = [math]::Round((($sizeGb / $quotaGb) * 100), 2)
    }

    $permissions = Convert-PermissionSet -Permissions (Get-PropertyValueOrNull -Object $Raw -Name 'Permissions')

    $sample = [pscustomobject]@{
        TimestampUtc     = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $Raw -Name 'TimestampUtc')
        SizeGB           = $sizeGb
        ItemCount        = [int64](Get-NumericOrDefault -Value (Get-PropertyValueOrNull -Object $Raw -Name 'ItemCount') -Default 0)
        PermissionCount  = $permissions.Count
        QuotaGB          = $quotaGb
        UsagePercent     = $usagePercent
        LastLogonTime    = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $Raw -Name 'LastLogonTime')
        ArchiveEnabled   = [bool](Get-PropertyValueOrNull -Object $Raw -Name 'ArchiveEnabled')
        ArchiveSizeGB    = [double](Get-NumericOrDefault -Value (Get-PropertyValueOrNull -Object $Raw -Name 'ArchiveSizeGB') -Default 0.0)
        ArchiveItemCount = [int64](Get-NumericOrDefault -Value (Get-PropertyValueOrNull -Object $Raw -Name 'ArchiveItemCount') -Default 0)
    }

    return [pscustomobject]@{
        ExchangeGuid       = $exchangeGuid
        PrimarySmtpAddress = [string](Get-PropertyValueOrNull -Object $Raw -Name 'PrimarySmtpAddress')
        DisplayName        = [string](Get-PropertyValueOrNull -Object $Raw -Name 'DisplayName')
        Licensing          = Get-PropertyValueOrNull -Object $Raw -Name 'Licensing'
        Permissions        = $permissions
        Samples            = @($sample)
    }
}

function Get-NumericOrDefault {
    param(
        [Parameter()] $Value,
        [Parameter(Mandatory)] $Default
    )

    if ($null -eq $Value) { return $Default }

    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }

    return $Default
}

function Get-RecordsFromFile {
<#
.SYNOPSIS
    Returns the history records contained in one collector output file.
#>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $raw = Read-MailboxJson -Path $Path

    if ($null -eq $raw) {
        return @()
    }

    $mailboxHistory = Get-PropertyValueOrNull -Object $raw -Name 'MailboxHistory'
    if ($null -ne $mailboxHistory) {
        return @($mailboxHistory | Where-Object { $null -ne $_ })
    }

    $single = ConvertTo-HistoryRecord -Raw $raw
    if ($null -eq $single) {
        return @()
    }

    return @($single)
}

function Merge-RecordIntoIndex {
<#
.SYNOPSIS
    Adds or updates one mailbox record in the merge index, de-duplicating samples.
.OUTPUTS
    The number of samples actually added.
#>
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)] [hashtable]$Index,
        [Parameter(Mandatory)] $Records,
        [Parameter(Mandatory)] [int]$MaxSamples,
        [Parameter(Mandatory)] [ref]$ReplacedCount
    )

    $exchangeGuid = [string](Get-PropertyValueOrNull -Object $Record -Name 'ExchangeGuid')
    if ([string]::IsNullOrWhiteSpace($exchangeGuid)) {
        return 0
    }

    $key = $exchangeGuid.ToLowerInvariant()
    $incoming = @(Get-PropertyValueOrNull -Object $Record -Name 'Samples')

    if (-not $Index.ContainsKey($key)) {
        foreach ($sample in $incoming) {
            if ($null -eq $sample) { continue }
            $timestamp = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')
            if ($null -ne $timestamp) { $sample.TimestampUtc = $timestamp }
        }

        $Records.Add($Record)
        $Index[$key] = $Record
        return $incoming.Count
    }

    $existing = $Index[$key]

    $samples = [System.Collections.Generic.List[object]]::new()
    $byTimestamp = @{}

    foreach ($sample in @(Get-PropertyValueOrNull -Object $existing -Name 'Samples')) {
        if ($null -eq $sample) { continue }

        # Normalising in place keeps the stored history in one timestamp format.
        $timestamp = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')
        if ($null -ne $timestamp) {
            $sample.TimestampUtc = $timestamp
        }

        $samples.Add($sample)
        if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
            $byTimestamp[$timestamp] = $samples.Count - 1
        }
    }

    $added = 0
    foreach ($sample in $incoming) {
        if ($null -eq $sample) { continue }

        $timestamp = ConvertTo-IsoUtcString -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')
        if ($null -ne $timestamp) {
            $sample.TimestampUtc = $timestamp
        }

        # Same mailbox, same timestamp means the batch was re-run; keep the newer figures.
        if (-not [string]::IsNullOrWhiteSpace($timestamp) -and $byTimestamp.ContainsKey($timestamp)) {
            $samples[$byTimestamp[$timestamp]] = $sample
            $ReplacedCount.Value++
            continue
        }

        $samples.Add($sample)
        if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
            $byTimestamp[$timestamp] = $samples.Count - 1
        }
        $added++
    }

    $ordered = @($samples | Sort-Object -Property @{ Expression = {
        $parsed = ConvertTo-DateTimeOrNull -Value (Get-PropertyValueOrNull -Object $_ -Name 'TimestampUtc')
        if ($null -ne $parsed) { $parsed } else { [datetime]::MinValue }
    } })

    if ($ordered.Count -gt $MaxSamples) {
        $ordered = @($ordered | Select-Object -Last $MaxSamples)
    }

    $newSmtp = [string](Get-PropertyValueOrNull -Object $Record -Name 'PrimarySmtpAddress')
    $newDisplayName = [string](Get-PropertyValueOrNull -Object $Record -Name 'DisplayName')
    $newLicensing = Get-PropertyValueOrNull -Object $Record -Name 'Licensing'
    $newPermissions = Get-PropertyValueOrNull -Object $Record -Name 'Permissions'

    if (-not [string]::IsNullOrWhiteSpace($newSmtp)) { $existing.PrimarySmtpAddress = $newSmtp }
    if (-not [string]::IsNullOrWhiteSpace($newDisplayName)) { $existing.DisplayName = $newDisplayName }
    if ($null -ne $newLicensing) { $existing.Licensing = $newLicensing }
    if ($null -ne $newPermissions) { $existing.Permissions = @($newPermissions) }

    $existing.Samples = $ordered

    return $added
}

# --- Entry point -------------------------------------------------------------

$configParams = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
$config = Import-MailboxDashboardConfig @configParams -SkipValidation

$resolvedInputPath = if ($PSBoundParameters.ContainsKey('InputPath')) {
    Resolve-MailboxPath -Path $InputPath -BaseDirectory $PWD.Path
}
else {
    $config.ResolvedPaths.ThreadJobsDirectory
}

$resolvedHistoryPath = if ($PSBoundParameters.ContainsKey('HistoryJsonPath')) {
    Resolve-MailboxPath -Path $HistoryJsonPath -BaseDirectory $PWD.Path
}
else {
    $config.ResolvedPaths.HistoryJson
}

$maxSamples = if ($PSBoundParameters.ContainsKey('MaxHistorySamples')) { $MaxHistorySamples } else { [int]$config.Collection.MaxHistorySamples }

Write-Stage "Merging collection results"

if (-not (Test-Path -LiteralPath $resolvedInputPath)) {
    throw "Input path not found at '$resolvedInputPath'."
}

$inputFiles = @(Get-ChildItem -LiteralPath $resolvedInputPath -Filter $Filter -File -ErrorAction Stop)

if ($inputFiles.Count -eq 0) {
    Write-Notice "No files matching '$Filter' in '$resolvedInputPath' - nothing to merge."
    return [pscustomobject]@{
        FilesRead = 0; FilesFailed = 0; RecordsAdded = 0; RecordsUpdated = 0
        SamplesAdded = 0; SamplesReplaced = 0; TotalRecords = 0; HistoryPath = $resolvedHistoryPath
    }
}

Write-Detail "Source: $resolvedInputPath ($($inputFiles.Count) files)"
Write-Detail "Target: $resolvedHistoryPath"

$records = [System.Collections.Generic.List[object]]::new()
$index = @{}

$existingHistory = $null
try {
    $existingHistory = Read-MailboxJson -Path $resolvedHistoryPath
}
catch {
    Write-Notice "Existing history could not be read; rebuilding from the merged files."
}

if ($null -ne $existingHistory) {
    foreach ($entry in @(Get-PropertyValueOrNull -Object $existingHistory -Name 'MailboxHistory')) {
        if ($null -eq $entry) { continue }
        $records.Add($entry)

        $guid = [string](Get-PropertyValueOrNull -Object $entry -Name 'ExchangeGuid')
        if (-not [string]::IsNullOrWhiteSpace($guid)) {
            $index[$guid.ToLowerInvariant()] = $entry
        }
    }
    Write-Detail "Loaded $($records.Count) existing mailbox record(s)."
}

$recordsBefore = $records.Count
$filesRead = 0
$filesFailed = 0
$samplesAdded = 0
$replaced = 0
$processedFiles = [System.Collections.Generic.List[string]]::new()
$newestSample = ConvertTo-DateTimeOrNull -Value (Get-PropertyValueOrNull -Object $existingHistory -Name 'GeneratedUtc')
$counter = 0

foreach ($file in $inputFiles) {
    $counter++

    if (-not $PSCmdlet.ShouldProcess($file.Name, "Merge collector output")) {
        continue
    }

    try {
        $fileRecords = @(Get-RecordsFromFile -Path $file.FullName)

        if ($fileRecords.Count -eq 0) {
            $filesFailed++
            Write-Item -Name $file.Name -Index $counter -Total $inputFiles.Count -Status "SKIPPED - no usable records"
            continue
        }

        $replacedRef = [ref]$replaced
        foreach ($record in $fileRecords) {
            $samplesAdded += Merge-RecordIntoIndex -Record $record -Index $index -Records $records -MaxSamples $maxSamples -ReplacedCount $replacedRef

            foreach ($sample in @(Get-PropertyValueOrNull -Object $record -Name 'Samples')) {
                $sampleTime = ConvertTo-DateTimeOrNull -Value (Get-PropertyValueOrNull -Object $sample -Name 'TimestampUtc')
                if ($null -ne $sampleTime -and ($null -eq $newestSample -or $sampleTime -gt $newestSample)) {
                    $newestSample = $sampleTime
                }
            }
        }

        $filesRead++
        $processedFiles.Add($file.FullName)
        Write-Item -Name "$($file.Name)  ($($fileRecords.Count) record(s))" -Index $counter -Total $inputFiles.Count
    }
    catch {
        $filesFailed++
        Write-Item -Name $file.Name -Index $counter -Total $inputFiles.Count -Status "FAILED - $($_.Exception.Message)"
        Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0) -Context "Merging $($file.Name)"
    }
}

if ($filesRead -eq 0) {
    Write-Notice "No files merged successfully; history.json was left unchanged."
    return [pscustomobject]@{
        FilesRead = 0; FilesFailed = $filesFailed; RecordsAdded = 0; RecordsUpdated = 0
        SamplesAdded = 0; SamplesReplaced = 0; TotalRecords = $records.Count; HistoryPath = $resolvedHistoryPath
    }
}

if ($null -ne $newestSample) {
    $latestTimestamp = $newestSample.ToUniversalTime().ToString("o")
}
else {
    $latestTimestamp = (Get-Date).ToUniversalTime().ToString("o")
}

$recordsAdded = $records.Count - $recordsBefore
$recordsUpdated = $index.Count - $recordsAdded

$document = [pscustomobject]@{
    GeneratedUtc   = $latestTimestamp
    MailboxHistory = @($records)
}

Write-MailboxJson `
    -InputObject $document `
    -Path $resolvedHistoryPath `
    -Source "$resolvedInputPath ($filesRead thread-job file(s))" `
    -RecordCount $records.Count `
    -RecordDetail "$recordsAdded added, $samplesAdded sample(s) appended, $replaced replaced" `
    -Depth 100

if ($RemoveProcessed -and $processedFiles.Count -gt 0) {
    foreach ($path in $processedFiles) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    Write-Detail "Removed $($processedFiles.Count) processed file(s)."
}

Write-Detail "Merged $filesRead of $($inputFiles.Count) file(s); $filesFailed failed."

if ($filesFailed -gt 0) {
    Write-Notice "$filesFailed file(s) could not be merged - see the failure log."
}
else {
    Write-Success "Merge completed cleanly."
}

[pscustomobject]@{
    FilesRead       = $filesRead
    FilesFailed     = $filesFailed
    RecordsAdded    = $recordsAdded
    RecordsUpdated  = $recordsUpdated
    SamplesAdded    = $samplesAdded
    SamplesReplaced = $replaced
    TotalRecords    = $records.Count
    GeneratedUtc    = $latestTimestamp
    HistoryPath     = $resolvedHistoryPath
}
