<#
.SYNOPSIS
    Validates, repairs, and culls the MailboxDashboard JSON data files.
.DESCRIPTION
    Checks history.json and data.json against the schema the dashboard expects, reports
    every problem found, and optionally repairs recoverable records or removes
    unrecoverable ones.

    Three modes, in increasing order of intervention:
      (default)  report only - nothing is written
      -Repair    fix recoverable problems and write the file back
      -Cull      additionally remove records that cannot be repaired
      -Strict    report only, and fail the run if any problem is found
.PARAMETER Target
    Which files to check: History, Data, or Both (default).
.PARAMETER Path
    Validate a specific file instead of the configured ones. Requires -Target.
.EXAMPLE
    .\Test-MailboxDashboardJSON.ps1
    Reports problems in history.json and data.json without changing anything.
.EXAMPLE
    .\Test-MailboxDashboardJSON.ps1 -Repair -Cull
    Fixes what it can and drops records it cannot fix, backing up each file first.
.EXAMPLE
    .\Test-MailboxDashboardJSON.ps1 -Strict
    Exits with code 1 if the data is not clean - suitable for a scheduled task gate.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('History', 'Data', 'Both')]
    [string]$Target = 'Both',

    [Parameter()]
    [string]$Path,

    [Parameter()]
    [switch]$Repair,

    [Parameter()]
    [switch]$Cull,

    [Parameter()]
    [switch]$Strict,

    [Parameter()]
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

#region Report helpers

function New-ValidationReport {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$Kind
    )

    return [pscustomobject]@{
        File            = $FilePath
        Kind            = $Kind
        RecordsRead     = 0
        RecordsKept     = 0
        RecordsRepaired = 0
        RecordsCulled   = 0
        SamplesRead     = 0
        SamplesRepaired = 0
        SamplesCulled   = 0
        Problems        = [System.Collections.Generic.List[string]]::new()
        Warnings        = [System.Collections.Generic.List[string]]::new()
        Repairs         = [System.Collections.Generic.List[string]]::new()
        Culls           = [System.Collections.Generic.List[string]]::new()
        Changed         = $false
        IsValid         = $true
    }
}

function Add-Problem {
    param($Report, [string]$Message)
    $Report.Problems.Add($Message)
    $Report.IsValid = $false
}

# A warning is a true fact about the tenant, not a schema fault - it never fails the file.
function Add-Warning {
    param($Report, [string]$Message)
    $Report.Warnings.Add($Message)
}

function Add-RepairNote {
    param($Report, [string]$Message)
    $Report.Repairs.Add($Message)
    $Report.Changed = $true
}

function Add-CullNote {
    param($Report, [string]$Message)
    $Report.Culls.Add($Message)
    $Report.Changed = $true
}

#endregion

#region Value coercion

function Get-PropertyOrNull {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Object.$Name
}

function ConvertTo-NumberOrNull {
<#
.SYNOPSIS
    Coerces a value to a double, accepting numeric strings. Returns $null if impossible.
#>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) {
        return [double]$Value
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = 0.0
    if ([double]::TryParse($text, [ref]$parsed)) { return $parsed }

    return $null
}

function ConvertTo-IsoTimestampOrNull {
    param($Value)

    if ($null -eq $Value) { return $null }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    # ISO first, then the local culture - on en-AU '11/08/2026' means 11 August, and
    # invariant parsing would silently turn it into 8 November.
    $isoFormats = @('o', "yyyy-MM-ddTHH:mm:ss.fffffffZ", "yyyy-MM-ddTHH:mm:ssZ", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-dd HH:mm:ss")
    if ([datetime]::TryParseExact($text, $isoFormats, $invariant, $styles, [ref]$parsed)) {
        return $parsed.ToString("o")
    }

    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$parsed)) {
        return $parsed.ToString("o")
    }

    if ([datetime]::TryParse($text, $invariant, $styles, [ref]$parsed)) {
        return $parsed.ToString("o")
    }

    return $null
}

function Test-GuidLike {
    param($Value)

    if ($null -eq $Value) { return $false }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    $guid = [guid]::Empty
    return [guid]::TryParse($text, [ref]$guid)
}

#endregion

#region Numeric field checks

function Test-NumericField {
<#
.SYNOPSIS
    Validates one numeric field, repairing a numeric string or negative value in place.
.OUTPUTS
    $true when the field is usable after any repair, $false when it is not.
#>
    param(
        [Parameter(Mandatory)] $Container,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] $Report,
        [Parameter()] [switch]$ApplyRepair,
        [Parameter()] [switch]$MustBePositive,
        [Parameter()] [double]$Maximum = [double]::MaxValue,
        [Parameter()] [double]$DefaultValue = 0.0
    )

    $raw = Get-PropertyOrNull -Object $Container -Name $Name
    $number = ConvertTo-NumberOrNull -Value $raw

    if ($null -eq $number) {
        Add-Problem $Report "$Label - '$Name' is missing or not numeric (value: '$raw')."
        if ($ApplyRepair -and -not $MustBePositive) {
            Set-FieldValue -Container $Container -Name $Name -Value $DefaultValue
            Add-RepairNote $Report "$Label - set '$Name' to $DefaultValue."
            return $true
        }
        return $false
    }

    if ($number -lt 0) {
        Add-Problem $Report "$Label - '$Name' is negative ($number)."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Container -Name $Name -Value 0.0
            Add-RepairNote $Report "$Label - clamped negative '$Name' to 0."
            $number = 0.0
        }
        else {
            return $false
        }
    }

    if ($MustBePositive -and $number -le 0) {
        Add-Problem $Report "$Label - '$Name' must be greater than zero (value: $number)."
        return $false
    }

    if ($number -gt $Maximum) {
        Add-Problem $Report "$Label - '$Name' exceeds the maximum of $Maximum (value: $number)."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Container -Name $Name -Value $Maximum
            Add-RepairNote $Report "$Label - clamped '$Name' to $Maximum."
        }
        else {
            return $false
        }
    }

    # Normalise numeric strings so the dashboard never does string arithmetic.
    if ($raw -isnot [double] -and $raw -isnot [int] -and $raw -isnot [long] -and $raw -isnot [decimal]) {
        if ($ApplyRepair) {
            Set-FieldValue -Container $Container -Name $Name -Value $number
            Add-RepairNote $Report "$Label - converted '$Name' from text to a number."
        }
    }

    return $true
}

function Set-FieldValue {
    param(
        [Parameter(Mandatory)] $Container,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value
    )

    if ($Container.PSObject.Properties.Name -contains $Name) {
        $Container.$Name = $Value
    }
    else {
        Add-Member -InputObject $Container -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

#endregion

#region history.json

function Test-HistorySample {
<#
.SYNOPSIS
    Validates one historical sample. Returns $true if the sample should be kept.
#>
    param(
        [Parameter(Mandatory)] $Sample,
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] $Report,
        [Parameter()] [switch]$ApplyRepair
    )

    $isUsable = $true

    $timestamp = ConvertTo-IsoTimestampOrNull -Value (Get-PropertyOrNull -Object $Sample -Name 'TimestampUtc')
    if ($null -eq $timestamp) {
        Add-Problem $Report "$Label - 'TimestampUtc' is missing or unparseable."
        $isUsable = $false
    }
    elseif ($ApplyRepair -and [string](Get-PropertyOrNull -Object $Sample -Name 'TimestampUtc') -ne $timestamp) {
        Set-FieldValue -Container $Sample -Name 'TimestampUtc' -Value $timestamp
        Add-RepairNote $Report "$Label - normalised 'TimestampUtc' to ISO 8601."
    }

    if (-not (Test-NumericField -Container $Sample -Name 'SizeGB' -Label $Label -Report $Report -ApplyRepair:$ApplyRepair)) {
        $isUsable = $false
    }

    # A null quota means the mailbox is unlimited - a real state, not a fault.
    $quotaRaw = Get-PropertyOrNull -Object $Sample -Name 'QuotaGB'
    $isUnlimited = ($null -eq $quotaRaw) -or ([string]$quotaRaw -eq 'Unlimited')

    if (-not $isUnlimited) {
        if (-not (Test-NumericField -Container $Sample -Name 'QuotaGB' -Label $Label -Report $Report -ApplyRepair:$ApplyRepair -MustBePositive)) {
            $isUsable = $false
        }
    }

    $null = Test-NumericField -Container $Sample -Name 'ItemCount' -Label $Label -Report $Report -ApplyRepair:$ApplyRepair
    $null = Test-NumericField -Container $Sample -Name 'PermissionCount' -Label $Label -Report $Report -ApplyRepair:$ApplyRepair
    $null = Test-NumericField -Container $Sample -Name 'ArchiveSizeGB' -Label $Label -Report $Report -ApplyRepair:$ApplyRepair
    $null = Test-NumericField -Container $Sample -Name 'ArchiveItemCount' -Label $Label -Report $Report -ApplyRepair:$ApplyRepair

    if (-not $isUsable) {
        return $false
    }

    # Usage cannot be derived without a quota, so an unlimited mailbox reports none.
    if ($isUnlimited) {
        $storedUsage = Get-PropertyOrNull -Object $Sample -Name 'UsagePercent'
        if ($null -ne $storedUsage -and $ApplyRepair) {
            Set-FieldValue -Container $Sample -Name 'UsagePercent' -Value $null
            Add-RepairNote $Report "$Label - cleared UsagePercent on an unlimited mailbox."
        }
        return $true
    }

    $sizeGb = [double](ConvertTo-NumberOrNull -Value (Get-PropertyOrNull -Object $Sample -Name 'SizeGB'))
    $quotaGb = [double](ConvertTo-NumberOrNull -Value (Get-PropertyOrNull -Object $Sample -Name 'QuotaGB'))

    # An over-quota mailbox is real and worth surfacing; never clamp it away.
    if ($sizeGb -gt $quotaGb) {
        Add-Warning $Report "$Label - over quota: SizeGB $sizeGb against QuotaGB $quotaGb."
    }

    $expectedUsage = [math]::Round((($sizeGb / $quotaGb) * 100), 2)
    $actualUsage = ConvertTo-NumberOrNull -Value (Get-PropertyOrNull -Object $Sample -Name 'UsagePercent')

    if ($null -eq $actualUsage -or [math]::Abs($actualUsage - $expectedUsage) -gt 0.5) {
        Add-Problem $Report "$Label - UsagePercent ($actualUsage) does not match SizeGB/QuotaGB (expected $expectedUsage)."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Sample -Name 'UsagePercent' -Value $expectedUsage
            Add-RepairNote $Report "$Label - recalculated UsagePercent as $expectedUsage."
        }
    }

    $archiveEnabled = Get-PropertyOrNull -Object $Sample -Name 'ArchiveEnabled'
    if ($null -ne $archiveEnabled -and $archiveEnabled -isnot [bool]) {
        if ($ApplyRepair) {
            $asBool = ([string]$archiveEnabled).Trim() -match '^(true|1|yes)$'
            Set-FieldValue -Container $Sample -Name 'ArchiveEnabled' -Value $asBool
            Add-RepairNote $Report "$Label - converted 'ArchiveEnabled' to a boolean."
        }
    }

    return $true
}

function Test-HistoryDocument {
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)] [int]$MaxSamples,
        [Parameter()] [switch]$ApplyRepair,
        [Parameter()] [switch]$ApplyCull
    )

    if ($null -eq (Get-PropertyOrNull -Object $Document -Name 'MailboxHistory')) {
        Add-Problem $Report "Top level 'MailboxHistory' array is missing."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Document -Name 'MailboxHistory' -Value @()
            Add-RepairNote $Report "Added an empty 'MailboxHistory' array."
        }
        return $Document
    }

    if ($null -eq (Get-PropertyOrNull -Object $Document -Name 'GeneratedUtc')) {
        Add-Problem $Report "Top level 'GeneratedUtc' is missing."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Document -Name 'GeneratedUtc' -Value ((Get-Date).ToUniversalTime().ToString("o"))
            Add-RepairNote $Report "Added 'GeneratedUtc'."
        }
    }

    $records = @($Document.MailboxHistory)
    $Report.RecordsRead = $records.Count

    $seenGuids = @{}
    $kept = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($record in $records) {
        $index++
        $smtp = [string](Get-PropertyOrNull -Object $record -Name 'PrimarySmtpAddress')
        $guid = Get-PropertyOrNull -Object $record -Name 'ExchangeGuid'
        $label = "history[$index] $(if ([string]::IsNullOrWhiteSpace($smtp)) { '<no address>' } else { $smtp })"

        Write-Item -Name $label -Index $index -Total $records.Count

        if (-not (Test-GuidLike -Value $guid)) {
            Add-Problem $Report "$label - 'ExchangeGuid' is missing or not a GUID."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (no usable ExchangeGuid)."
                $Report.RecordsCulled++
                continue
            }
        }

        $guidKey = ([string]$guid).Trim().ToLowerInvariant()
        if ($seenGuids.ContainsKey($guidKey)) {
            Add-Problem $Report "$label - duplicate ExchangeGuid (first seen at record $($seenGuids[$guidKey]))."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (duplicate ExchangeGuid)."
                $Report.RecordsCulled++
                continue
            }
        }
        else {
            $seenGuids[$guidKey] = $index
        }

        if ([string]::IsNullOrWhiteSpace($smtp)) {
            Add-Problem $Report "$label - 'PrimarySmtpAddress' is missing."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (no PrimarySmtpAddress)."
                $Report.RecordsCulled++
                continue
            }
        }

        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyOrNull -Object $record -Name 'DisplayName'))) {
            if ($ApplyRepair -and -not [string]::IsNullOrWhiteSpace($smtp)) {
                Set-FieldValue -Container $record -Name 'DisplayName' -Value $smtp
                Add-RepairNote $Report "$label - filled empty DisplayName from the address."
            }
        }

        $samples = @(Get-PropertyOrNull -Object $record -Name 'Samples')
        if ($samples.Count -eq 0) {
            Add-Problem $Report "$label - has no samples."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (no samples)."
                $Report.RecordsCulled++
                continue
            }
        }

        $Report.SamplesRead += $samples.Count
        $repairsBefore = $Report.Repairs.Count

        $keptSamples = [System.Collections.Generic.List[object]]::new()
        $seenTimestamps = @{}
        $sampleIndex = 0

        foreach ($sample in $samples) {
            $sampleIndex++
            $sampleLabel = "$label sample[$sampleIndex]"

            if (-not (Test-HistorySample -Sample $sample -Label $sampleLabel -Report $Report -ApplyRepair:$ApplyRepair)) {
                if ($ApplyCull) {
                    Add-CullNote $Report "$sampleLabel - removed (unusable)."
                    $Report.SamplesCulled++
                    continue
                }
            }

            $timestampKey = [string](Get-PropertyOrNull -Object $sample -Name 'TimestampUtc')
            if ($seenTimestamps.ContainsKey($timestampKey)) {
                Add-Problem $Report "$sampleLabel - duplicate timestamp '$timestampKey'."
                if ($ApplyCull) {
                    Add-CullNote $Report "$sampleLabel - removed (duplicate timestamp)."
                    $Report.SamplesCulled++
                    continue
                }
            }
            else {
                $seenTimestamps[$timestampKey] = $true
            }

            $keptSamples.Add($sample)
        }

        # Culling every sample leaves a record the dashboard cannot plot.
        if ($ApplyCull -and $keptSamples.Count -eq 0) {
            Add-CullNote $Report "$label - removed (no samples left after culling)."
            $Report.RecordsCulled++
            continue
        }

        if (($ApplyRepair -or $ApplyCull) -and $keptSamples.Count -gt 0) {
            $ordered = @($keptSamples | Sort-Object -Property @{ Expression = { [datetime](Get-PropertyOrNull -Object $_ -Name 'TimestampUtc') } })

            if ($ordered.Count -gt $MaxSamples) {
                $trimmed = $ordered.Count - $MaxSamples
                $ordered = @($ordered | Select-Object -Last $MaxSamples)
                Add-RepairNote $Report "$label - trimmed $trimmed sample(s) beyond the $MaxSamples retained."
                $Report.SamplesCulled += $trimmed
            }

            $record.Samples = $ordered
        }
        elseif ($keptSamples.Count -ne $samples.Count) {
            $record.Samples = @($keptSamples)
        }

        if ($Report.Repairs.Count -gt $repairsBefore) {
            $Report.RecordsRepaired++
        }

        $kept.Add($record)
    }

    $Report.RecordsKept = $kept.Count

    if ($Report.RecordsCulled -gt 0) {
        $Document.MailboxHistory = @($kept)
    }

    return $Document
}

#endregion

#region data.json

function Test-DataDocument {
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)] $Report,
        [Parameter()] [switch]$ApplyRepair,
        [Parameter()] [switch]$ApplyCull
    )

    if ($null -eq (Get-PropertyOrNull -Object $Document -Name 'Mailboxes')) {
        Add-Problem $Report "Top level 'Mailboxes' array is missing."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Document -Name 'Mailboxes' -Value @()
            Add-RepairNote $Report "Added an empty 'Mailboxes' array."
        }
        return $Document
    }

    if ($null -eq (Get-PropertyOrNull -Object $Document -Name 'GeneratedUtc')) {
        Add-Problem $Report "Top level 'GeneratedUtc' is missing."
        if ($ApplyRepair) {
            Set-FieldValue -Container $Document -Name 'GeneratedUtc' -Value ((Get-Date).ToUniversalTime().ToString("o"))
            Add-RepairNote $Report "Added 'GeneratedUtc'."
        }
    }

    $records = @($Document.Mailboxes)
    $Report.RecordsRead = $records.Count

    $seenGuids = @{}
    $kept = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($record in $records) {
        $index++
        $smtp = [string](Get-PropertyOrNull -Object $record -Name 'PrimarySmtpAddress')
        $guid = Get-PropertyOrNull -Object $record -Name 'ExchangeGuid'
        $label = "data[$index] $(if ([string]::IsNullOrWhiteSpace($smtp)) { '<no address>' } else { $smtp })"

        Write-Item -Name $label -Index $index -Total $records.Count

        if (-not (Test-GuidLike -Value $guid)) {
            Add-Problem $Report "$label - 'ExchangeGuid' is missing or not a GUID."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (no usable ExchangeGuid)."
                $Report.RecordsCulled++
                continue
            }
        }

        $guidKey = ([string]$guid).Trim().ToLowerInvariant()
        if ($seenGuids.ContainsKey($guidKey)) {
            Add-Problem $Report "$label - duplicate ExchangeGuid."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (duplicate ExchangeGuid)."
                $Report.RecordsCulled++
                continue
            }
        }
        else {
            $seenGuids[$guidKey] = $index
        }

        $current = Get-PropertyOrNull -Object $record -Name 'current'
        if ($null -eq $current) {
            Add-Problem $Report "$label - 'current' snapshot is missing."
            if ($ApplyCull) {
                Add-CullNote $Report "$label - removed (no current snapshot)."
                $Report.RecordsCulled++
                continue
            }
            $kept.Add($record)
            continue
        }

        $repairsBefore = $Report.Repairs.Count

        $sizeOk = Test-NumericField -Container $current -Name 'totalGB' -Label $label -Report $Report -ApplyRepair:$ApplyRepair

        $quotaRaw = Get-PropertyOrNull -Object $current -Name 'quotaGB'
        $isUnlimited = ($null -eq $quotaRaw) -or ([string]$quotaRaw -eq 'Unlimited')
        $quotaOk = $isUnlimited -or (Test-NumericField -Container $current -Name 'quotaGB' -Label $label -Report $Report -ApplyRepair:$ApplyRepair -MustBePositive)

        $null = Test-NumericField -Container $current -Name 'itemCount' -Label $label -Report $Report -ApplyRepair:$ApplyRepair
        $null = Test-NumericField -Container $current -Name 'archiveSizeGB' -Label $label -Report $Report -ApplyRepair:$ApplyRepair
        $null = Test-NumericField -Container $current -Name 'archiveItemCount' -Label $label -Report $Report -ApplyRepair:$ApplyRepair

        if ($sizeOk -and $quotaOk -and -not $isUnlimited) {
            $totalGb = [double](ConvertTo-NumberOrNull -Value $current.totalGB)
            $quotaGb = [double](ConvertTo-NumberOrNull -Value $current.quotaGB)

            if ($totalGb -gt $quotaGb) {
                Add-Warning $Report "$label - over quota: totalGB $totalGb against quotaGB $quotaGb."
            }

            $expectedUsage = [math]::Round((($totalGb / $quotaGb) * 100), 2)
            $actualUsage = ConvertTo-NumberOrNull -Value (Get-PropertyOrNull -Object $current -Name 'usagePercent')

            if ($null -eq $actualUsage -or [math]::Abs($actualUsage - $expectedUsage) -gt 0.5) {
                Add-Problem $Report "$label - usagePercent ($actualUsage) does not match totalGB/quotaGB (expected $expectedUsage)."
                if ($ApplyRepair) {
                    Set-FieldValue -Container $current -Name 'usagePercent' -Value $expectedUsage
                    Add-RepairNote $Report "$label - recalculated usagePercent as $expectedUsage."
                }
            }
        }
        elseif ($ApplyCull -and -not $quotaOk) {
            Add-CullNote $Report "$label - removed (quotaGB is unusable)."
            $Report.RecordsCulled++
            continue
        }

        $permissions = Get-PropertyOrNull -Object $record -Name 'permissions'
        if ($null -ne $permissions -and $permissions -isnot [array] -and $ApplyRepair) {
            Set-FieldValue -Container $record -Name 'permissions' -Value @($permissions)
            Add-RepairNote $Report "$label - normalised 'permissions' to an array."
        }

        if ($Report.Repairs.Count -gt $repairsBefore) {
            $Report.RecordsRepaired++
        }

        $kept.Add($record)
    }

    $Report.RecordsKept = $kept.Count

    if ($Report.RecordsCulled -gt 0) {
        $Document.Mailboxes = @($kept)
    }

    return $Document
}

#endregion

function Invoke-FileValidation {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [ValidateSet('History', 'Data')] [string]$Kind,
        [Parameter(Mandatory)] [int]$MaxSamples,
        [Parameter()] [switch]$ApplyRepair,
        [Parameter()] [switch]$ApplyCull,
        [Parameter()] [switch]$SkipBackup
    )

    $report = New-ValidationReport -FilePath $FilePath -Kind $Kind

    Write-Stage "Validating $(Split-Path -Path $FilePath -Leaf)"

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Add-Problem $report "File not found at '$FilePath'."
        Write-Notice "File not found: $FilePath"
        return $report
    }

    try {
        $document = Read-MailboxJson -Path $FilePath
    }
    catch {
        Add-Problem $report "File is not valid JSON: $($_.Exception.Message)"
        Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0) -Context "Parsing $FilePath"
        return $report
    }

    if ($null -eq $document) {
        Add-Problem $report "File is empty."
        Write-Notice "File is empty: $FilePath"
        return $report
    }

    $document = if ($Kind -eq 'History') {
        Test-HistoryDocument -Document $document -Report $report -MaxSamples $MaxSamples -ApplyRepair:$ApplyRepair -ApplyCull:$ApplyCull
    }
    else {
        Test-DataDocument -Document $document -Report $report -ApplyRepair:$ApplyRepair -ApplyCull:$ApplyCull
    }

    Write-ValidationSummary -Report $report

    if (($ApplyRepair -or $ApplyCull) -and $report.Changed) {
        if (-not $SkipBackup) {
            $backupPath = "$FilePath.bak"
            Copy-Item -LiteralPath $FilePath -Destination $backupPath -Force
            Write-Detail "Backed up to $(Split-Path -Path $backupPath -Leaf)"
        }

        $recordCount = $report.RecordsKept
        $detail = "$($report.RecordsRepaired) repaired, $($report.RecordsCulled) culled"

        Write-MailboxJson `
            -InputObject $document `
            -Path $FilePath `
            -Source "Test-MailboxDashboardJSON.ps1 ($(if ($ApplyCull) { 'repair + cull' } else { 'repair' }))" `
            -RecordCount $recordCount `
            -RecordDetail $detail
    }
    elseif ($report.Changed) {
        Write-Notice "Problems are repairable - re-run with -Repair to apply the fixes."
    }

    return $report
}

function Write-ValidationSummary {
    param([Parameter(Mandatory)] $Report)

    Write-Detail "Records: $($Report.RecordsRead) read, $($Report.RecordsKept) kept"

    if ($Report.SamplesRead -gt 0) {
        Write-Detail "Samples: $($Report.SamplesRead) read, $($Report.SamplesCulled) removed"
    }

    if ($Report.Warnings.Count -gt 0) {
        Write-Notice "$($Report.Warnings.Count) mailbox(es) over quota:"
        foreach ($warning in @($Report.Warnings | Select-Object -First 5)) {
            Write-ConsoleLine -Message "    $warning" -Colour Yellow
        }
        if ($Report.Warnings.Count -gt 5) {
            Write-Detail "... and $($Report.Warnings.Count - 5) more."
        }
    }

    if ($Report.Problems.Count -eq 0) {
        Write-Success "Schema OK - no problems found."
        return
    }

    Write-Notice "$($Report.Problems.Count) problem(s) found."

    $preview = @($Report.Problems | Select-Object -First 10)
    foreach ($problem in $preview) {
        Write-ConsoleLine -Message "    $problem" -Colour Yellow
    }

    if ($Report.Problems.Count -gt $preview.Count) {
        Write-Detail "... and $($Report.Problems.Count - $preview.Count) more."
    }

    if ($Report.Repairs.Count -gt 0) {
        Write-Success "Repaired $($Report.RecordsRepaired) record(s)."
    }

    if ($Report.Culls.Count -gt 0) {
        Write-Notice "Culled $($Report.RecordsCulled) record(s) and $($Report.SamplesCulled) sample(s)."
    }
}

# --- Entry point -------------------------------------------------------------

$config = Import-MailboxDashboardConfig -ConfigPath $ConfigPath -SkipValidation

if ($Strict -and ($Repair -or $Cull)) {
    throw "-Strict reports without changing anything; it cannot be combined with -Repair or -Cull."
}

$maxSamples = [int]$config.Collection.MaxHistorySamples
$reports = [System.Collections.Generic.List[object]]::new()

$targets = [System.Collections.Generic.List[object]]::new()

if (-not [string]::IsNullOrWhiteSpace($Path)) {
    if ($Target -eq 'Both') {
        throw "-Path requires -Target History or -Target Data."
    }
    $targets.Add(@{ Path = (Resolve-MailboxPath -Path $Path -BaseDirectory $PWD.Path); Kind = $Target })
}
else {
    if ($Target -in @('History', 'Both')) {
        $targets.Add(@{ Path = $config.ResolvedPaths.HistoryJson; Kind = 'History' })
    }
    if ($Target -in @('Data', 'Both')) {
        $targets.Add(@{ Path = $config.ResolvedPaths.DataJson; Kind = 'Data' })
    }
}

foreach ($item in $targets) {
    if (-not $PSCmdlet.ShouldProcess($item.Path, "Validate JSON")) {
        continue
    }

    $reports.Add((Invoke-FileValidation `
        -FilePath $item.Path `
        -Kind $item.Kind `
        -MaxSamples $maxSamples `
        -ApplyRepair:$Repair `
        -ApplyCull:$Cull `
        -SkipBackup:$NoBackup))
}

$totalProblems = 0
foreach ($report in $reports) {
    $totalProblems += $report.Problems.Count
}
$allValid = @($reports | Where-Object { -not $_.IsValid }).Count -eq 0

Write-Stage "Validation complete"
if ($allValid) {
    Write-Success "All checked files match the expected schema."
}
else {
    Write-Notice "$totalProblems problem(s) across $($reports.Count) file(s)."
}

$reports

if ($Strict -and -not $allValid) {
    exit 1
}
