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
    [string]$HotDataJsonPath,

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
        '$schema'      = "./dashboard.schema.json"
        SchemaVersion  = "2026-08-14"
        GeneratedUtc   = ""
        RetentionPolicies = @()
        MailboxHistory = @()
    }
}

function Convert-StringArray {
    param(
        [Parameter()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }

    return @(
        foreach ($item in @($InputObject)) {
            if ($null -eq $item) {
                continue
            }

            if ($item -is [string]) {
                $value = $item.Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $value
                }
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
    param(
        [Parameter()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    try {
        return [bool]$InputObject
    }
    catch {
        return $null
    }
}

function Get-RecordValue {
    param(
        [Parameter(Mandatory)]
        [psobject]$Record,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        if ($Record.PSObject.Properties.Name -contains $propertyName) {
            $value = $Record.$propertyName
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }

    return $null
}

function Get-IsoUtcDateOrNull {
    param(
        [Parameter()]
        $InputObject
    )

    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject)) {
        return $null
    }

    try {
        return ([datetimeoffset]::Parse([string]$InputObject)).ToUniversalTime().ToString("o")
    }
    catch {
        return $null
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

function Get-RetentionPolicyCatalog {
    $retentionPolicyCommand = Get-Command -Name Get-RetentionPolicy -ErrorAction SilentlyContinue
    if ($null -eq $retentionPolicyCommand) {
        Write-Warning "Get-RetentionPolicy cmdlet was not available. Retention policy catalog enrichment is disabled."
        return @{}
    }

    try {
        $policies = @(Get-RetentionPolicy -ErrorAction Stop)
    }
    catch {
        Write-Warning "Failed to query retention policies: $($_.Exception.Message)"
        return @{}
    }

    $catalogLookup = @{}
    foreach ($policy in $policies) {
        if ($null -eq $policy) {
            continue
        }

        $policyName = if ($policy.PSObject.Properties.Name -contains "Name") { [string]$policy.Name } else { [string]$policy.Identity }
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            continue
        }

        $tagLinks = if ($policy.PSObject.Properties.Name -contains "RetentionPolicyTagLinks") {
            Convert-StringArray -InputObject $policy.RetentionPolicyTagLinks
        }
        else {
            @()
        }

        $isDefaultPolicy = if ($policy.PSObject.Properties.Name -contains "IsDefault") {
            Try-ConvertToBoolean -InputObject $policy.IsDefault
        }
        else {
            $null
        }

        $catalogLookup[$policyName.ToLowerInvariant()] = [pscustomobject]@{
            Name                    = $policyName
            IsKnownPolicy           = $true
            MailboxCount            = 0
            IsDefaultPolicy         = $isDefaultPolicy
            RetentionId             = if ($policy.PSObject.Properties.Name -contains "RetentionId") { [string]$policy.RetentionId } elseif ($policy.PSObject.Properties.Name -contains "Guid") { [string]$policy.Guid } else { $null }
            RetentionPolicyTagLinks = @($tagLinks)
            TagCount                = @($tagLinks).Count
            Comment                 = if ($policy.PSObject.Properties.Name -contains "Comment" -and -not [string]::IsNullOrWhiteSpace([string]$policy.Comment)) { [string]$policy.Comment } else { $null }
        }
    }

    return $catalogLookup
}

function Build-RetentionPolicyCatalog {
    param(
        [Parameter(Mandatory)]
        [hashtable]$PolicyLookup,

        [Parameter(Mandatory)]
        [psobject[]]$MailboxHistory
    )

    $mailboxCountsByPolicy = @{}
    foreach ($entry in $MailboxHistory) {
        if ($null -eq $entry) {
            continue
        }

        $policyName = Get-RetentionPolicyNameForEntry -Entry $entry
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            continue
        }

        $countKey = $policyName.ToLowerInvariant()
        if (-not $mailboxCountsByPolicy.ContainsKey($countKey)) {
            $mailboxCountsByPolicy[$countKey] = [pscustomobject]@{
                Name  = $policyName
                Count = 0
            }
        }

        $mailboxCountsByPolicy[$countKey].Count += 1
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
            $discoveredName = [string]$mailboxCountsByPolicy[$catalogKey].Name
            [pscustomobject]@{
                Name                    = $discoveredName
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
        if ($null -eq $entry) {
            continue
        }

        if (-not ($entry.PSObject.Properties.Name -contains "Retention") -or $null -eq $entry.Retention) {
            continue
        }

        $policyName = Get-RetentionPolicyNameForEntry -Entry $entry
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            $entry.Retention.RetentionPolicyDetails = $null
            continue
        }

        $lookupKey = $policyName.ToLowerInvariant()
        if (-not $policyIndex.ContainsKey($lookupKey)) {
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

        $policy = $policyIndex[$lookupKey]
        $entry.Retention.RetentionPolicyDetails = [pscustomobject]@{
            Name            = [string]$policy.Name
            IsKnownPolicy   = [bool]$policy.IsKnownPolicy
            MailboxCount    = if ($null -ne $policy.MailboxCount) { [int]$policy.MailboxCount } else { 0 }
            IsDefaultPolicy = $policy.IsDefaultPolicy
            RetentionId     = $policy.RetentionId
            TagCount        = if ($null -ne $policy.TagCount) { [int]$policy.TagCount } else { 0 }
            Comment         = $policy.Comment
        }
    }
}

function Get-LicenseAssessment {
    param(
        [Parameter()]
        [string]$RecipientTypeDetails,

        [Parameter()]
        [Nullable[bool]]$IsInactiveMailbox,

        [Parameter()]
        [Nullable[bool]]$SkuAssigned,

        [Parameter()]
        [string[]]$PersistedCapabilities
    )

    $normalizedRecipientType = [string]$RecipientTypeDetails
    $normalizedRecipientType = $normalizedRecipientType.ToLowerInvariant()

    $nonLicensedTypes = @(
        "sharedmailbox",
        "roommailbox",
        "equipmentmailbox",
        "discoverymailbox",
        "publicfoldermailbox",
        "groupmailbox",
        "schedulingmailbox",
        "teammailbox",
        "auditlogmailbox",
        "arbitrationmailbox"
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
        LicenseRequired         = $licenseRequired
        HasLicense              = $hasLicense
        LicenseTypes            = @($licenseTypes)
        LicenseType             = if ($licenseTypes.Count -gt 0) { [string]($licenseTypes -join ", ") } else { $null }
        IsLicenseCompliant      = (-not $licenseRequired) -or $hasLicense
        LicenseRequirementReason = $requirementReason
    }
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

    $hotMailboxes = foreach ($entry in $MailboxHistory) {
        if ($null -eq $entry) {
            continue
        }

        $samples = @($entry.Samples)
        if ($samples.Count -eq 0) {
            continue
        }

        $latestSample = $samples[-1]
        $retention = if ($entry.PSObject.Properties.Name -contains "Retention") { $entry.Retention } else { $null }
        $licensing = if ($entry.PSObject.Properties.Name -contains "Licensing") { $entry.Licensing } else { $null }
        $mailboxMaintenance = if ($entry.PSObject.Properties.Name -contains "MailboxMaintenance") { $entry.MailboxMaintenance } else { $null }
        [pscustomobject]@{
            ExchangeGuid       = [string]$entry.ExchangeGuid
            PrimarySmtpAddress = [string]$entry.PrimarySmtpAddress
            DisplayName        = [string]$entry.DisplayName
            current            = [pscustomobject]@{
                totalGB          = [double]$latestSample.SizeGB
                itemCount        = [int64]$latestSample.ItemCount
                quotaGB          = if ($null -ne $latestSample.QuotaGB) { [double]$latestSample.QuotaGB } else { $null }
                usagePercent     = if ($null -ne $latestSample.UsagePercent) { [double]$latestSample.UsagePercent } else { $null }
                lastLogonTime    = $latestSample.LastLogonTime
                archiveEnabled   = [bool]$latestSample.ArchiveEnabled
                archiveSizeGB    = [double]$latestSample.ArchiveSizeGB
                archiveItemCount = [int64]$latestSample.ArchiveItemCount
            }
            retention          = if ($null -ne $retention) { $retention } else { $null }
            licensing          = if ($null -ne $licensing) { $licensing } else { $null }
            mailboxMaintenance = if ($null -ne $mailboxMaintenance) { $mailboxMaintenance } else { $null }
            lastCleanupSuccessUtc = if ($null -ne $mailboxMaintenance -and $mailboxMaintenance.PSObject.Properties.Name -contains "LastCleanupSuccessUtc") { $mailboxMaintenance.LastCleanupSuccessUtc } else { $null }
            cleanupStatus = if ($null -ne $mailboxMaintenance -and $mailboxMaintenance.PSObject.Properties.Name -contains "CleanupStatus") { $mailboxMaintenance.CleanupStatus } else { $null }
            daysSinceSuccessfulCleanup = if ($null -ne $mailboxMaintenance -and $mailboxMaintenance.PSObject.Properties.Name -contains "DaysSinceSuccessfulCleanup") { $mailboxMaintenance.DaysSinceSuccessfulCleanup } else { $null }
            permissions        = if ($entry.PSObject.Properties.Name -contains "Permissions") { @($entry.Permissions) } else { @() }
        }
    }

    return [pscustomobject]@{
        '$schema' = "./dashboard.schema.json"
        SchemaVersion = "2026-08-14"
        GeneratedUtc = $GeneratedUtc
        RetentionPolicies = @($RetentionPolicies)
        Mailboxes = @($hotMailboxes)
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
    # Canonical EXO string format: "4.993 GB (5,362,556,928 bytes)"
    if ($text -match "\(([\d,]+)\s+bytes\)") {
        $bytes = [int64]($matches[1] -replace ",", "")
        return [Math]::Round($bytes / 1GB, 2)
    }

    # Unit-only fallback: "4.993 GB" (no bytes parenthetical)
    if ($text -match "([\d\.]+)\s*(KB|MB|GB|TB)") {
        $value = [double]$matches[1]
        $bytes = switch ($matches[2]) {
            "KB" { [int64]($value * 1KB) }
            "MB" { [int64]($value * 1MB) }
            "GB" { [int64]($value * 1GB) }
            "TB" { [int64]($value * 1TB) }
        }
        return [Math]::Round($bytes / 1GB, 2)
    }

    # Raw numeric fallback: EXO REST module may return bare byte counts as integers
    if ($text -match "^\d+$") {
        return [Math]::Round([int64]$text / 1GB, 2)
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
$configuredHotDataJsonPath = if ($PSBoundParameters.ContainsKey("HotDataJsonPath")) {
    $HotDataJsonPath
}
elseif ($config.PSObject.Properties.Name -contains "HotDataJsonPath" -and -not [string]::IsNullOrWhiteSpace([string]$config.HotDataJsonPath)) {
    [string]$config.HotDataJsonPath
}
else {
    Join-Path -Path (Split-Path -Path $configuredHistoryJsonPath -Parent) -ChildPath "data.json"
}

$resolvedCsvPath = Resolve-AbsolutePath -Path $configuredCsvPath -BaseDirectory $configBaseDirectory
$resolvedHistoryJsonPath = Resolve-AbsolutePath -Path $configuredHistoryJsonPath -BaseDirectory $configBaseDirectory
$resolvedHotDataJsonPath = Resolve-AbsolutePath -Path $configuredHotDataJsonPath -BaseDirectory $configBaseDirectory

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

$retentionPolicyLookup = Get-RetentionPolicyCatalog
Write-Host "Retention policy catalog entries discovered: $($retentionPolicyLookup.Count)" -ForegroundColor DarkCyan

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
$runCorrelationId = [guid]::NewGuid().ToString()

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
            ExchangeGuid, ArchiveGuid, ArchiveStatus, ProhibitSendReceiveQuota, `
            RecipientTypeDetails, IsInactiveMailbox, SKUAssigned, PersistedCapabilities, `
            RetentionPolicy, RetentionHoldEnabled, LitigationHoldEnabled, LitigationHoldDuration, `
            InPlaceHolds, SingleItemRecoveryEnabled, RetainDeletedItemsFor -ErrorAction Stop

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

        $permissions = @(
            Get-EXOMailboxPermission -Identity $identity -ErrorAction Stop |
                Where-Object { $_.IsInherited -eq $false -and $_.User -notmatch "NT AUTHORITY\\SELF|S-1-5-" }
        )
        $permissions = Convert-PermissionSet -Permissions $permissions

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

        $retentionProfile = [pscustomobject]@{
            RetentionPolicy = if ($mailboxInfo.PSObject.Properties.Name -contains "RetentionPolicy") { [string]$mailboxInfo.RetentionPolicy } else { $null }
            RetentionHoldEnabled = if ($mailboxInfo.PSObject.Properties.Name -contains "RetentionHoldEnabled") { Try-ConvertToBoolean -InputObject $mailboxInfo.RetentionHoldEnabled } else { $null }
            LitigationHoldEnabled = if ($mailboxInfo.PSObject.Properties.Name -contains "LitigationHoldEnabled") { Try-ConvertToBoolean -InputObject $mailboxInfo.LitigationHoldEnabled } else { $null }
            LitigationHoldDurationDays = if ($mailboxInfo.PSObject.Properties.Name -contains "LitigationHoldDuration" -and $null -ne $mailboxInfo.LitigationHoldDuration) { [int]$mailboxInfo.LitigationHoldDuration } else { $null }
            InPlaceHolds = if ($mailboxInfo.PSObject.Properties.Name -contains "InPlaceHolds") { Convert-StringArray -InputObject $mailboxInfo.InPlaceHolds } else { @() }
            SingleItemRecoveryEnabled = if ($mailboxInfo.PSObject.Properties.Name -contains "SingleItemRecoveryEnabled") { Try-ConvertToBoolean -InputObject $mailboxInfo.SingleItemRecoveryEnabled } else { $null }
            RetainDeletedItemsFor = if ($mailboxInfo.PSObject.Properties.Name -contains "RetainDeletedItemsFor" -and $null -ne $mailboxInfo.RetainDeletedItemsFor) { [string]$mailboxInfo.RetainDeletedItemsFor } else { $null }
        }

        $recipientTypeDetails = if ($mailboxInfo.PSObject.Properties.Name -contains "RecipientTypeDetails") { [string]$mailboxInfo.RecipientTypeDetails } else { "" }
        $skuAssigned = if ($mailboxInfo.PSObject.Properties.Name -contains "SKUAssigned") { Try-ConvertToBoolean -InputObject $mailboxInfo.SKUAssigned } else { $null }
        $persistedCapabilities = if ($mailboxInfo.PSObject.Properties.Name -contains "PersistedCapabilities") { Convert-StringArray -InputObject $mailboxInfo.PersistedCapabilities } else { @() }
        $isInactiveMailbox = if ($mailboxInfo.PSObject.Properties.Name -contains "IsInactiveMailbox") { Try-ConvertToBoolean -InputObject $mailboxInfo.IsInactiveMailbox } else { $null }
        $licenseAssessment = Get-LicenseAssessment -RecipientTypeDetails $recipientTypeDetails -IsInactiveMailbox $isInactiveMailbox -SkuAssigned $skuAssigned -PersistedCapabilities $persistedCapabilities

        $licensingProfile = [pscustomobject]@{
            RecipientTypeDetails = $recipientTypeDetails
            IsSharedMailbox = ($recipientTypeDetails -eq "SharedMailbox")
            SKUAssigned = $skuAssigned
            PersistedCapabilities = @($persistedCapabilities)
            ArchiveStatus = if ($mailboxInfo.PSObject.Properties.Name -contains "ArchiveStatus") { [string]$mailboxInfo.ArchiveStatus } else { $null }
            IsInactiveMailbox = $isInactiveMailbox
            LicenseRequired = $licenseAssessment.LicenseRequired
            HasLicense = $licenseAssessment.HasLicense
            LicenseTypes = @($licenseAssessment.LicenseTypes)
            LicenseType = $licenseAssessment.LicenseType
            IsLicenseCompliant = $licenseAssessment.IsLicenseCompliant
            LicenseRequirementReason = $licenseAssessment.LicenseRequirementReason
        }

        $cleanupAttemptUtc = Get-IsoUtcDateOrNull -InputObject (Get-RecordValue -Record $mailbox -PropertyNames @("LastCleanupAttemptUtc", "CleanupLastAttemptUtc"))
        $cleanupSuccessUtc = Get-IsoUtcDateOrNull -InputObject (Get-RecordValue -Record $mailbox -PropertyNames @("LastCleanupSuccessUtc", "CleanupLastSuccessUtc"))
        $cleanupStatus = Get-RecordValue -Record $mailbox -PropertyNames @("CleanupStatus", "MailboxCleanupStatus")
        $cleanupVersion = Get-RecordValue -Record $mailbox -PropertyNames @("CleanupVersion")
        $cleanupLastProcessedBy = Get-RecordValue -Record $mailbox -PropertyNames @("LastProcessedBy")
        $cleanupCorrelationId = Get-RecordValue -Record $mailbox -PropertyNames @("CleanupCorrelationId", "CorrelationId")
        $cleanupNotes = Get-RecordValue -Record $mailbox -PropertyNames @("CleanupNotes", "MaintenanceNotes")

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
            LastProcessedBy = if ($cleanupLastProcessedBy) { [string]$cleanupLastProcessedBy } else { "MailboxDashboardCollector" }
            CorrelationId = if ($cleanupCorrelationId) { [string]$cleanupCorrelationId } else { $runCorrelationId }
            Notes = if ($cleanupNotes) { [string]$cleanupNotes } else { "No external cleanup telemetry was provided for this mailbox." }
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
            $existingEntry.Permissions = @($permissions)
            $existingEntry.Retention = $retentionProfile
            $existingEntry.Licensing = $licensingProfile
            $existingEntry.MailboxMaintenance = $mailboxMaintenance
            $existingEntry.LastCleanupSuccessUtc = $mailboxMaintenance.LastCleanupSuccessUtc
            $existingEntry.CleanupStatus = $mailboxMaintenance.CleanupStatus
            $existingEntry.DaysSinceSuccessfulCleanup = $mailboxMaintenance.DaysSinceSuccessfulCleanup
            $existingEntry.Samples = @($sampleList)
        }
        else {
            $newEntry = [pscustomobject]@{
                ExchangeGuid       = $exchangeGuid
                PrimarySmtpAddress = [string]$mailboxInfo.PrimarySmtpAddress
                DisplayName        = [string]$mailboxInfo.DisplayName
                Permissions        = @($permissions)
                Retention          = $retentionProfile
                Licensing          = $licensingProfile
                MailboxMaintenance = $mailboxMaintenance
                LastCleanupSuccessUtc = $mailboxMaintenance.LastCleanupSuccessUtc
                CleanupStatus = $mailboxMaintenance.CleanupStatus
                DaysSinceSuccessfulCleanup = $mailboxMaintenance.DaysSinceSuccessfulCleanup
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
        $retentionPolicies = Build-RetentionPolicyCatalog -PolicyLookup $retentionPolicyLookup -MailboxHistory @($updatedMailboxHistory)
        Apply-RetentionPolicyDetailsToMailboxHistory -MailboxHistory @($updatedMailboxHistory) -RetentionPolicies $retentionPolicies
        $batchOutput = [pscustomobject]@{
            '$schema'      = "./dashboard.schema.json"
            SchemaVersion  = "2026-08-14"
            GeneratedUtc   = $timestampUtcValue
            RetentionPolicies = @($retentionPolicies)
            MailboxHistory = @($updatedMailboxHistory)
        }
        $hotDataOutput = Convert-HistoryToHotData -MailboxHistory @($updatedMailboxHistory) -GeneratedUtc $timestampUtcValue -RetentionPolicies @($retentionPolicies)

        Write-Host " [BATCH COMMIT] Committing progress to disk ($counter/$($mailboxes.Count))..." -ForegroundColor Yellow
        Write-JsonSafe -InputObject $batchOutput -Path $resolvedHistoryJsonPath -Depth 100
        Write-JsonSafe -InputObject $hotDataOutput -Path $resolvedHotDataJsonPath -Depth 100
    }
}

Write-Host "`n[SUCCESS] Collection completed cleanly at $timestampUtcValue.`n" -ForegroundColor Green
