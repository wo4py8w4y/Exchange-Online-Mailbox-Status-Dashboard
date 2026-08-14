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

[CmdletBinding(DefaultParameterSetName = "ConfigOnly")]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json"),

    [Parameter()]
    [switch]$SkipConfigValidation,

    [Parameter()]
    [switch]$UseFilePicker,

    [Parameter(ParameterSetName = "ConfigOnly")]
    [Parameter(ParameterSetName = "ConfigWithAuthOverride")]
    [switch]$Interactive,

    [Parameter(ParameterSetName = "ConfigWithAuthOverride")]
    [string]$AppId,

    [Parameter(ParameterSetName = "ConfigWithAuthOverride")]
    [string]$Organization,

    [Parameter(ParameterSetName = "ConfigWithAuthOverride")]
    [string]$CertificateThumbprint,

    [Parameter(ParameterSetName = "ConfigWithAuthOverride")]
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty."
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $root = if ([string]::IsNullOrWhiteSpace($BaseDirectory)) { $PSScriptRoot } else { $BaseDirectory }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $root -ChildPath $Path))
}

function Test-ConfigHasNonEmptyStringValue {
    param(
        [Parameter(Mandatory)] $ConfigObject,
        [Parameter(Mandatory)] [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($ConfigObject.PSObject.Properties.Name -contains $name) {
            $value = $ConfigObject.$name
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $true
            }
        }
    }

    return $false
}

function Validate-DashboardConfig {
    param(
        [Parameter(Mandatory)] $ConfigObject,
        [Parameter(Mandatory)] [string]$ResolvedConfigPath,
        [Parameter(Mandatory)] [bool]$IsInteractiveMode
    )

    $issues = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("MailboxesCsvPath", "CsvPath"))) {
        $issues.Add("Either 'MailboxesCsvPath' or 'CsvPath' must be provided.")
    }

    if (-not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("HotDataJsonPath", "OutputJsonPath"))) {
        $issues.Add("Either 'HotDataJsonPath' or 'OutputJsonPath' must be provided.")
    }

    if (-not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("HistoryJsonPath"))) {
        $issues.Add("'HistoryJsonPath' must be provided.")
    }

    if (-not $IsInteractiveMode) {
        if (-not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("Organization"))) {
            $issues.Add("'Organization' must be provided for unattended execution.")
        }
        if (-not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("AppID", "AppId"))) {
            $issues.Add("Either 'AppID' or 'AppId' must be provided for unattended execution.")
        }
        if (-not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("Thumbprint", "CertificateThumbprint"))) {
            $issues.Add("Either 'Thumbprint' or 'CertificateThumbprint' must be provided for unattended execution.")
        }
    }

    $maxHistorySamples = if ($ConfigObject.PSObject.Properties.Name -contains "MaxHistorySamples" -and $null -ne $ConfigObject.MaxHistorySamples) { [int]$ConfigObject.MaxHistorySamples } else { 365 }
    if ($maxHistorySamples -lt 1) {
        $issues.Add("'MaxHistorySamples' must be greater than 0.")
    }

    $warningThresholdPercent = if ($ConfigObject.PSObject.Properties.Name -contains "WarningThresholdPercent" -and $null -ne $ConfigObject.WarningThresholdPercent) { [double]$ConfigObject.WarningThresholdPercent } else { 85.0 }
    $criticalThresholdPercent = if ($ConfigObject.PSObject.Properties.Name -contains "CriticalThresholdPercent" -and $null -ne $ConfigObject.CriticalThresholdPercent) { [double]$ConfigObject.CriticalThresholdPercent } else { 94.0 }

    if ($warningThresholdPercent -lt 0 -or $warningThresholdPercent -gt 100) {
        $issues.Add("'WarningThresholdPercent' must be between 0 and 100.")
    }
    if ($criticalThresholdPercent -lt 0 -or $criticalThresholdPercent -gt 100) {
        $issues.Add("'CriticalThresholdPercent' must be between 0 and 100.")
    }
    if ($warningThresholdPercent -ge $criticalThresholdPercent) {
        $issues.Add("'WarningThresholdPercent' must be less than 'CriticalThresholdPercent'.")
    }

    $collectorScheduleMinutes = if ($ConfigObject.PSObject.Properties.Name -contains "CollectorScheduleMinutes" -and $null -ne $ConfigObject.CollectorScheduleMinutes) { [int]$ConfigObject.CollectorScheduleMinutes } else { 30 }
    if ($collectorScheduleMinutes -lt 1) {
        $issues.Add("'CollectorScheduleMinutes' must be greater than 0.")
    }

    $webRefreshSeconds = if ($ConfigObject.PSObject.Properties.Name -contains "WebRefreshSeconds" -and $null -ne $ConfigObject.WebRefreshSeconds) { [int]$ConfigObject.WebRefreshSeconds } else { 60 }
    if ($webRefreshSeconds -lt 1) {
        $issues.Add("'WebRefreshSeconds' must be greater than 0.")
    }

    $registerScheduledTask = if ($ConfigObject.PSObject.Properties.Name -contains "RegisterScheduledTask") { [bool]$ConfigObject.RegisterScheduledTask } else { $false }
    if ($registerScheduledTask -and -not (Test-ConfigHasNonEmptyStringValue -ConfigObject $ConfigObject -Names @("ScheduledTaskName"))) {
        $issues.Add("'ScheduledTaskName' must be provided when 'RegisterScheduledTask' is true.")
    }

    if ($issues.Count -gt 0) {
        $details = $issues | ForEach-Object { " - $_" } | Out-String
        throw "Config validation failed for '$ResolvedConfigPath':`n$details"
    }
}

$defaultConfigPath = Resolve-AbsolutePath -Path (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json")
$resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Configuration file not found at '$resolvedConfigPath'."
}

$isAlternateConfig = $resolvedConfigPath -ne $defaultConfigPath
$usedAuthOverrides = $PSBoundParameters.ContainsKey("AppId") -or
    $PSBoundParameters.ContainsKey("Organization") -or
    $PSBoundParameters.ContainsKey("CertificateThumbprint") -or
    $PSBoundParameters.ContainsKey("ClientSecret")

if ($usedAuthOverrides -and -not $isAlternateConfig) {
    throw "AppId/Organization/CertificateThumbprint/ClientSecret overrides are only allowed when -ConfigPath points to an alternate config file."
}

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$skipConfigValidationFromConfig = if ($config.PSObject.Properties.Name -contains "SkipConfigValidation") { [bool]$config.SkipConfigValidation } else { $false }
$effectiveSkipConfigValidation = if ($PSBoundParameters.ContainsKey("SkipConfigValidation")) { [bool]$SkipConfigValidation } else { $skipConfigValidationFromConfig }
if (-not $effectiveSkipConfigValidation) {
    Validate-DashboardConfig -ConfigObject $config -ResolvedConfigPath $resolvedConfigPath -IsInteractiveMode ([bool]$Interactive)
}
$configDirectory = Split-Path -Path $resolvedConfigPath -Parent
$configBaseDirectory = Split-Path -Path $configDirectory -Parent

$CsvPath = if ($UseFilePicker) {
    $null
}
elseif ($config.PSObject.Properties.Name -contains "MailboxesCsvPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.MailboxesCsvPath)) {
    Resolve-AbsolutePath -Path ([string]$config.MailboxesCsvPath) -BaseDirectory $configBaseDirectory
}
elseif ($config.PSObject.Properties.Name -contains "CsvPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.CsvPath)) {
    Resolve-AbsolutePath -Path ([string]$config.CsvPath) -BaseDirectory $configBaseDirectory
}
else {
    Resolve-AbsolutePath -Path "..\Mailboxes\mailboxes.csv" -BaseDirectory $PSScriptRoot
}

$OutputJsonPath = if ($config.PSObject.Properties.Name -contains "HotDataJsonPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.HotDataJsonPath)) {
    Resolve-AbsolutePath -Path ([string]$config.HotDataJsonPath) -BaseDirectory $configBaseDirectory
}
elseif ($config.PSObject.Properties.Name -contains "OutputJsonPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.OutputJsonPath)) {
    Resolve-AbsolutePath -Path ([string]$config.OutputJsonPath) -BaseDirectory $configBaseDirectory
}
else {
    Resolve-AbsolutePath -Path "..\Web\data.json" -BaseDirectory $PSScriptRoot
}

$HistoryJsonPath = if ($config.PSObject.Properties.Name -contains "HistoryJsonPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.HistoryJsonPath)) {
    Resolve-AbsolutePath -Path ([string]$config.HistoryJsonPath) -BaseDirectory $configBaseDirectory
}
else {
    Resolve-AbsolutePath -Path "..\Web\history.json" -BaseDirectory $PSScriptRoot
}

$WebRootPath = if ($config.PSObject.Properties.Name -contains "WebRootPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.WebRootPath)) {
    Resolve-AbsolutePath -Path ([string]$config.WebRootPath) -BaseDirectory $configBaseDirectory
}
else {
    Split-Path -Path $OutputJsonPath -Parent
}

$DashboardUrl = if ($config.PSObject.Properties.Name -contains "DashboardUrl" -and -not [string]::IsNullOrWhiteSpace([string]$config.DashboardUrl)) { [string]$config.DashboardUrl } else { "http://localhost:8888/" }
$LogRootPath = if ($config.PSObject.Properties.Name -contains "LogRootPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.LogRootPath)) { Resolve-AbsolutePath -Path ([string]$config.LogRootPath) -BaseDirectory $configBaseDirectory } else { Resolve-AbsolutePath -Path ".\Logs" -BaseDirectory $PSScriptRoot }
$LogFilePath = if ($config.PSObject.Properties.Name -contains "LogFilePath" -and -not [string]::IsNullOrWhiteSpace([string]$config.LogFilePath)) { Resolve-AbsolutePath -Path ([string]$config.LogFilePath) -BaseDirectory $configBaseDirectory } else { $null }

$MaxHistorySamples = if ($config.PSObject.Properties.Name -contains "MaxHistorySamples" -and $null -ne $config.MaxHistorySamples) { [int]$config.MaxHistorySamples } else { 365 }
$CriticalThresholdPercent = if ($config.PSObject.Properties.Name -contains "CriticalThresholdPercent" -and $null -ne $config.CriticalThresholdPercent) { [double]$config.CriticalThresholdPercent } else { 94.0 }
$WarningThresholdPercent = if ($config.PSObject.Properties.Name -contains "WarningThresholdPercent" -and $null -ne $config.WarningThresholdPercent) { [double]$config.WarningThresholdPercent } else { 85.0 }

$IncludeArchive = if ($config.PSObject.Properties.Name -contains "IncludeArchive") { [bool]$config.IncludeArchive } else { $false }
$IncludeSendAs = if ($config.PSObject.Properties.Name -contains "IncludeSendAs") { [bool]$config.IncludeSendAs } else { $false }
$IncludeFolderPermissions = if ($config.PSObject.Properties.Name -contains "IncludeFolderPermissions") { [bool]$config.IncludeFolderPermissions } else { $false }
$CollectorScheduleMinutes = if ($config.PSObject.Properties.Name -contains "CollectorScheduleMinutes" -and $null -ne $config.CollectorScheduleMinutes) { [int]$config.CollectorScheduleMinutes } else { 30 }
$WebRefreshSeconds = if ($config.PSObject.Properties.Name -contains "WebRefreshSeconds" -and $null -ne $config.WebRefreshSeconds) { [int]$config.WebRefreshSeconds } else { 60 }
$RegisterScheduledTask = if ($config.PSObject.Properties.Name -contains "RegisterScheduledTask") { [bool]$config.RegisterScheduledTask } else { $false }
$ScheduledTaskName = if ($config.PSObject.Properties.Name -contains "ScheduledTaskName" -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) { [string]$config.ScheduledTaskName } else { "Exchange Online Mailbox Dashboard Collector" }

$Organization = if ($PSBoundParameters.ContainsKey("Organization")) { $Organization } elseif ($config.PSObject.Properties.Name -contains "Organization") { [string]$config.Organization } else { $null }
$AppId = if ($PSBoundParameters.ContainsKey("AppId")) { $AppId } elseif ($config.PSObject.Properties.Name -contains "AppID") { [string]$config.AppID } elseif ($config.PSObject.Properties.Name -contains "AppId") { [string]$config.AppId } else { $null }
$CertificateThumbprint = if ($PSBoundParameters.ContainsKey("CertificateThumbprint")) { $CertificateThumbprint } elseif ($config.PSObject.Properties.Name -contains "Thumbprint") { [string]$config.Thumbprint } elseif ($config.PSObject.Properties.Name -contains "CertificateThumbprint") { [string]$config.CertificateThumbprint } else { $null }
$ClientSecret = if ($PSBoundParameters.ContainsKey("ClientSecret")) { $ClientSecret } elseif ($config.PSObject.Properties.Name -contains "ClientSecret") { [string]$config.ClientSecret } else { $null }

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
    if ($null -eq $SizeObject) { return [int64]0 }
    try {
        if ($SizeObject.PSObject.Properties.Name -contains "Value" -and $SizeObject.Value -and $SizeObject.Value.PSObject.Methods.Name -contains "ToBytes") {
            return [int64]$SizeObject.Value.ToBytes()
        }
    } catch {}
    $text = [string]$SizeObject
    # Canonical EXO string format: "4.993 GB (5,362,556,928 bytes)"
    if ($text -match "\(([\d,]+)\s+bytes\)") { return [int64]($matches[1] -replace ",", "") }
    # Unit-only fallback: "4.993 GB" (no bytes parenthetical)
    if ($text -match "([\d\.]+)\s*(KB|MB|GB|TB)") {
        $value = [double]$matches[1]
        switch ($matches[2]) {
            "KB" { return [int64]($value * 1KB) }
            "MB" { return [int64]($value * 1MB) }
            "GB" { return [int64]($value * 1GB) }
            "TB" { return [int64]($value * 1TB) }
        }
    }
    # Raw numeric fallback: EXO REST module may return bare byte counts as integers
    if ($text -match "^\d+$") { return [int64]$text }
    return [int64]0
}

function Convert-BytesToGB {
    param([int64]$Bytes)
    if ($Bytes -le 0) { return [double]0.0 }
    return [Math]::Round($Bytes / 1GB, 2)
}

function Convert-StringArray {
    param([Parameter()] $InputObject)
    if ($null -eq $InputObject) { return @() }

    return @(
        foreach ($item in @($InputObject)) {
            if ($null -eq $item) { continue }
            if ($item -is [string]) {
                $value = $item.Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) { $value }
                continue
            }
            if ($item.PSObject.Properties.Name -contains "Capability" -and $item.Capability) {
                [string]$item.Capability
                continue
            }
            [string]$item
        }
    )
}

function Try-ConvertToBoolean {
    param([Parameter()] $InputObject)
    if ($null -eq $InputObject) { return $null }
    try { return [bool]$InputObject } catch { return $null }
}

function Get-RecordValue {
    param(
        [Parameter(Mandatory)] [psobject]$Record,
        [Parameter(Mandatory)] [string[]]$PropertyNames
    )
    foreach ($propertyName in $PropertyNames) {
        if ($Record.PSObject.Properties.Name -contains $propertyName) {
            $value = $Record.$propertyName
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
        }
    }
    return $null
}

function Get-IsoUtcDateOrNull {
    param([Parameter()] $InputObject)
    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject)) { return $null }
    try { return ([datetimeoffset]::Parse([string]$InputObject)).ToUniversalTime().ToString("o") } catch { return $null }
}

function Get-RetentionPolicyCatalog {
    $retentionPolicyCommand = Get-Command -Name Get-RetentionPolicy -ErrorAction SilentlyContinue
    if ($null -eq $retentionPolicyCommand) {
        Write-Log -Tag "RETENTION" -Level "WARN" -Message "Get-RetentionPolicy cmdlet is unavailable. Retention policy catalog enrichment is disabled."
        return @{}
    }

    try {
        $policies = @(Get-RetentionPolicy -ErrorAction Stop)
    }
    catch {
        Write-Log -Tag "RETENTION" -Level "WARN" -Message "Failed to query retention policies: $($_.Exception.Message)"
        return @{}
    }

    $lookup = @{}
    foreach ($policy in $policies) {
        if ($null -eq $policy) { continue }

        $policyName = if ($policy.PSObject.Properties.Name -contains "Name") { [string]$policy.Name } else { [string]$policy.Identity }
        if ([string]::IsNullOrWhiteSpace($policyName)) { continue }

        $tagLinks = if ($policy.PSObject.Properties.Name -contains "RetentionPolicyTagLinks") {
            Convert-StringArray -InputObject $policy.RetentionPolicyTagLinks
        }
        else {
            @()
        }

        $lookup[$policyName.ToLowerInvariant()] = [pscustomobject]@{
            Name                    = $policyName
            IsKnownPolicy           = $true
            MailboxCount            = 0
            IsDefaultPolicy         = if ($policy.PSObject.Properties.Name -contains "IsDefault") { Try-ConvertToBoolean -InputObject $policy.IsDefault } else { $null }
            RetentionId             = if ($policy.PSObject.Properties.Name -contains "RetentionId") { [string]$policy.RetentionId } elseif ($policy.PSObject.Properties.Name -contains "Guid") { [string]$policy.Guid } else { $null }
            RetentionPolicyTagLinks = @($tagLinks)
            TagCount                = @($tagLinks).Count
            Comment                 = if ($policy.PSObject.Properties.Name -contains "Comment" -and -not [string]::IsNullOrWhiteSpace([string]$policy.Comment)) { [string]$policy.Comment } else { $null }
        }
    }

    return $lookup
}

function Get-LicenseAssessment {
    param(
        [Parameter()] [string]$RecipientTypeDetails,
        [Parameter()] [Nullable[bool]]$IsInactiveMailbox,
        [Parameter()] [Nullable[bool]]$SkuAssigned,
        [Parameter()] [string[]]$PersistedCapabilities
    )

    $normalizedRecipientType = [string]$RecipientTypeDetails
    $normalizedRecipientType = $normalizedRecipientType.ToLowerInvariant()
    $nonLicensedTypes = @(
        "sharedmailbox", "roommailbox", "equipmentmailbox", "discoverymailbox",
        "publicfoldermailbox", "groupmailbox", "schedulingmailbox", "teammailbox",
        "auditlogmailbox", "arbitrationmailbox"
    )

    $capabilities = @($PersistedCapabilities | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $hasLicense = ($SkuAssigned -eq $true) -or ($capabilities.Count -gt 0)

    $licenseRequired = $true
    $requirementReason = "Recipient type '$RecipientTypeDetails' is expected to require mailbox licensing."
    if ($IsInactiveMailbox -eq $true) {
        $licenseRequired = $false
        $requirementReason = "Inactive mailbox; licensing is generally not required."
    }
    elseif ($nonLicensedTypes -contains $normalizedRecipientType) {
        $licenseRequired = $false
        $requirementReason = "Recipient type '$RecipientTypeDetails' is typically unlicensed."
    }

    $licenseTypes = if ($capabilities.Count -gt 0) { $capabilities } elseif ($hasLicense) { @("SKUAssigned") } else { @() }

    return [pscustomobject]@{
        LicenseRequired          = $licenseRequired
        HasLicense               = $hasLicense
        LicenseTypes             = @($licenseTypes)
        LicenseType              = if ($licenseTypes.Count -gt 0) { [string]($licenseTypes -join ", ") } else { $null }
        IsLicenseCompliant       = (-not $licenseRequired) -or $hasLicense
        LicenseRequirementReason = $requirementReason
    }
}

function Get-RetentionPolicyNameFromMailboxRecord {
    param([Parameter(Mandatory)] [psobject]$MailboxRecord)
    if (-not ($MailboxRecord.PSObject.Properties.Name -contains "Retention") -or $null -eq $MailboxRecord.Retention) { return $null }
    $retention = $MailboxRecord.Retention
    if ($retention.PSObject.Properties.Name -contains "RetentionPolicy" -and -not [string]::IsNullOrWhiteSpace([string]$retention.RetentionPolicy)) {
        return [string]$retention.RetentionPolicy
    }
    return $null
}

function Build-RetentionPolicyCatalog {
    param(
        [Parameter(Mandatory)] [hashtable]$PolicyLookup,
        [Parameter(Mandatory)] [object[]]$MailboxRecords
    )

    $mailboxCountsByPolicy = @{}
    foreach ($mailboxRecord in @($MailboxRecords)) {
        if ($null -eq $mailboxRecord) { continue }
        $policyName = Get-RetentionPolicyNameFromMailboxRecord -MailboxRecord $mailboxRecord
        if ([string]::IsNullOrWhiteSpace($policyName)) { continue }
        $key = $policyName.ToLowerInvariant()
        if (-not $mailboxCountsByPolicy.ContainsKey($key)) {
            $mailboxCountsByPolicy[$key] = [pscustomobject]@{ Name = $policyName; Count = 0 }
        }
        $mailboxCountsByPolicy[$key].Count += 1
    }

    $catalogKeys = @($PolicyLookup.Keys + $mailboxCountsByPolicy.Keys | Sort-Object -Unique)
    $catalog = foreach ($catalogKey in $catalogKeys) {
        $mailboxCount = if ($mailboxCountsByPolicy.ContainsKey($catalogKey)) { [int]$mailboxCountsByPolicy[$catalogKey].Count } else { 0 }
        if ($PolicyLookup.ContainsKey($catalogKey)) {
            $policy = $PolicyLookup[$catalogKey]
            [pscustomobject]@{
                Name                    = [string]$policy.Name
                IsKnownPolicy           = [bool]$policy.IsKnownPolicy
                MailboxCount            = $mailboxCount
                IsDefaultPolicy         = $policy.IsDefaultPolicy
                RetentionId             = $policy.RetentionId
                RetentionPolicyTagLinks = @($policy.RetentionPolicyTagLinks)
                TagCount                = if ($null -ne $policy.TagCount) { [int]$policy.TagCount } else { 0 }
                Comment                 = $policy.Comment
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
                Comment                 = "Policy is assigned to one or more mailboxes but was not returned by Get-RetentionPolicy."
            }
        }
    }

    return @($catalog | Sort-Object -Property @{ Expression = { -1 * [int]$_.MailboxCount } }, @{ Expression = { [string]$_.Name } })
}

function Apply-RetentionPolicyDetailsToMailboxRecords {
    param(
        [Parameter(Mandatory)] [object[]]$MailboxRecords,
        [Parameter(Mandatory)] [object[]]$RetentionPolicies
    )

    $policyIndex = @{}
    foreach ($policy in @($RetentionPolicies)) {
        if ($null -eq $policy -or [string]::IsNullOrWhiteSpace([string]$policy.Name)) { continue }
        $policyIndex[[string]$policy.Name.ToLowerInvariant()] = $policy
    }

    foreach ($mailboxRecord in @($MailboxRecords)) {
        if ($null -eq $mailboxRecord -or -not ($mailboxRecord.PSObject.Properties.Name -contains "Retention") -or $null -eq $mailboxRecord.Retention) { continue }
        $policyName = Get-RetentionPolicyNameFromMailboxRecord -MailboxRecord $mailboxRecord
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            $mailboxRecord.Retention.RetentionPolicyDetails = $null
            continue
        }

        $lookupKey = $policyName.ToLowerInvariant()
        if (-not $policyIndex.ContainsKey($lookupKey)) {
            $mailboxRecord.Retention.RetentionPolicyDetails = [pscustomobject]@{
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

        $policy = $policyIndex[$lookupKey]
        $mailboxRecord.Retention.RetentionPolicyDetails = [pscustomobject]@{
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

function Get-LastSampleTimestampOrNow {
    param(
        [Parameter(Mandatory)] [psobject]$HistoryEntry,
        [Parameter(Mandatory)] [datetime]$SnapshotTimeUtc
    )

    $latestSample = $null
    if ($HistoryEntry.PSObject.Properties.Name -contains "Samples") {
        $samples = @($HistoryEntry.Samples)
        if ($samples.Count -gt 0) {
            $latestSample = $samples[-1]
        }
    }

    if ($null -ne $latestSample -and $latestSample.PSObject.Properties.Name -contains "TimestampUtc" -and -not [string]::IsNullOrWhiteSpace([string]$latestSample.TimestampUtc)) {
        return [string]$latestSample.TimestampUtc
    }

    return $SnapshotTimeUtc.ToString("o")
}

function Update-MailboxPolicyAndLicenseChangeHistory {
    param(
        [Parameter(Mandatory)] [psobject]$HistoryEntry,
        [Parameter(Mandatory)] [psobject]$CurrentRecord,
        [Parameter(Mandatory)] [datetime]$SnapshotTimeUtc
    )

    $eventTimestampUtc = $SnapshotTimeUtc.ToString("o")
    $baselineTimestampUtc = Get-LastSampleTimestampOrNow -HistoryEntry $HistoryEntry -SnapshotTimeUtc $SnapshotTimeUtc

    if (-not ($HistoryEntry.PSObject.Properties.Name -contains "RetentionPolicyChangeHistory") -or $null -eq $HistoryEntry.RetentionPolicyChangeHistory) {
        $HistoryEntry.RetentionPolicyChangeHistory = @()
    }
    if (-not ($HistoryEntry.PSObject.Properties.Name -contains "LicenseAssignmentHistory") -or $null -eq $HistoryEntry.LicenseAssignmentHistory) {
        $HistoryEntry.LicenseAssignmentHistory = @()
    }

    $retentionHistory = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($HistoryEntry.RetentionPolicyChangeHistory)) {
        if ($null -ne $item) { $retentionHistory.Add($item) }
    }

    $licenseHistory = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($HistoryEntry.LicenseAssignmentHistory)) {
        if ($null -ne $item) { $licenseHistory.Add($item) }
    }

    $currentRetentionPolicy = if ($CurrentRecord.Retention -and $CurrentRecord.Retention.PSObject.Properties.Name -contains "RetentionPolicy") { [string]$CurrentRecord.Retention.RetentionPolicy } else { $null }
    $currentLicenseType = if ($CurrentRecord.Licensing -and $CurrentRecord.Licensing.PSObject.Properties.Name -contains "LicenseType") { [string]$CurrentRecord.Licensing.LicenseType } else { $null }
    $currentHasLicense = if ($CurrentRecord.Licensing -and $CurrentRecord.Licensing.PSObject.Properties.Name -contains "HasLicense") { Try-ConvertToBoolean -InputObject $CurrentRecord.Licensing.HasLicense } else { $null }
    $currentLicenseRequired = if ($CurrentRecord.Licensing -and $CurrentRecord.Licensing.PSObject.Properties.Name -contains "LicenseRequired") { Try-ConvertToBoolean -InputObject $CurrentRecord.Licensing.LicenseRequired } else { $null }

    $previousRetentionPolicy = if ($HistoryEntry.Retention -and $HistoryEntry.Retention.PSObject.Properties.Name -contains "RetentionPolicy") { [string]$HistoryEntry.Retention.RetentionPolicy } else { $null }
    $previousLicenseType = if ($HistoryEntry.Licensing -and $HistoryEntry.Licensing.PSObject.Properties.Name -contains "LicenseType") { [string]$HistoryEntry.Licensing.LicenseType } else { $null }
    $previousHasLicense = if ($HistoryEntry.Licensing -and $HistoryEntry.Licensing.PSObject.Properties.Name -contains "HasLicense") { Try-ConvertToBoolean -InputObject $HistoryEntry.Licensing.HasLicense } else { $null }
    $previousLicenseRequired = if ($HistoryEntry.Licensing -and $HistoryEntry.Licensing.PSObject.Properties.Name -contains "LicenseRequired") { Try-ConvertToBoolean -InputObject $HistoryEntry.Licensing.LicenseRequired } else { $null }

    if ($retentionHistory.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($previousRetentionPolicy)) {
        $retentionHistory.Add([pscustomobject]@{
            TimestampUtc = $baselineTimestampUtc
            RetentionPolicy = $previousRetentionPolicy
        })
    }

    if ($retentionHistory.Count -eq 0 -or ([string]$retentionHistory[$retentionHistory.Count - 1].RetentionPolicy) -ne [string]$currentRetentionPolicy) {
        $retentionHistory.Add([pscustomobject]@{
            TimestampUtc = $eventTimestampUtc
            RetentionPolicy = $currentRetentionPolicy
        })
    }

    if ($licenseHistory.Count -eq 0 -and ($null -ne $previousHasLicense -or $null -ne $previousLicenseRequired -or -not [string]::IsNullOrWhiteSpace($previousLicenseType))) {
        $licenseHistory.Add([pscustomobject]@{
            TimestampUtc = $baselineTimestampUtc
            HasLicense = $previousHasLicense
            LicenseRequired = $previousLicenseRequired
            LicenseType = $previousLicenseType
        })
    }

    $appendLicenseEvent = $false
    if ($licenseHistory.Count -eq 0) {
        $appendLicenseEvent = $true
    }
    else {
        $lastLicense = $licenseHistory[$licenseHistory.Count - 1]
        $lastHasLicense = if ($lastLicense.PSObject.Properties.Name -contains "HasLicense") { Try-ConvertToBoolean -InputObject $lastLicense.HasLicense } else { $null }
        $lastLicenseRequired = if ($lastLicense.PSObject.Properties.Name -contains "LicenseRequired") { Try-ConvertToBoolean -InputObject $lastLicense.LicenseRequired } else { $null }
        $lastLicenseType = if ($lastLicense.PSObject.Properties.Name -contains "LicenseType") { [string]$lastLicense.LicenseType } else { $null }

        if ($lastHasLicense -ne $currentHasLicense -or $lastLicenseRequired -ne $currentLicenseRequired -or [string]$lastLicenseType -ne [string]$currentLicenseType) {
            $appendLicenseEvent = $true
        }
    }

    if ($appendLicenseEvent) {
        $licenseHistory.Add([pscustomobject]@{
            TimestampUtc = $eventTimestampUtc
            HasLicense = $currentHasLicense
            LicenseRequired = $currentLicenseRequired
            LicenseType = $currentLicenseType
        })
    }

    $HistoryEntry.RetentionPolicyChangeHistory = @($retentionHistory)
    $HistoryEntry.LicenseAssignmentHistory = @($licenseHistory)
    $CurrentRecord.RetentionPolicyChangeHistory = @($retentionHistory)
    $CurrentRecord.LicenseAssignmentHistory = @($licenseHistory)
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

function Get-HistoryLookup {
    param($HistoryData)

    $lookup = [pscustomobject]@{
        ByGuid  = @{}
        BySmtp  = @{}
        Entries = [System.Collections.Generic.List[object]]::new()
    }

    if ($null -eq $HistoryData -or $null -eq $HistoryData.MailboxHistory) {
        return $lookup
    }

    foreach ($entry in @($HistoryData.MailboxHistory)) {
        if ($null -eq $entry) {
            continue
        }

        $lookup.Entries.Add($entry)

        if (-not [string]::IsNullOrWhiteSpace([string]$entry.ExchangeGuid)) {
            $lookup.ByGuid[[string]$entry.ExchangeGuid] = $entry
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$entry.PrimarySmtpAddress)) {
            $lookup.BySmtp[([string]$entry.PrimarySmtpAddress).ToLowerInvariant()] = $entry
        }
    }

    return $lookup
}

function Get-HistoryEntry {
    param(
        [Parameter(Mandatory)] $HistoryLookup,
        [string]$ExchangeGuid,
        [string]$PrimarySmtpAddress
    )

    if (-not [string]::IsNullOrWhiteSpace($ExchangeGuid) -and $HistoryLookup.ByGuid.ContainsKey($ExchangeGuid)) {
        return $HistoryLookup.ByGuid[$ExchangeGuid]
    }

    $smtpKey = if ([string]::IsNullOrWhiteSpace($PrimarySmtpAddress)) { $null } else { $PrimarySmtpAddress.ToLowerInvariant() }
    if ($smtpKey -and $HistoryLookup.BySmtp.ContainsKey($smtpKey)) {
        return $HistoryLookup.BySmtp[$smtpKey]
    }

    return $null
}

function Connect-ToExchangeOnline {
    if ($Interactive) { Connect-ExchangeOnline -ShowBanner:$false; return }
    if ([string]::IsNullOrWhiteSpace($AppId) -or [string]::IsNullOrWhiteSpace($Organization) -or [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        throw "Unattended execution requires AppId, Organization, and CertificateThumbprint in the selected config file (or as overrides when using an alternate -ConfigPath)."
    }
    Connect-ExchangeOnline -AppId $AppId -Organization $Organization -CertificateThumbprint $CertificateThumbprint -ShowBanner:$false
}

function Show-DashboardRuntimeSummary {
    param($ConfigPath, $CsvPath, $OutputJsonPath, $HistoryJsonPath, $WebRootPath, $DashboardUrl, $Organization, $AppId, $CertificateThumbprint, $WarningThresholdPercent, $CriticalThresholdPercent, $WebRefreshSeconds, $CollectorScheduleMinutes, $ScheduledTaskName, [switch]$RegisterScheduledTask)
    $summary = @"

============================================================
 Exchange Online Mailbox Dashboard Collector Configuration
============================================================
Config file:                 $ConfigPath
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
    param(
        [Parameter(Mandatory)] [string]$Identity,
        [Parameter(Mandatory)] $HistoryLookup,
        [Parameter(Mandatory)] [datetime]$SnapshotTimeUtc,
        [Parameter(Mandatory)] [psobject]$MailboxRow,
        [Parameter(Mandatory)] [string]$RunCorrelationId
    )

    $mailbox = Get-EXOMailbox -Identity $Identity -Properties DisplayName,PrimarySmtpAddress,RecipientTypeDetails,ExchangeGuid,ArchiveGuid,ArchiveStatus,ProhibitSendQuota,ProhibitSendReceiveQuota,IssueWarningQuota,GrantSendOnBehalfTo,SKUAssigned,PersistedCapabilities,IsInactiveMailbox,RetentionPolicy,RetentionHoldEnabled,LitigationHoldEnabled,LitigationHoldDuration,InPlaceHolds,SingleItemRecoveryEnabled,RetainDeletedItemsFor
    $stats = Get-EXOMailboxStatistics -Identity $Identity
    $exchangeGuid = [string]$mailbox.ExchangeGuid
    $historyEntry = Get-HistoryEntry -HistoryLookup $HistoryLookup -ExchangeGuid $exchangeGuid -PrimarySmtpAddress ([string]$mailbox.PrimarySmtpAddress)
    $latestHistorySample = if ($null -ne $historyEntry -and @($historyEntry.Samples).Count -gt 0) { @($historyEntry.Samples)[-1] } else { $null }

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
    $archiveEnabled = ($null -ne $mailbox.ArchiveGuid -and $mailbox.ArchiveGuid -ne [Guid]::Empty) -or
        ($mailbox.ArchiveStatus -and $mailbox.ArchiveStatus -ne "None")

    $archiveSizeGB = if ($null -ne $latestHistorySample -and $latestHistorySample.PSObject.Properties.Name -contains "ArchiveSizeGB" -and $null -ne $latestHistorySample.ArchiveSizeGB) {
        [double]$latestHistorySample.ArchiveSizeGB
    }
    else {
        0.0
    }
    $archiveItemCount = if ($null -ne $latestHistorySample -and $latestHistorySample.PSObject.Properties.Name -contains "ArchiveItemCount" -and $null -ne $latestHistorySample.ArchiveItemCount) {
        [int64]$latestHistorySample.ArchiveItemCount
    }
    else {
        0
    }

    if (-not $archiveEnabled -and $null -ne $latestHistorySample -and $latestHistorySample.PSObject.Properties.Name -contains "ArchiveEnabled") {
        $archiveEnabled = [bool]$latestHistorySample.ArchiveEnabled
    }

    if ($IncludeArchive -and $archiveEnabled) {
        try {
            $archiveStats = Get-EXOMailboxStatistics -Identity $Identity -Archive
            $archiveBytes = Convert-ExoSizeToBytes -SizeObject $archiveStats.TotalItemSize
            $archiveSizeGB = Convert-BytesToGB -Bytes $archiveBytes
            $archiveItemCount = [int64]$archiveStats.ItemCount
        } catch { Write-Warning "Could not query archive statistics for $Identity. Preserving the most recent known archive values." }
    }

    $lastLogonTime = if ($stats.PSObject.Properties.Name -contains "LastLogonTime" -and $stats.LastLogonTime) {
        try { $stats.LastLogonTime.ToString("o") } catch { $null }
    }
    else {
        $null
    }

    $retentionProfile = [pscustomobject]@{
        RetentionPolicy = if ($mailbox.PSObject.Properties.Name -contains "RetentionPolicy") { [string]$mailbox.RetentionPolicy } else { $null }
        RetentionHoldEnabled = if ($mailbox.PSObject.Properties.Name -contains "RetentionHoldEnabled") { Try-ConvertToBoolean -InputObject $mailbox.RetentionHoldEnabled } else { $null }
        LitigationHoldEnabled = if ($mailbox.PSObject.Properties.Name -contains "LitigationHoldEnabled") { Try-ConvertToBoolean -InputObject $mailbox.LitigationHoldEnabled } else { $null }
        LitigationHoldDurationDays = if ($mailbox.PSObject.Properties.Name -contains "LitigationHoldDuration" -and $null -ne $mailbox.LitigationHoldDuration) { [int]$mailbox.LitigationHoldDuration } else { $null }
        InPlaceHolds = if ($mailbox.PSObject.Properties.Name -contains "InPlaceHolds") { Convert-StringArray -InputObject $mailbox.InPlaceHolds } else { @() }
        SingleItemRecoveryEnabled = if ($mailbox.PSObject.Properties.Name -contains "SingleItemRecoveryEnabled") { Try-ConvertToBoolean -InputObject $mailbox.SingleItemRecoveryEnabled } else { $null }
        RetainDeletedItemsFor = if ($mailbox.PSObject.Properties.Name -contains "RetainDeletedItemsFor" -and $null -ne $mailbox.RetainDeletedItemsFor) { [string]$mailbox.RetainDeletedItemsFor } else { $null }
    }

    $recipientTypeDetails = if ($mailbox.PSObject.Properties.Name -contains "RecipientTypeDetails") { [string]$mailbox.RecipientTypeDetails } else { "" }
    $skuAssigned = if ($mailbox.PSObject.Properties.Name -contains "SKUAssigned") { Try-ConvertToBoolean -InputObject $mailbox.SKUAssigned } else { $null }
    $persistedCapabilities = if ($mailbox.PSObject.Properties.Name -contains "PersistedCapabilities") { Convert-StringArray -InputObject $mailbox.PersistedCapabilities } else { @() }
    $isInactiveMailbox = if ($mailbox.PSObject.Properties.Name -contains "IsInactiveMailbox") { Try-ConvertToBoolean -InputObject $mailbox.IsInactiveMailbox } else { $null }
    $licenseAssessment = Get-LicenseAssessment -RecipientTypeDetails $recipientTypeDetails -IsInactiveMailbox $isInactiveMailbox -SkuAssigned $skuAssigned -PersistedCapabilities $persistedCapabilities

    $licensingProfile = [pscustomobject]@{
        RecipientTypeDetails = $recipientTypeDetails
        IsSharedMailbox = ($recipientTypeDetails -eq "SharedMailbox")
        SKUAssigned = $skuAssigned
        PersistedCapabilities = @($persistedCapabilities)
        ArchiveStatus = if ($mailbox.PSObject.Properties.Name -contains "ArchiveStatus") { [string]$mailbox.ArchiveStatus } else { $null }
        IsInactiveMailbox = $isInactiveMailbox
        LicenseRequired = $licenseAssessment.LicenseRequired
        HasLicense = $licenseAssessment.HasLicense
        LicenseTypes = @($licenseAssessment.LicenseTypes)
        LicenseType = $licenseAssessment.LicenseType
        IsLicenseCompliant = $licenseAssessment.IsLicenseCompliant
        LicenseRequirementReason = $licenseAssessment.LicenseRequirementReason
    }

    $cleanupAttemptUtc = Get-IsoUtcDateOrNull -InputObject (Get-RecordValue -Record $MailboxRow -PropertyNames @("LastCleanupAttemptUtc", "CleanupLastAttemptUtc"))
    $cleanupSuccessUtc = Get-IsoUtcDateOrNull -InputObject (Get-RecordValue -Record $MailboxRow -PropertyNames @("LastCleanupSuccessUtc", "CleanupLastSuccessUtc"))
    $cleanupStatus = Get-RecordValue -Record $MailboxRow -PropertyNames @("CleanupStatus", "MailboxCleanupStatus")
    $cleanupVersion = Get-RecordValue -Record $MailboxRow -PropertyNames @("CleanupVersion")
    $cleanupLastProcessedBy = Get-RecordValue -Record $MailboxRow -PropertyNames @("LastProcessedBy")
    $cleanupCorrelationId = Get-RecordValue -Record $MailboxRow -PropertyNames @("CleanupCorrelationId", "CorrelationId")
    $cleanupNotes = Get-RecordValue -Record $MailboxRow -PropertyNames @("CleanupNotes", "MaintenanceNotes")

    if ($null -eq $cleanupStatus) {
        $cleanupStatus = if ($cleanupSuccessUtc) { "Success" } else { "Unknown" }
    }

    $daysSinceSuccessfulCleanup = $null
    if ($cleanupSuccessUtc) {
        try {
            $daysSinceSuccessfulCleanup = [Math]::Floor(((Get-Date).ToUniversalTime() - ([datetimeoffset]::Parse($cleanupSuccessUtc)).UtcDateTime).TotalDays)
        }
        catch {
            $daysSinceSuccessfulCleanup = $null
        }
    }

    $mailboxMaintenance = [pscustomobject]@{
        LastCleanupAttemptUtc = $cleanupAttemptUtc
        LastCleanupSuccessUtc = $cleanupSuccessUtc
        CleanupStatus = [string]$cleanupStatus
        DaysSinceSuccessfulCleanup = $daysSinceSuccessfulCleanup
        CleanupVersion = if ($cleanupVersion) { [string]$cleanupVersion } else { $null }
        LastProcessedBy = if ($cleanupLastProcessedBy) { [string]$cleanupLastProcessedBy } else { "Update-MailboxDashboard" }
        CorrelationId = if ($cleanupCorrelationId) { [string]$cleanupCorrelationId } else { $RunCorrelationId }
        Notes = if ($cleanupNotes) { [string]$cleanupNotes } else { "No external cleanup telemetry was provided for this mailbox." }
    }

    $thresholdState = if ($usagePercent -ge $CriticalThresholdPercent) { "critical" } elseif ($usagePercent -ge $WarningThresholdPercent) { "warning" } else { "ok" }

    return [pscustomobject]@{
        Current = [pscustomobject]@{
            ExchangeGuid             = $exchangeGuid
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
            LastLogonTime            = $lastLogonTime
            ArchiveEnabled           = $archiveEnabled
            ArchiveSizeGB            = $archiveSizeGB
            ArchiveItemCount         = $archiveItemCount
            Archive                  = if ($archiveEnabled) {
                [pscustomobject]@{
                    TotalBytes = $null
                    TotalGB    = $archiveSizeGB
                    ItemCount  = $archiveItemCount
                }
            } else { $null }
            Permissions              = $permissions
            Retention                = $retentionProfile
            Licensing                = $licensingProfile
            MailboxMaintenance       = $mailboxMaintenance
            LastCleanupSuccessUtc    = $mailboxMaintenance.LastCleanupSuccessUtc
            CleanupStatus            = $mailboxMaintenance.CleanupStatus
            DaysSinceSuccessfulCleanup = $mailboxMaintenance.DaysSinceSuccessfulCleanup
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
            ArchiveEnabled  = $archiveEnabled
            ArchiveSizeGB   = $archiveSizeGB
            ArchiveItemCount = $archiveItemCount
            ThresholdState  = $thresholdState
            LastLogonTime   = $lastLogonTime
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
    param(
        [Parameter(Mandatory)] [string]$TaskName,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string]$ConfigPath,
        [int]$CollectorScheduleMinutes
    )
    
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        "-File `"$ScriptPath`"",
        "-ConfigPath `"$ConfigPath`""
    )

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
    Start-DashboardLogging -LogRootPath $LogRootPath -LogFilePath $LogFilePath
    Write-Log -Tag "START" -Message "Collector runtime execution initialized."

    $OverviewUrl   = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "index.html"
    $ThresholdsUrl = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "thresholds.html"
    $HistoryUrl    = Join-DashboardUrl -BaseUrl $DashboardUrl -Page "history.html"

    if ($UseFilePicker -or [string]::IsNullOrWhiteSpace($CsvPath)) {
        $CsvPath = Get-CsvFileFromPicker
    }
    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV target data mapping missing: $CsvPath" }

    Show-DashboardRuntimeSummary -ConfigPath $resolvedConfigPath -CsvPath $CsvPath -OutputJsonPath $OutputJsonPath -HistoryJsonPath $HistoryJsonPath -WebRootPath $WebRootPath -DashboardUrl $OverviewUrl -Organization $Organization -AppId $AppId -CertificateThumbprint $CertificateThumbprint -WarningThresholdPercent $WarningThresholdPercent -CriticalThresholdPercent $CriticalThresholdPercent -WebRefreshSeconds $WebRefreshSeconds -CollectorScheduleMinutes $CollectorScheduleMinutes -ScheduledTaskName $ScheduledTaskName -RegisterScheduledTask:$RegisterScheduledTask

    Write-Log -Tag "INPUT" -Message "Processing structural targets from matching CSV mappings."
    $mailboxRows = Import-Csv -LiteralPath $CsvPath
    if (-not $mailboxRows -or -not ($mailboxRows[0].PSObject.Properties.Name -contains "Mailbox")) {
        throw "CSV structure validation broken. Target header definition requires field attribute named 'Mailbox'."
    }

    Write-Log -Tag "EXO" -Message "Loading endpoint interaction module layers."
    Import-Module ExchangeOnlineManagement
    Connect-ToExchangeOnline
    Write-Log -Tag "EXO" -Level "SUCCESS" -Message "Remote endpoint synchronization pipeline connected."
    $retentionPolicyLookup = Get-RetentionPolicyCatalog
    Write-Log -Tag "RETENTION" -Message "Retention policy catalog entries discovered: $($retentionPolicyLookup.Count)"

    $snapshotTimeUtc = (Get-Date).ToUniversalTime()
    $runCorrelationId = [guid]::NewGuid().ToString()
    $existingHistoryData = Read-JsonFile -Path $HistoryJsonPath
    $historyLookup = Get-HistoryLookup -HistoryData $existingHistoryData

    $currentRecords = @()

    foreach ($row in $mailboxRows) {
        if ([string]::IsNullOrWhiteSpace($row.Mailbox)) { continue }
        $mailboxIdentity = $row.Mailbox.Trim()
        
        try {
            $result = Get-MailboxDashboardRecord -Identity $mailboxIdentity -HistoryLookup $historyLookup -SnapshotTimeUtc $snapshotTimeUtc -MailboxRow $row -RunCorrelationId $runCorrelationId
            $currentRecords += $result.Current

            $historyEntry = Get-HistoryEntry -HistoryLookup $historyLookup -ExchangeGuid ([string]$result.Current.ExchangeGuid) -PrimarySmtpAddress ([string]$result.Current.PrimarySmtpAddress)
            if ($null -ne $historyEntry) {
                $samples = @(
                    @($historyEntry.Samples) | ForEach-Object { $_ }
                    @($result.History) | ForEach-Object { $_ }
                ) | Select-Object -Last $MaxHistorySamples
                $historyEntry.ExchangeGuid = [string]$result.Current.ExchangeGuid
                $historyEntry.PrimarySmtpAddress = [string]$result.Current.PrimarySmtpAddress
                $historyEntry.DisplayName = [string]$result.Current.DisplayName
                $historyEntry.Permissions = @($result.Current.Permissions)
                Update-MailboxPolicyAndLicenseChangeHistory -HistoryEntry $historyEntry -CurrentRecord $result.Current -SnapshotTimeUtc $snapshotTimeUtc
                $historyEntry.Retention = $result.Current.Retention
                $historyEntry.Licensing = $result.Current.Licensing
                $historyEntry.MailboxMaintenance = $result.Current.MailboxMaintenance
                $historyEntry.LastCleanupSuccessUtc = $result.Current.LastCleanupSuccessUtc
                $historyEntry.CleanupStatus = $result.Current.CleanupStatus
                $historyEntry.DaysSinceSuccessfulCleanup = $result.Current.DaysSinceSuccessfulCleanup
                $historyEntry.Samples = $samples
            }
            else {
                $historyEntry = [pscustomobject]@{
                    ExchangeGuid       = [string]$result.Current.ExchangeGuid
                    PrimarySmtpAddress = [string]$result.Current.PrimarySmtpAddress
                    DisplayName        = [string]$result.Current.DisplayName
                    Permissions        = @($result.Current.Permissions)
                    Retention          = $result.Current.Retention
                    Licensing          = $result.Current.Licensing
                    MailboxMaintenance = $result.Current.MailboxMaintenance
                    LastCleanupSuccessUtc = $result.Current.LastCleanupSuccessUtc
                    CleanupStatus = $result.Current.CleanupStatus
                    DaysSinceSuccessfulCleanup = $result.Current.DaysSinceSuccessfulCleanup
                    Samples            = @($result.History)
                }
                Update-MailboxPolicyAndLicenseChangeHistory -HistoryEntry $historyEntry -CurrentRecord $result.Current -SnapshotTimeUtc $snapshotTimeUtc

                $historyLookup.Entries.Add($historyEntry)
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$historyEntry.ExchangeGuid)) {
                $historyLookup.ByGuid[[string]$historyEntry.ExchangeGuid] = $historyEntry
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$historyEntry.PrimarySmtpAddress)) {
                $historyLookup.BySmtp[([string]$historyEntry.PrimarySmtpAddress).ToLowerInvariant()] = $historyEntry
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

    $retentionPolicies = Build-RetentionPolicyCatalog -PolicyLookup $retentionPolicyLookup -MailboxRecords $currentRecords
    Apply-RetentionPolicyDetailsToMailboxRecords -MailboxRecords $currentRecords -RetentionPolicies $retentionPolicies
    Apply-RetentionPolicyDetailsToMailboxRecords -MailboxRecords @($historyLookup.Entries) -RetentionPolicies $retentionPolicies

    Show-CriticalThresholdReport -ThresholdMailboxes $thresholdMailboxes -CriticalThresholdPercent $CriticalThresholdPercent

    $currentDashboardData = [pscustomobject]@{
        '$schema'                = "./dashboard.schema.json"
        SchemaVersion            = "2026-08-14"
        GeneratedUtc             = $snapshotTimeUtc.ToString("o")
        SourceCsv                = $CsvPath
        WebRootPath              = $WebRootPath
        OutputJsonPath           = $OutputJsonPath
        MailboxCount             = $currentRecords.Count
        WarningThresholdPercent  = $WarningThresholdPercent
        CriticalThresholdPercent = $CriticalThresholdPercent
        ThresholdCount           = $thresholdMailboxes.Count
        RetentionPolicies        = @($retentionPolicies)
        Mailboxes                = $currentRecords
        ThresholdMailboxes       = $thresholdMailboxes
    }

    $historyOutput = [pscustomobject]@{
        '$schema'         = "./dashboard.schema.json"
        SchemaVersion     = "2026-08-14"
        RetentionPolicies = @($retentionPolicies)
        MailboxHistory    = @($historyLookup.Entries)
        GeneratedUtc      = $snapshotTimeUtc.ToString("o")
        MaxHistorySamples = $MaxHistorySamples
    }

    Write-Log -Tag "JSON" -Message "Writing current atomic metrics frame structure over to: $OutputJsonPath"
    Write-JsonFileAtomic -InputObject $currentDashboardData -Path $OutputJsonPath -Depth 12

    Write-Log -Tag "JSON" -Message "Appending timeline history payload map matrix into target: $HistoryJsonPath"
    Write-JsonFileAtomic -InputObject $historyOutput -Path $HistoryJsonPath -Depth 12

    if ($RegisterScheduledTask) {
        Register-MailboxDashboardScheduledTask -TaskName $ScheduledTaskName -ScriptPath $PSCommandPath -ConfigPath $resolvedConfigPath -CollectorScheduleMinutes $CollectorScheduleMinutes
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