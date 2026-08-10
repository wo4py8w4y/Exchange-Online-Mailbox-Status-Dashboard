<#
.SYNOPSIS
    Exchange Online historical data collector for the dashboard.
.DESCRIPTION
    Collects mailbox usage and archive metrics, appending historical samples
    indexed by ExchangeGuid to history.json without locking web server file
    streams. Includes periodic batch commits for crash recovery.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json"),

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BatchSize = 50,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$TimestampUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptInvocationPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $MyInvocation.MyCommand.Definition }
$scriptBaseDirectory = Split-Path -Path $scriptInvocationPath -Parent

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty."
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    $rootDirectory = if ([string]::IsNullOrWhiteSpace($BaseDirectory)) { $scriptBaseDirectory } else { $BaseDirectory }

    if (-not [string]::IsNullOrWhiteSpace($rootDirectory)) {
        $candidatePaths.Add((Join-Path -Path $rootDirectory -ChildPath $Path))
    }

    $currentLocation = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($currentLocation)) {
        $candidatePaths.Add((Join-Path -Path $currentLocation -ChildPath $Path))
    }

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidatePaths.Add((Join-Path -Path $PSScriptRoot -ChildPath $Path))
    }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return [System.IO.Path]::GetFullPath($candidatePath)
        }
    }

    if ($candidatePaths.Count -gt 0) {
        return [System.IO.Path]::GetFullPath($candidatePaths[0])
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function New-EmptyHistoryData {
    return [pscustomobject]@{
        GeneratedUtc   = ""
        MailboxHistory = @()
    }
}

function Write-JsonSafe {
    param(
        [Parameter(Mandatory)]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Depth = 100
    )

    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    $jsonString = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)

    $fileStream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )

    try {
        $fileStream.Write($bytes, 0, $bytes.Length)
        $fileStream.Flush()
    }
    finally {
        $fileStream.Dispose()
    }
}

function Convert-ToGigabytes {
    param(
        [Parameter()]
        $SizeObject
    )

    if ($null -eq $SizeObject) {
        return 0.0
    }

    try {
        if ($SizeObject.PSObject.Properties.Name -contains "Value" -and
            $SizeObject.Value -and
            $SizeObject.Value.PSObject.Methods.Name -contains "ToBytes") {
            return [Math]::Round([int64]$SizeObject.Value.ToBytes() / 1GB, 2)
        }
    }
    catch {
    }

    $text = [string]$SizeObject
    if ($text -match "\(([\d,]+)\s+bytes\)") {
        $bytes = [int64]($matches[1] -replace ",", "")
        return [Math]::Round($bytes / 1GB, 2)
    }

    return 0.0
}

if (-not (Get-Module -Name ExchangeOnlineManagement)) {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
}

$resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Configuration file not found at '$resolvedConfigPath'."
}

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$configDirectory = Split-Path -Path $resolvedConfigPath -Parent
$configBaseDirectory = Split-Path -Path $configDirectory -Parent

$configuredCsvPath = if ($PSBoundParameters.ContainsKey("CsvPath")) {
    $CsvPath
}
elseif ($config.PSObject.Properties.Name -contains "MailboxesCsvPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.MailboxesCsvPath)) {
    [string]$config.MailboxesCsvPath
}
else {
    [string]$config.CsvPath
}
$configuredHistoryJsonPath = if ($PSBoundParameters.ContainsKey("HistoryJsonPath")) { $HistoryJsonPath } else { [string]$config.HistoryJsonPath }

$resolvedCsvPath = Resolve-AbsolutePath -Path $configuredCsvPath -BaseDirectory $configBaseDirectory
$resolvedHistoryJsonPath = Resolve-AbsolutePath -Path $configuredHistoryJsonPath -BaseDirectory $configBaseDirectory

if (-not (Test-Path -LiteralPath $resolvedCsvPath)) {
    $defaultCsvPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "Mailboxes\mailboxes.csv"
    if (Test-Path -LiteralPath $defaultCsvPath) {
        Write-Warning "Configured CsvPath '$configuredCsvPath' was not found at '$resolvedCsvPath'. Falling back to '$defaultCsvPath'."
        $resolvedCsvPath = $defaultCsvPath
    }
    else {
        throw "Target CSV file not found at '$resolvedCsvPath'."
    }
}

try {
    $null = Get-EXOMailbox -ResultSize 1 -ErrorAction Stop
    Write-Host "`n[SUCCESS] Exchange Online session verified.`n" -ForegroundColor Green
}
catch {
    throw "Exchange Online is not connected. Run 'Connect-ExchangeOnline' before executing."
}

$mailboxes = @(Import-Csv -LiteralPath $resolvedCsvPath)
if ($mailboxes.Count -eq 0) {
    Write-Warning "No mailbox rows were found in '$resolvedCsvPath'. Nothing to collect."
    return
}

$mailboxColumns = @($mailboxes[0].PSObject.Properties.Name)
if (-not ($mailboxColumns -contains "PrimarySMTPAddress")) {
    throw "Mailbox CSV '$resolvedCsvPath' must contain a 'PrimarySMTPAddress' column. Found columns: $($mailboxColumns -join ', ')."
}

Write-Host "Imported $($mailboxes.Count) target mailbox(es) from CSV.`n"

$historyData = New-EmptyHistoryData
if (Test-Path -LiteralPath $resolvedHistoryJsonPath) {
    try {
        $historyData = Get-Content -LiteralPath $resolvedHistoryJsonPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Existing history.json was invalid or corrupt. Initializing new structure."
    }
}

$historyIndex = @{}
if ($null -ne $historyData.MailboxHistory) {
    foreach ($entry in $historyData.MailboxHistory) {
        if ($entry.ExchangeGuid) {
            $historyIndex[[string]$entry.ExchangeGuid] = $entry
        }
    }
}

$updatedMailboxHistory = [System.Collections.Generic.List[psobject]]::new()
if ($null -ne $historyData.MailboxHistory) {
    foreach ($item in $historyData.MailboxHistory) {
        $updatedMailboxHistory.Add($item)
    }
}

$timestampUtcValue = if ($PSBoundParameters.ContainsKey("TimestampUtc")) {
    ([datetimeoffset]::Parse($TimestampUtc)).ToUniversalTime().ToString("o")
}
else {
    (Get-Date).ToUniversalTime().ToString("o")
}

$counter = 0

foreach ($mailbox in $mailboxes) {
    $counter++
    $identity = $mailbox.PrimarySMTPAddress

    if ([string]::IsNullOrWhiteSpace($identity)) {
        Write-Warning "[$counter/$($mailboxes.Count)] Skipping blank identity row in CSV."
        continue
    }

    Write-Host "[$counter/$($mailboxes.Count)] Collecting metrics for [$identity]..." -ForegroundColor Cyan

    try {
        $mailboxInfo = Get-EXOMailbox -Identity $identity -Properties `
            ExchangeGuid, ArchiveGuid, ArchiveStatus, ProhibitSendReceiveQuota -ErrorAction Stop

        $exchangeGuid = [string]$mailboxInfo.ExchangeGuid
        $stats = Get-EXOMailboxStatistics -Identity $identity -ErrorAction Stop
        $sizeGB = Convert-ToGigabytes -SizeObject $stats.TotalItemSize

        $quotaGB = $null
        $usagePercent = $null
        if ($mailboxInfo.ProhibitSendReceiveQuota -and $mailboxInfo.ProhibitSendReceiveQuota.ToString() -ne "Unlimited") {
            $quotaGB = Convert-ToGigabytes -SizeObject $mailboxInfo.ProhibitSendReceiveQuota
            if ($quotaGB -gt 0) {
                $usagePercent = [Math]::Round(($sizeGB / $quotaGB) * 100, 2)
            }
        }

        $permissions = @(Get-EXOMailboxPermission -Identity $identity -ErrorAction SilentlyContinue |
            Where-Object { $_.IsInherited -eq $false -and $_.User -notmatch "NT AUTHORITY\\SELF|S-1-5-" })

        $archiveEnabled = $false
        $archiveSizeGB = 0.0
        $archiveItemCount = 0

        if (($null -ne $mailboxInfo.ArchiveGuid -and $mailboxInfo.ArchiveGuid -ne [Guid]::Empty) -or
            ($mailboxInfo.ArchiveStatus -and $mailboxInfo.ArchiveStatus -ne "None")) {

            $archiveEnabled = $true
            try {
                $archiveStats = Get-EXOMailboxStatistics -Identity $identity -Archive -ErrorAction Stop
                if ($null -ne $archiveStats) {
                    $archiveSizeGB = Convert-ToGigabytes -SizeObject $archiveStats.TotalItemSize
                    $archiveItemCount = [int64]$archiveStats.ItemCount
                }
            }
            catch {
                Write-Warning "  └─ Archive enabled for [$identity], but statistics were unavailable."
            }
        }

        $lastLogonTime = $null
        if ($stats.PSObject.Properties.Name -contains "LastLogonTime" -and $stats.LastLogonTime) {
            try {
                $lastLogonTime = $stats.LastLogonTime.ToString("o")
            }
            catch {
                $lastLogonTime = $null
            }
        }

        $sample = [pscustomobject]@{
            TimestampUtc     = $timestampUtcValue
            SizeGB           = $sizeGB
            ItemCount        = [int64]$stats.ItemCount
            PermissionCount  = $permissions.Count
            QuotaGB          = $quotaGB
            UsagePercent     = $usagePercent
            LastLogonTime    = $lastLogonTime
            ArchiveEnabled   = $archiveEnabled
            ArchiveSizeGB    = $archiveSizeGB
            ArchiveItemCount = $archiveItemCount
        }

        if ($historyIndex.ContainsKey($exchangeGuid)) {
            $existingEntry = $historyIndex[$exchangeGuid]
            $sampleList = [System.Collections.Generic.List[psobject]]::new()

            if ($null -ne $existingEntry.Samples) {
                foreach ($s in $existingEntry.Samples) {
                    $sampleList.Add($s)
                }
            }

            $sampleList.Add($sample)
            $existingEntry.PrimarySmtpAddress = [string]$mailboxInfo.PrimarySmtpAddress
            $existingEntry.DisplayName = [string]$mailboxInfo.DisplayName
            $existingEntry.Samples = @($sampleList)
        }
        else {
            $newEntry = [pscustomobject]@{
                ExchangeGuid       = $exchangeGuid
                PrimarySmtpAddress = [string]$mailboxInfo.PrimarySmtpAddress
                DisplayName        = [string]$mailboxInfo.DisplayName
                Samples            = @($sample)
            }

            $updatedMailboxHistory.Add($newEntry)
            $historyIndex[$exchangeGuid] = $newEntry
        }

        Write-Host "  └─ [OK] Size: ${sizeGB}GB | Quota: ${quotaGB}GB | Archive: ${archiveEnabled} (${archiveSizeGB}GB)" -ForegroundColor Green
    }
    catch {
        Write-Warning "  └─ [FAILED] Mailbox [$identity]: $($_.Exception.Message)"
    }

    if (($counter % $BatchSize -eq 0) -or ($counter -eq $mailboxes.Count)) {
        $batchOutput = [pscustomobject]@{
            GeneratedUtc   = $timestampUtcValue
            MailboxHistory = @($updatedMailboxHistory)
        }

        Write-Host " [BATCH COMMIT] Committing progress to disk ($counter/$($mailboxes.Count))..." -ForegroundColor Yellow
        Write-JsonSafe -InputObject $batchOutput -Path $resolvedHistoryJsonPath -Depth 100
    }
}

Write-Host "`n[SUCCESS] Collection completed cleanly at $timestampUtcValue.`n" -ForegroundColor Green
