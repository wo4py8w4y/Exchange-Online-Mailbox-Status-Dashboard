<#
.SYNOPSIS
    Collects Exchange Online mailbox storage and permission data and writes it to JSON
    for an IIS-hosted dashboard.
.DESCRIPTION
    Connects to Exchange Online, collects mailbox usage and permission metrics, and
    writes current and historical data files for the mailbox dashboard.
.NOTES
    CHANGELOG
    ----------
    2026-06-22 - Replaced array math operators with stream subexpressions to completely eliminate op_Addition faults.
.EXAMPLE
    .\Update-MailboxDashboard.ps1 -UseFilePicker -Interactive
#>

[CmdletBinding(DefaultParameterSetName = "Certificate")]
param(
    [Parameter()]
    [string]$CsvPath = "F:\Website\Qbuild-Mon\Collector\users.csv",

    [Parameter()]
    [string]$OutputJsonPath = "F:\Website\Qbuild-Mon\Web\data.json",

    [Parameter()]
    [string]$HistoryJsonPath = "F:\Website\Qbuild-Mon\Web\history.json",

    [Parameter()]
    [switch]$UseFilePicker,

    [Parameter(ParameterSetName = "Interactive")]
    [switch]$Interactive,

    [Parameter(ParameterSetName = "Certificate")]
    [string]$AppId,

    [Parameter(ParameterSetName = "Certificate")]
    [string]$Organization,

    [Parameter(ParameterSetName = "Certificate")]
    [string]$CertificateThumbprint,

    [Parameter()]
    [int]$MaxHistorySamples = 365,

    [Parameter()]
    [double]$CriticalThresholdPercent = 94,

    [Parameter()]
    [double]$WarningThresholdPercent = 85,

    [Parameter()]
    [switch]$IncludeArchive,

    [Parameter()]
    [switch]$IncludeSendAs,

    [Parameter()]
    [switch]$IncludeFolderPermissions,

    [Parameter()]
    [int]$CollectorScheduleMinutes = 30,

    [Parameter()]
    [int]$WebRefreshSeconds = 60,

    [Parameter()]
    [bool]$RegisterScheduledTask,

    [Parameter()]
    [string]$ScheduledTaskName = "Exchange Online Mailbox Dashboard Collector",

    [Parameter()]
    [string]$WebRootPath = "F:\Website\Qbuild-Mon\Web",

    [Parameter()]
    [string]$DashboardUrl = "http://localhost:8888/",

    [Parameter()]
    [string]$LogRootPath = "F:\Website\Qbuild-Mon\Collector\Logs",

    [Parameter()]
    [string]$LogFilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Logging & Structural Helpers
# ---------------------------------------------------------------------------
$script:LogFilePath = $null
$script:TranscriptFilePath = $null
$script:TranscriptStarted = $false

function Write-LogFileEntry {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Entry,
        [int]$MaxRetries = 3,
        [int]$RetryDelayMilliseconds = 150
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $stream = $null; $writer = $null
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
            $writer.WriteLine($Entry)
            $writer.Flush()
            return $true
        }
        catch {
            if ($attempt -ge $MaxRetries) { return $false }
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
        finally {
            if ($null -ne $writer) { $writer.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return $false
}

function New-DashboardTranscriptFilePath {
    param([Parameter(Mandatory)] [string]$LogFilePath)
    $extension = [System.IO.Path]::GetExtension($LogFilePath)
    if ([string]::IsNullOrWhiteSpace($extension)) { return "$LogFilePath.transcript.log" }
    $directory = Split-Path -Path $LogFilePath -Parent
    $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($LogFilePath)
    return Join-Path -Path $directory -ChildPath "$fileNameWithoutExtension.transcript$extension"
}

function New-DashboardLogFilePath {
    param([Parameter(Mandatory)] [string]$LogRootPath, [string]$Prefix = "MailboxDashboardCollector")
    if (-not (Test-Path -LiteralPath $LogRootPath)) { New-Item -Path $LogRootPath -ItemType Directory -Force | Out-Null }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path $LogRootPath "$Prefix-$timestamp-$env:COMPUTERNAME-PID$PID.log"
}

function Start-DashboardLogging {
    param([Parameter(Mandatory)] [string]$LogRootPath, [string]$LogFilePath)
    if ([string]::IsNullOrWhiteSpace($LogFilePath)) { $LogFilePath = New-DashboardLogFilePath -LogRootPath $LogRootPath }
    else {
        $parent = Split-Path -Path $LogFilePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    }
    $script:LogFilePath = $LogFilePath
    $script:TranscriptFilePath = New-DashboardTranscriptFilePath -LogFilePath $script:LogFilePath

    "[$(Get-Date -Format o)] [START] [INFO] Log file initialised: $script:LogFilePath" | Set-Content -LiteralPath $script:LogFilePath -Encoding UTF8
    "[$(Get-Date -Format o)] [START] [INFO] Transcript file initialised: $script:TranscriptFilePath" | Set-Content -LiteralPath $script:TranscriptFilePath -Encoding UTF8

    try {
        Start-Transcript -Path $script:TranscriptFilePath -Append -IncludeInvocationHeader | Out-Null
        $script:TranscriptStarted = $true
        Write-Log -Tag "START" -Level "INFO" -Message "PowerShell transcript started: $script:TranscriptFilePath"
    }
    catch {
        $script:TranscriptStarted = $false
        [void](Write-LogFileEntry -Path $script:LogFilePath -Entry "[$(Get-Date -Format o)] [START] [WARN] Start-Transcript failed: $($_.Exception.Message)")
    }
    return $script:LogFilePath
}

function Stop-DashboardLogging {
    if ($script:TranscriptStarted) {
        try {
            Write-Log -Tag "END" -Level "INFO" -Message "Stopping PowerShell transcript."
            Stop-Transcript | Out-Null
        }
        catch {
            [void](Write-LogFileEntry -Path $script:LogFilePath -Entry "[$(Get-Date -Format o)] [END] [WARN] Stop-Transcript failed: $($_.Exception.Message)")
        }
    }
}

function Write-Log {
    param([Parameter(Mandatory)] [string]$Tag, [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "SUCCESS")] [string]$Level = "INFO", [Parameter(Mandatory)] [string]$Message, [switch]$NoConsole)
    $entry = "[$(Get-Date -Format o)] [$Tag] [$Level] $Message"
    if (-not [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        [void](Write-LogFileEntry -Path $script:LogFilePath -Entry $entry)
    }
    if (-not $NoConsole) {
        switch ($Level) {
            "ERROR"   { Write-Host $entry -ForegroundColor Red }
            "WARN"    { Write-Host $entry -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $entry -ForegroundColor Green }
            "DEBUG"   { Write-Host $entry -ForegroundColor DarkGray }
            default   { Write-Host $entry }
        }
    }
}

function Write-LogBlock {
    param([Parameter(Mandatory)] [string]$Tag, [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "SUCCESS")] [string]$Level = "INFO", [Parameter(Mandatory)] [string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Log -Tag $Tag -Level $Level -Message $line }
    }
}

function Join-DashboardUrl {
    param([Parameter(Mandatory)] [string]$BaseUrl, [Parameter(Mandatory)] [string]$Page)
    return "$($BaseUrl.TrimEnd('/'))/$Page"
}

function Get-CsvFileFromPicker {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog -Property @{ Title = "Select mailbox CSV"; Filter = "CSV files (*.csv)|*.csv"; Multiselect = $false }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    throw "No CSV file was selected."
}

function Convert-ExoSizeToBytes {
    param([Parameter(Mandatory)] $SizeObject)
    if ($null -eq $SizeObject) { return 0 }
    try {
        if ($SizeObject.PSObject.Properties.Name -contains "Value" -and $SizeObject.Value -and $SizeObject.Value.PSObject.Methods.Name -contains "ToBytes") {
            return [int64]$SizeObject.Value.ToBytes()
        }
    } catch {}
    $text = [string]$SizeObject
    if ($text -match "\(([\d,]+)\s+bytes\)") { return ($matches[1] -replace ",", "") }
    if ($text -match "([\d\.]+)\s*(KB|MB|GB|TB)") {
        $value = [double]$matches[1]
        switch ($matches[2]) {
            "KB" { return $value * 1KB }
            "MB" { return $value * 1MB }
            "GB" { return $value * 1GB }
            "TB" { return $value * 1TB }
        }
    }
    return 0
}

function Convert-BytesToGB {
    param([int64]$Bytes)
    if ($Bytes -le 0) { return 0 }
    return [Math]::Round($Bytes / 1GB, 2)
}

function Read-JsonFile {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Could not read JSON file '$Path'. $($_.Exception.Message)"
        return $null
    }
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string]$Path,
        [int]$Depth = 12,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMilliseconds = 200
    )
    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }

    $jsonString = ConvertTo-Json -InputObject $InputObject -Depth $Depth

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $stream = $null; $writer = $null
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
            $writer.Write($jsonString)
            $writer.Flush()
            return $true
        }
        catch {
            if ($attempt -ge $MaxRetries) { throw $_ }
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
        finally {
            if ($null -ne $writer) { $writer.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return $false
}

function Get-HistoryMap {
    param($HistoryData)
    $map = @{}
    if ($null -eq $HistoryData -or $null -eq $HistoryData.MailboxHistory) { return $map }
    foreach ($entry in $HistoryData.MailboxHistory) {
        if ($entry.PrimarySmtpAddress) { $map[[string]$entry.PrimarySmtpAddress] = @($entry.Samples) }
    }
    return $map
}

function Connect-ToExchangeOnline {
    if ($Interactive) { Connect-ExchangeOnline -ShowBanner:$false; return }
    if ([string]::IsNullOrWhiteSpace($AppId) -or [string]::IsNullOrWhiteSpace($Organization) -or [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        throw "For unattended execution, supply -AppId, -Organization and -CertificateThumbprint."
    }
    Connect-ExchangeOnline -AppId $AppId -Organization $Organization -CertificateThumbprint $CertificateThumbprint -ShowBanner:$false
}

function Show-DashboardRuntimeSummary {
    param($CsvPath, $OutputJsonPath, $HistoryJsonPath, $WebRootPath, $DashboardUrl, $Organization, $AppId, $CertificateThumbprint, $WarningThresholdPercent, $CriticalThresholdPercent, $WebRefreshSeconds, $CollectorScheduleMinutes, $ScheduledTaskName, [switch]$RegisterScheduledTask)
    $summary = @"

============================================================
 Exchange Online Mailbox Dashboard Collector Configuration
============================================================
CSV input file:              $CsvPath
Current data JSON:           $OutputJsonPath
Historical data JSON:        $HistoryJsonPath
Web root path:               $WebRootPath

Dashboard URL:               $DashboardUrl
Overview page:               $DashboardUrl/index.html

Organization:                $Organization
App ID:                      $AppId
Warning threshold:           $WarningThresholdPercent%
Critical threshold:          $CriticalThresholdPercent%
============================================================
"@
    Write-Host $summary -ForegroundColor Cyan
}

function Get-MailboxDashboardRecord {
    param([Parameter(Mandatory)] [string]$Identity, [Parameter(Mandatory)] [hashtable]$HistoryMap, [Parameter(Mandatory)] [datetime]$SnapshotTimeUtc)
    
    $mailbox = Get-EXOMailbox -Identity $Identity -Properties DisplayName,PrimarySmtpAddress,RecipientTypeDetails,ProhibitSendQuota,ProhibitSendReceiveQuota,IssueWarningQuota,GrantSendOnBehalfTo
    $stats = Get-EXOMailboxStatistics -Identity $Identity

    $totalBytes = Convert-ExoSizeToBytes -SizeObject $stats.TotalItemSize
    $totalGB = Convert-BytesToGB -Bytes $totalBytes
    $quotaBytes = Convert-ExoSizeToBytes -SizeObject $mailbox.ProhibitSendReceiveQuota
    $quotaGB = Convert-BytesToGB -Bytes $quotaBytes
    $usagePercent = if ($quotaBytes -gt 0) { [Math]::Round(($totalBytes / $quotaBytes) * 100, 2) } else { $null }

    $fullAccessPermissions = @(
        Get-EXOMailboxPermission -Identity $Identity -ResultSize Unlimited |
            Where-Object { $_.IsInherited -eq $false -and $_.Deny -eq $false -and $_.User -notmatch "NT AUTHORITY\\SELF" -and $_.User -notmatch "S-1-5-" } |
            Select-Object @{Name = "PermissionType"; Expression = { "MailboxPermission" }}, @{Name = "User"; Expression = { [string]$_.User }}, @{Name = "AccessRights"; Expression = { ($_.AccessRights -join ", ") }}, @{Name = "IsInherited"; Expression = { [bool]$_.IsInherited }}, @{Name = "Deny"; Expression = { [bool]$_.Deny }}
    )

    $sendAsPermissions = @()
    if ($IncludeSendAs) {
        try {
            $sendAsPermissions = @(
                Get-EXORecipientPermission -Identity $Identity -ResultSize Unlimited |
                    Where-Object { $_.IsInherited -eq $false -and $_.Deny -eq $false -and $_.Trustee -notmatch "NT AUTHORITY\\SELF" -and $_.Trustee -notmatch "S-1-5-" } |
                    Select-Object @{Name = "PermissionType"; Expression = { "SendAs" }}, @{Name = "User"; Expression = { [string]$_.Trustee }}, @{Name = "AccessRights"; Expression = { ($_.AccessRights -join ", ") }}, @{Name = "IsInherited"; Expression = { [bool]$_.IsInherited }}, @{Name = "Deny"; Expression = { [bool]$_.Deny }}
            )
        } catch { Write-Warning "Could not query Send As permissions for $Identity." }
    }

    $folderPermissions = @()
    if ($IncludeFolderPermissions) {
        foreach ($folderName in @("Calendar", "Inbox")) {
            try {
                $folderPermissions += @(
                    Get-EXOMailboxFolderPermission -Identity "$($mailbox.PrimarySmtpAddress):\$folderName" |
                        Where-Object { $_.User -notmatch "Default" -and $_.User -notmatch "Anonymous" } |
                        Select-Object @{Name = "PermissionType"; Expression = { "Folder:$folderName" }}, @{Name = "User"; Expression = { [string]$_.User }}, @{Name = "AccessRights"; Expression = { ($_.AccessRights -join ", ") }}, @{Name = "IsInherited"; Expression = { $false }}, @{Name = "Deny"; Expression = { $false }}
                )
            } catch { Write-Warning "Could not query $folderName folder permissions for $Identity." }
        }
    }

    $sendOnBehalf = @()
    if ($mailbox.GrantSendOnBehalfTo) {
        $sendOnBehalf = @($mailbox.GrantSendOnBehalfTo | ForEach-Object {
            [pscustomobject]@{ PermissionType = "SendOnBehalf"; User = [string]$_; AccessRights = "SendOnBehalf"; IsInherited = $false; Deny = $false }
        })
    }

    $permissions = @($fullAccessPermissions + $sendAsPermissions + $sendOnBehalf + $folderPermissions)
    $archive = $null
    if ($IncludeArchive) {
        try {
            $archiveStats = Get-EXOMailboxStatistics -Identity $Identity -Archive
            $archiveBytes = Convert-ExoSizeToBytes -SizeObject $archiveStats.TotalItemSize
            $archive = [pscustomobject]@{ TotalBytes = $archiveBytes; TotalGB = Convert-BytesToGB -Bytes $archiveBytes; ItemCount = [int64]$archiveStats.ItemCount }
        } catch { $archive = [pscustomobject]@{ Error = "Archive unavailable." } }
    }

    $thresholdState = if ($usagePercent -ge $CriticalThresholdPercent) { "critical" } elseif ($usagePercent -ge $WarningThresholdPercent) { "warning" } else { "ok" }

    return [pscustomobject]@{
        Current = [pscustomobject]@{
            DisplayName              = [string]$mailbox.DisplayName
            PrimarySmtpAddress       = [string]$mailbox.PrimarySmtpAddress
            RecipientTypeDetails     = [string]$mailbox.RecipientTypeDetails
            TotalBytes               = $totalBytes
            TotalGB                  = $totalGB
            ItemCount                = [int64]$stats.ItemCount
            DeletedItemCount         = [int64]$stats.DeletedItemCount
            ProhibitSendReceiveQuota = [string]$mailbox.ProhibitSendReceiveQuota
            QuotaGB                  = $quotaGB
            UsagePercent             = $usagePercent
            ThresholdState           = $thresholdState
            Archive                  = $archive
            Permissions              = $permissions
        }
        History = [pscustomobject]@{
            TimestampUtc    = $SnapshotTimeUtc.ToString("o")
            TotalBytes      = $totalBytes
            TotalGB         = $totalGB
            QuotaGB         = $quotaGB
            UsagePercent    = $usagePercent
            ItemCount       = [int64]$stats.ItemCount
            DeletedItems    = [int64]$stats.DeletedItemCount
            PermissionCount = $permissions.Count
            ThresholdState  = $thresholdState
        }
    }
}

function Show-CriticalThresholdReport {
    param(
        [Parameter(Mandatory)] [array]$ThresholdMailboxes,
        [Parameter(Mandatory)] [double]$CriticalThresholdPercent
    )
    Write-Log -Tag "THRESHOLD" -Message "Mailboxes exceeding critical threshold ($CriticalThresholdPercent%): $($ThresholdMailboxes.Count)"
    if ($ThresholdMailboxes.Count -eq 0) { return }
    
    $tableText = $ThresholdMailboxes | Select-Object `
        PrimarySmtpAddress, DisplayName, TotalGB, QuotaGB, UsagePercent | Format-Table -AutoSize | Out-String
    Write-LogBlock -Tag "THRESHOLD" -Level "WARN" -Text $tableText
}

function Register-MailboxDashboardScheduledTask {
    param([Parameter(Mandatory)] [string]$TaskName, [Parameter(Mandatory)] [string]$ScriptPath, [Parameter(Mandatory)] [string]$CsvPath, [Parameter(Mandatory)] [string]$OutputJsonPath, [Parameter(Mandatory)] [string]$HistoryJsonPath, [Parameter(Mandatory)] [string]$WebRootPath, [Parameter(Mandatory)] [string]$DashboardUrl, [Parameter(Mandatory)] [string]$AppId, [Parameter(Mandatory)] [string]$Organization, [Parameter(Mandatory)] [string]$CertificateThumbprint, [double]$WarningThresholdPercent, [double]$CriticalThresholdPercent, [int]$WebRefreshSeconds, [int]$CollectorScheduleMinutes, [switch]$IncludeSendAs, [switch]$IncludeArchive, [switch]$IncludeFolderPermissions, [string]$LogRootPath)
    
    $arguments = @("-NoProfile", "-ExecutionPolicy Bypass", "-File `"$ScriptPath`"", "-CsvPath `"$CsvPath`"", "-OutputJsonPath `"$OutputJsonPath`"", "-HistoryJsonPath `"$HistoryJsonPath`"", "-WebRootPath `"$WebRootPath`"", "-DashboardUrl `"$DashboardUrl`"", "-AppId `"$AppId`"", "-Organization `"$Organization`"", "-CertificateThumbprint `"$CertificateThumbprint`"")
    if ($IncludeSendAs) { $arguments += "-IncludeSendAs" }
    if ($IncludeArchive) { $arguments += "-IncludeArchive" }
    if ($IncludeFolderPermissions) { $arguments += "-IncludeFolderPermissions" }

    $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument ($arguments -join " ")
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $CollectorScheduleMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Exo Mailbox Dynamic Dashboard Collector Task" -Force
    Write-Host "Scheduled task '$TaskName' registered cleanly." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Execution Block Lifecycle
# ---------------------------------------------------------------------------
try {
    $resolvedLogPath = Start-DashboardLogging -LogRootPath $LogRootPath -LogFilePath $LogFilePath
    Write-Log -Tag "START" -Message "Collector runtime execution initialized."

    $OverviewUrl   = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "index.html"
    $ThresholdsUrl = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "thresholds.html"
    $HistoryUrl    = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "history.html"
    $PermissionsUrl = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "permissions.html"

    if ($UseFilePicker -or [string]::IsNullOrWhiteSpace($CsvPath)) {
        $CsvPath = Get-CsvFileFromPicker
    }
    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV target data mapping missing: $CsvPath" }

    Show-DashboardRuntimeSummary -CsvPath $CsvPath -OutputJsonPath $OutputJsonPath -HistoryJsonPath $HistoryJsonPath -WebRootPath $WebRootPath -DashboardUrl $OverviewUrl -Organization $Organization -AppId $AppId -CertificateThumbprint $CertificateThumbprint -WarningThresholdPercent $WarningThresholdPercent -CriticalThresholdPercent $CriticalThresholdPercent -WebRefreshSeconds $WebRefreshSeconds -CollectorScheduleMinutes $CollectorScheduleMinutes -ScheduledTaskName $ScheduledTaskName -RegisterScheduledTask:$RegisterScheduledTask

    Write-Log -Tag "INPUT" -Message "Processing structural targets from matching CSV mappings."
    $mailboxRows = Import-Csv -LiteralPath $CsvPath
    if (-not $mailboxRows -or -not ($mailboxRows[0].PSObject.Properties.Name -contains "Mailbox")) {
        throw "CSV structure validation broken. Target header definition requires field attribute named 'Mailbox'."
    }

    Write-Log -Tag "EXO" -Message "Loading endpoint interaction module layers."
    Import-Module ExchangeOnlineManagement
    Connect-ToExchangeOnline
    Write-Log -Tag "EXO" -Level "SUCCESS" -Message "Remote endpoint synchronization pipeline connected."

    $snapshotTimeUtc = (Get-Date).ToUniversalTime()
    $existingHistoryData = Read-JsonFile -Path $HistoryJsonPath
    $historyMap = Get-HistoryMap -HistoryData $existingHistoryData

    $currentRecords = @()
    $newHistorySamples = @()

    foreach ($row in $mailboxRows) {
        if ([string]::IsNullOrWhiteSpace($row.Mailbox)) { continue }
        $mailboxIdentity = $row.Mailbox.Trim()
        
        try {
            $result = Get-MailboxDashboardRecord -Identity $mailboxIdentity -HistoryMap $historyMap -SnapshotTimeUtc $snapshotTimeUtc
            $currentRecords += $result.Current
            $newHistorySamples += [pscustomobject]@{
                PrimarySmtpAddress = $result.Current.PrimarySmtpAddress
                DisplayName        = $result.Current.DisplayName
                Sample             = $result.History
            }
            Write-Log -Tag "QUERY" -Level "SUCCESS" -Message "Data synchronized for mapping target address [$($result.Current.PrimarySmtpAddress)]."
        }
        catch {
            Write-Log -Tag "QUERY" -Level "ERROR" -Message "Target collection step dropped for entry ID: $mailboxIdentity. Failure: $($_.Exception.Message)"
        }
    }

    $thresholdMailboxes = @(
        $currentRecords | Where-Object { $null -ne $_.UsagePercent -and $_.UsagePercent -ge $CriticalThresholdPercent } | Sort-Object { $_.UsagePercent } -Descending
    )

    Show-CriticalThresholdReport -ThresholdMailboxes $thresholdMailboxes -CriticalThresholdPercent $CriticalThresholdPercent

    $currentDashboardData = [pscustomobject]@{
        GeneratedUtc             = $snapshotTimeUtc.ToString("o")
        SourceCsv                = $CsvPath
        WebRootPath              = $WebRootPath
        OutputJsonPath           = $OutputJsonPath
        MailboxCount             = $currentRecords.Count
        WarningThresholdPercent  = $WarningThresholdPercent
        CriticalThresholdPercent = $CriticalThresholdPercent
        ThresholdCount           = $thresholdMailboxes.Count
        Mailboxes                = $currentRecords
        ThresholdMailboxes       = $thresholdMailboxes
    }

    $updatedHistoryEntries = @()
    foreach ($record in $currentRecords) {
        $smtp = [string]$record.PrimarySmtpAddress
        $existingSamples = if ($historyMap.ContainsKey($smtp)) { @($historyMap[$smtp]) } else { @() }
        $newSample = @($newHistorySamples | Where-Object { $_.PrimarySmtpAddress -eq $smtp } | Select-Object -ExpandProperty Sample)
        
        # FIX: Concat collections via streaming subexpression to prevent [PSObject] operator bugs
        $samples = @(
            $existingSamples | ForEach-Object { $_ }
            $newSample | ForEach-Object { $_ }
        ) | Select-Object -Last $MaxHistorySamples

        $updatedHistoryEntries += [pscustomobject]@{
            PrimarySmtpAddress = $smtp
            DisplayName        = [string]$record.DisplayName
            Samples            = $samples
        }
    }

    $historyOutput = [pscustomobject]@{
        MailboxHistory    = $updatedHistoryEntries
        GeneratedUtc      = $snapshotTimeUtc.ToString("o")
        MaxHistorySamples = $MaxHistorySamples
    }

    Write-Log -Tag "JSON" -Message "Writing current atomic metrics frame structure over to: $OutputJsonPath"
    Write-JsonFileAtomic -InputObject $currentDashboardData -Path $OutputJsonPath -Depth 12

    Write-Log -Tag "JSON" -Message "Appending timeline history payload map matrix into target: $HistoryJsonPath"
    Write-JsonFileAtomic -InputObject $historyOutput -Path $HistoryJsonPath -Depth 12

    if ($RegisterScheduledTask) {
        Register-MailboxDashboardScheduledTask -TaskName $ScheduledTaskName -ScriptPath $PSCommandPath -CsvPath $CsvPath -OutputJsonPath $OutputJsonPath -HistoryJsonPath $HistoryJsonPath -WebRootPath $WebRootPath -DashboardUrl $DashboardUrl -AppId $AppId -Organization $Organization -CertificateThumbprint $CertificateThumbprint -WarningThresholdPercent $WarningThresholdPercent -CriticalThresholdPercent $CriticalThresholdPercent -WebRefreshSeconds $WebRefreshSeconds -CollectorScheduleMinutes $CollectorScheduleMinutes -IncludeSendAs:$IncludeSendAs -IncludeArchive:$IncludeArchive -IncludeFolderPermissions:$IncludeFolderPermissions -LogRootPath $LogRootPath
    }
}
catch {
    Write-Log -Tag "ERROR" -Level "ERROR" -Message "Execution block validation faulted out globally. Message details: $($_.Exception.Message)"
    Write-LogBlock -Tag "ERROR" -Level "ERROR" -Text ($_.ScriptStackTrace | Out-String)
    throw $_
}
finally {
    Write-Log -Tag "EXO" -Message "Terminating active Exchange cloud infrastructure endpoints cleanly."
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log -Tag "END" -Message "Data lifecycle synchronization runtime finished completely."
    Stop-DashboardLogging
}