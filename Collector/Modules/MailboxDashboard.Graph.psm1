Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MailboxDashboard.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MailboxDashboard.Config.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MailboxDashboard.Operations.psm1') -DisableNameChecking

function Get-GraphField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Connect-GraphMailboxApp {
    param($Config)
    # Operations keeps its Graph authentication helper private.
    $operations = Get-Module -Name MailboxDashboard.Operations
    & $operations { param($Settings) Connect-MailboxDashboardGraph -Config $Settings } $Config
}

function ConvertTo-GraphGuid {
    param($Value, [string]$Field)
    $guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$guid) -or $guid -eq [guid]::Empty) {
        throw "$Field must contain a nonempty GUID."
    }
    return $guid.ToString('D')
}

function ConvertTo-GraphReportDate {
    param($Value, [string]$Field)
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$Value, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw "Graph report $Field must be an ISO date (yyyy-MM-dd)."
    }
    return [datetime]::SpecifyKind($date, [DateTimeKind]::Utc)
}

function ConvertTo-GraphReportInteger {
    param($Value, [string]$Field)
    $number = [int64]0
    if (-not [int64]::TryParse([string]$Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0) {
        throw "Graph report $Field must contain a nonnegative Int64."
    }
    return $number
}

function Import-GraphMailboxMapping {
    param([string]$Path)
    $rows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    if ($rows.Count -eq 0) { throw 'Graph mailbox mapping must not be empty.' }
    $ids = @{}
    $guids = @{}
    foreach ($row in $rows) {
        $id = ConvertTo-GraphGuid (Get-GraphField $row 'GraphUserId') 'GraphUserId'
        $guid = ConvertTo-GraphGuid (Get-GraphField $row 'ExchangeGuid') 'ExchangeGuid'
        if ($ids.ContainsKey($id)) { throw "Duplicate GraphUserId in Graph mailbox mapping: $id" }
        if ($guids.ContainsKey($guid)) { throw "Duplicate ExchangeGuid in Graph mailbox mapping: $guid" }
        $ids[$id] = $true
        $guids[$guid] = $true
        [pscustomobject]@{ GraphUserId = $id; ExchangeGuid = $guid }
    }
}

function ConvertTo-GraphHistoryNumber {
    param($Value, [string]$Field, [double]$Minimum = 0)
    $number = 0.0
    if ($null -eq $Value -or -not [double]::TryParse(
            [System.Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture),
            [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum) {
        throw "Existing sample $Field must contain a finite number greater than or equal to $Minimum."
    }
    return $number
}

function Test-GraphHistoryLatestSample {
    param($Sample)
    $quota = Get-GraphField $Sample 'QuotaGB'
    if ($null -ne $quota) {
        $quotaNumber = ConvertTo-GraphHistoryNumber $quota 'QuotaGB' ([double]::Epsilon)
        $sizeNumber = ConvertTo-GraphHistoryNumber (Get-GraphField $Sample 'SizeGB') 'SizeGB'
        $usage = ($sizeNumber / $quotaNumber) * 100
        if ([double]::IsNaN($usage) -or [double]::IsInfinity($usage)) {
            throw 'Existing sample calculated quota usage is outside the supported numeric range.'
        }
    }
    $availability = Get-GraphField $Sample 'DataAvailability'
    $isGraph = (Get-GraphField $availability 'Source') -eq 'MicrosoftGraph'
    $unavailable = Get-GraphField $availability 'UnavailableFields'
    foreach ($name in @('ArchiveEnabled', 'ArchiveSizeGB', 'ArchiveItemCount')) {
        $value = Get-GraphField $Sample $name
        if ($null -eq $value) {
            if (-not $isGraph -or $unavailable -notcontains $name) {
                throw "Existing sample $name is missing without Graph unavailable-field metadata."
            }
            continue
        }
        if ($name -eq 'ArchiveEnabled') {
            $boolean = $false
            if ($value -isnot [bool] -and -not [bool]::TryParse([string]$value, [ref]$boolean)) {
                throw 'Existing sample ArchiveEnabled must be a boolean.'
            }
        }
        elseif ($name -eq 'ArchiveItemCount') {
            $null = ConvertTo-GraphReportInteger $value 'existing sample ArchiveItemCount'
        }
        else { $null = ConvertTo-GraphHistoryNumber $value $name }
    }
}

function Read-GraphMailboxHistory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ GeneratedUtc = $null; MailboxHistory = @() }
    }
    # Read-MailboxJson enumerates root arrays; check the raw root before using it.
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw) -or -not $raw.TrimStart().StartsWith('{')) {
        throw 'Existing history must be a JSON object; refusing to recreate it.'
    }
    $document = Read-MailboxJson -Path $Path -ErrorAction Stop
    $entries = Get-GraphField $document 'MailboxHistory'
    if ($null -eq $document -or $entries -isnot [array]) {
        throw 'Existing history must contain a MailboxHistory array.'
    }
    $guids = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) { throw 'Invalid existing mailbox record.' }
        if ([string]::IsNullOrWhiteSpace([string](Get-GraphField $entry 'PrimarySmtpAddress'))) {
            throw 'Existing mailbox record PrimarySmtpAddress must not be empty.'
        }
        $guid = ConvertTo-GraphGuid (Get-GraphField $entry 'ExchangeGuid') 'Existing ExchangeGuid'
        if ($guids.ContainsKey($guid)) { throw "Duplicate ExchangeGuid in existing history: $guid" }
        $guids[$guid] = $true
        $samples = Get-GraphField $entry 'Samples'
        if ($samples -isnot [array] -or $samples.Count -eq 0) {
            throw "Existing Samples must be a nonempty array for $guid."
        }
        $timestamps = @{}
        foreach ($sample in $samples) {
            if ($null -eq $sample -or $sample -isnot [pscustomobject]) { throw "Invalid existing sample for $guid." }
            $sizeValue = Get-GraphField $sample 'SizeGB'
            $size = 0.0
            if ($null -eq $sizeValue -or -not [double]::TryParse(
                    [string]([System.Convert]::ToString($sizeValue, [Globalization.CultureInfo]::InvariantCulture)),
                    [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$size) -or
                [double]::IsNaN($size) -or [double]::IsInfinity($size) -or $size -lt 0) {
                throw "Invalid existing sample SizeGB for $guid."
            }
            $null = ConvertTo-GraphReportInteger (Get-GraphField $sample 'ItemCount') 'existing sample ItemCount'
            $timestamp = [string](Get-GraphField $sample 'TimestampUtc')
            $parsed = [datetimeoffset]::MinValue
            if ([string]::IsNullOrWhiteSpace($timestamp) -or
                -not [datetimeoffset]::TryParse($timestamp, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
                throw "Invalid existing sample TimestampUtc for $guid."
            }
            $key = $parsed.UtcDateTime.Ticks.ToString()
            if ($timestamps.ContainsKey($key)) { throw "Duplicate existing sample timestamp for $guid." }
            $timestamps[$key] = $true
        }
        $latest = @($samples | Sort-Object { ([datetimeoffset]$_.TimestampUtc).UtcDateTime })[-1]
        Test-GraphHistoryLatestSample -Sample $latest
    }
    return $document
}

function Invoke-GraphMailboxRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [string]$OutputFilePath)
    $parsedUri = [uri]$Uri
    if (-not $parsedUri.IsAbsoluteUri -or $parsedUri.Scheme -ne 'https' -or
        $parsedUri.Host -ne 'graph.microsoft.com' -or $parsedUri.Port -ne 443 -or
        $parsedUri.UserInfo -or -not $parsedUri.AbsolutePath.StartsWith('/v1.0/', [StringComparison]::Ordinal)) {
        throw 'Graph requests and pagination must use HTTPS graph.microsoft.com/v1.0.'
    }
    $arguments = @{ Method = 'GET'; Uri = $Uri; ErrorAction = 'Stop' }
    if ($OutputFilePath) { $arguments.OutputFilePath = $OutputFilePath }
    else { $arguments.OutputType = 'PSObject' }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { return Invoke-MgGraphRequest @arguments }
        catch {
            $exception = $_.Exception
            $response = Get-GraphField $exception 'Response'
            $status = Get-GraphField $exception 'ResponseStatusCode'
            if ($null -eq $status) { $status = Get-GraphField $response 'StatusCode' }
            if ($null -eq $status) { $status = Get-GraphField $exception 'StatusCode' }
            if ($null -eq $status -or [int]$status -notin @(429, 503, 504) -or $attempt -eq 4) { throw }
            $delay = [math]::Pow(2, $attempt + 1)
            $headers = Get-GraphField $exception 'ResponseHeaders'
            if ($null -eq $headers) { $headers = Get-GraphField $response 'Headers' }
            $retryAfter = Get-GraphField $headers 'Retry-After'
            if ($null -eq $retryAfter) { $retryAfter = Get-GraphField $headers 'RetryAfter' }
            if ($null -ne $retryAfter) {
                $delta = Get-GraphField $retryAfter 'Delta'
                $date = Get-GraphField $retryAfter 'Date'
                $seconds = 0.0
                if ($null -ne $delta) { $delay = $delta.TotalSeconds }
                elseif ($null -ne $date) { $delay = ([datetimeoffset]$date - [datetimeoffset]::UtcNow).TotalSeconds }
                elseif ([double]::TryParse([string](@($retryAfter)[0]),
                        [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
                    $delay = $seconds
                }
                else {
                    $retryDate = [datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse([string](@($retryAfter)[0]), [ref]$retryDate)) {
                        $delay = ($retryDate - [datetimeoffset]::UtcNow).TotalSeconds
                    }
                }
            }
            Start-Sleep -Seconds ([int][math]::Min(60, [math]::Max(1, [math]::Ceiling($delay))))
        }
    }
}

function Get-GraphMailboxUsers {
    $uri = 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,mail,proxyAddresses,assignedLicenses,assignedPlans&$top=999'
    $visited = @{}
    $ids = @{}
    do {
        if ($visited.ContainsKey($uri)) { throw 'Graph directory pagination contains a cycle.' }
        $visited[$uri] = $true
        $page = Invoke-GraphMailboxRequest -Uri $uri
        $users = Get-GraphField $page 'value'
        if ($users -isnot [array]) { throw 'Graph directory response must contain a value array.' }
        foreach ($user in $users) {
            $id = ConvertTo-GraphGuid (Get-GraphField $user 'id') 'Graph directory id'
            if ($ids.ContainsKey($id)) { throw "Duplicate Graph directory id: $id" }
            $ids[$id] = $true
            $user
        }
        $uri = [string](Get-GraphField $page '@odata.nextLink')
    } while (-not [string]::IsNullOrWhiteSpace($uri))
}

function Get-GraphMailboxAddress {
    param($User)
    $primary = @((Get-GraphField $User 'proxyAddresses') | Where-Object { [string]$_ -cmatch '^SMTP:' })
    if ($primary.Count -gt 1) { throw 'Graph user has multiple primary SMTP addresses.' }
    $address = if ($primary.Count -eq 1) { ([string]$primary[0]).Substring(5) } else { [string](Get-GraphField $User 'mail') }
    if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw 'Graph user has no valid primary SMTP address or mail fallback.' }
    return $address
}

function Get-GraphMailboxPurpose {
    param([string]$GraphUserId)
    $id = ConvertTo-GraphGuid $GraphUserId 'Graph mailbox settings user id'
    $response = Invoke-GraphMailboxRequest -Uri "https://graph.microsoft.com/v1.0/users/$id/mailboxSettings/userPurpose"
    $purpose = Get-GraphField $response 'value'
    if ($purpose -isnot [string] -or [string]::IsNullOrWhiteSpace($purpose)) {
        throw 'Graph mailbox userPurpose response must contain a nonempty string value.'
    }
    return $purpose
}

function ConvertFrom-GraphMailboxReport {
    param([object[]]$Rows)
    if ($Rows.Count -eq 0) { throw 'Graph mailbox usage report is empty.' }
    $result = @{}
    $refreshDate = $null
    foreach ($row in $Rows) {
        $deleted = $false
        if (-not [bool]::TryParse([string](Get-GraphField $row 'Is Deleted'), [ref]$deleted)) {
            throw 'Graph report Is Deleted must contain true or false.'
        }
        if ($deleted) { continue }
        $upn = [string](Get-GraphField $row 'User Principal Name')
        if ($upn -notmatch '^[^@\s]+@[^@\s]+$') {
            throw 'Graph report identities are missing or concealed. Disable concealed report names before collection.'
        }
        if ($result.ContainsKey($upn)) { throw "Duplicate Graph report identity: $upn" }
        $date = ConvertTo-GraphReportDate (Get-GraphField $row 'Report Refresh Date') 'Report Refresh Date'
        if ($null -ne $refreshDate -and $date -ne $refreshDate) { throw 'Graph report contains inconsistent refresh dates.' }
        $refreshDate = $date
        $result[$upn] = $row
    }
    if ($result.Count -eq 0) { throw 'Graph report has no active mailbox rows.' }
    return [pscustomobject]@{ Rows = $result; RefreshDate = $refreshDate }
}

function New-GraphMailboxRecord {
    param($Mapping, $User, $Row, [datetime]$RefreshDate, [string]$GraphUserPurpose)
    $purposeTypes = @{
        user = 'UserMailbox'; linked = 'LinkedMailbox'; shared = 'SharedMailbox'
        room = 'RoomMailbox'; equipment = 'EquipmentMailbox'
    }
    $recipientType = $purposeTypes[$GraphUserPurpose]
    $storage = ConvertTo-GraphReportInteger (Get-GraphField $Row 'Storage Used (Byte)') 'Storage Used (Byte)'
    $items = ConvertTo-GraphReportInteger (Get-GraphField $Row 'Item Count') 'Item Count'
    $quota = ConvertTo-GraphReportInteger (Get-GraphField $Row 'Prohibit Send/Receive Quota (Byte)') 'Prohibit Send/Receive Quota (Byte)'
    $archive = $null
    $archiveText = [string](Get-GraphField $Row 'Has Archive')
    if (-not [string]::IsNullOrWhiteSpace($archiveText)) {
        $archiveValue = $false
        if (-not [bool]::TryParse($archiveText, [ref]$archiveValue)) { throw 'Graph report Has Archive must contain true or false.' }
        $archive = $archiveValue
    }
    $activity = $null
    $activityText = [string](Get-GraphField $Row 'Last Activity Date')
    if (-not [string]::IsNullOrWhiteSpace($activityText)) {
        $activity = (ConvertTo-GraphReportDate $activityText 'Last Activity Date').ToString('yyyy-MM-dd')
    }
    $plans = Get-GraphField $User 'assignedPlans'
    $licenses = Get-GraphField $User 'assignedLicenses'
    if ($plans -isnot [array] -or $licenses -isnot [array]) { throw 'Graph user must contain assignedPlans and assignedLicenses arrays.' }
    $hasLicense = $false
    foreach ($plan in $plans) {
        $service = [string](Get-GraphField $plan 'service')
        $status = [string](Get-GraphField $plan 'capabilityStatus')
        if ([string]::IsNullOrWhiteSpace($service) -or
            $status -notin @('Enabled', 'Warning', 'Suspended', 'Deleted', 'LockedOut')) {
            throw 'Graph assignedPlan is missing service or a valid capabilityStatus.'
        }
        if ($service -eq 'exchange' -and $status -eq 'Enabled') { $hasLicense = $true }
    }
    $licenseTypes = @(foreach ($license in $licenses) {
        ConvertTo-GraphGuid (Get-GraphField $license 'skuId') 'Graph assignedLicense skuId'
    })
    $licensing = [pscustomobject]@{
        HasLicense = $hasLicense; LicenseTypes = $licenseTypes; LicenseType = $null
        LicenseRequired = $null; IsLicenseCompliant = $null; RecipientTypeDetails = $recipientType
        LicenseRequirementReason = $null
    }
    $availability = [pscustomobject]@{
        Source = 'MicrosoftGraph'
        ReportRefreshDate = $RefreshDate.ToString('yyyy-MM-dd')
        UnavailableFields = @('ArchiveSizeGB', 'ArchiveItemCount', 'PermissionCount', 'Permissions',
            'LastLogonTime', 'Retention', 'LicenseRequired', 'IsLicenseCompliant')
    }
    if ($null -eq $recipientType) { $availability.UnavailableFields += 'RecipientTypeDetails' }
    if ($null -eq $archive) { $availability.UnavailableFields += 'ArchiveEnabled' }
    $sample = [pscustomobject]@{
        TimestampUtc = $RefreshDate.ToString('o')
        SizeGB = [math]::Round($storage / 1GB, 4)
        ItemCount = $items
        QuotaGB = $(if ($quota -gt 0) { [double]$quota / 1GB } else { $null })
        UsagePercent = $(if ($quota -gt 0) { [math]::Round(([double]$storage / $quota) * 100, 2) } else { $null })
        ArchiveEnabled = $archive; ArchiveSizeGB = $null; ArchiveItemCount = $null
        LastActivityDate = $activity; LastLogonTime = $null
        PermissionCount = $null; Permissions = $null; Retention = $null
        RecipientTypeDetails = $recipientType; GraphUserPurpose = $GraphUserPurpose
        LicenseRequired = $null; IsLicenseCompliant = $null
        Licensing = $licensing; DataAvailability = $availability
    }
    return [pscustomobject]@{
        ExchangeGuid = $Mapping.ExchangeGuid; GraphUserId = $Mapping.GraphUserId
        PrimarySmtpAddress = Get-GraphMailboxAddress $User
        DisplayName = [string](Get-GraphField $User 'displayName')
        Licensing = $licensing; Permissions = $null; Retention = $null
        RecipientTypeDetails = $recipientType; GraphUserPurpose = $GraphUserPurpose
        DataAvailability = $availability; Samples = @($sample)
    }
}

function Invoke-MailboxDashboardGraphCollection {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$HistoryJsonPath,
        [string]$MappingCsvPath,
        [string[]]$Identity,
        [switch]$Connect
    )
    if ([string]::IsNullOrWhiteSpace($HistoryJsonPath)) { $HistoryJsonPath = [string](Get-GraphField $Config.ResolvedPaths 'HistoryJson') }
    if ([string]::IsNullOrWhiteSpace($MappingCsvPath)) { $MappingCsvPath = [string](Get-GraphField $Config.ResolvedPaths 'GraphMailboxMappingCsv') }
    if ([string]::IsNullOrWhiteSpace($HistoryJsonPath) -or [string]::IsNullOrWhiteSpace($MappingCsvPath)) {
        throw 'Graph collection requires HistoryJson and GraphMailboxMappingCsv paths.'
    }
    $historyPath = Resolve-MailboxPath -Path $HistoryJsonPath -BaseDirectory $PWD.Path
    $mappingPath = Resolve-MailboxPath -Path $MappingCsvPath -BaseDirectory $PWD.Path
    if (-not $PSCmdlet.ShouldProcess($historyPath, 'Collect Graph mailbox report and atomically update history')) {
        return [pscustomobject]@{ Collected = 0; Failed = 0; Skipped = 0; TimestampUtc = $null; OutputPath = $historyPath }
    }
    $mappings = @(Import-GraphMailboxMapping -Path $mappingPath)
    $history = Read-GraphMailboxHistory -Path $historyPath
    $maxSamples = [int]$Config.Collection.MaxHistorySamples
    if ($maxSamples -lt 1) { throw 'Collection.MaxHistorySamples must be positive.' }
    if ($Connect) {
        if ((Test-ConfigPlaceholder $Config.Organization) -or (Test-ConfigPlaceholder $Config.AppID) -or
            ((Test-ConfigPlaceholder $Config.Thumbprint) -and (Test-ConfigPlaceholder $Config.ClientSecret))) {
            throw 'Graph app-only authentication requires real Organization, AppID, and a certificate thumbprint or client secret.'
        }
        $null = ConvertTo-GraphGuid $Config.AppID 'AppID'
        $tenantGuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$Config.Organization, [ref]$tenantGuid) -and
            [string]$Config.Organization -notmatch '^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$') {
            throw 'Graph Organization must be a tenant GUID or verified tenant domain.'
        }
        if ($tenantGuid -eq [guid]::Empty -and [string]$Config.Organization -eq [guid]::Empty.ToString()) {
            throw 'Graph Organization must not be an empty tenant GUID.'
        }
        if (-not (Test-ConfigPlaceholder $Config.Thumbprint) -and [string]$Config.Thumbprint -notmatch '^[a-f0-9]{40}$') {
            throw 'Graph certificate thumbprint must contain 40 hexadecimal characters.'
        }
        $null = Connect-GraphMailboxApp -Config $Config
    }
    else {
        if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        }
        if ($null -eq (Get-MgContext -ErrorAction Stop)) { throw 'Microsoft Graph is not connected. Use -Connect or establish a Graph context.' }
    }
    Write-Notice 'Graph-only collection uses delayed mailbox usage reports and limited mailbox-purpose types. Archive sizes, permissions, logon, retention, and license requirements are unavailable.'
    $usersById = @{}
    foreach ($user in @(Get-GraphMailboxUsers)) {
        $usersById[(ConvertTo-GraphGuid (Get-GraphField $user 'id') 'Graph directory id')] = $user
    }
    $selected = [System.Collections.Generic.List[object]]::new()
    $matched = @{}
    $filters = @()
    if ($null -ne $Identity) { $filters = @($Identity) }
    foreach ($mapping in $mappings) {
        $user = $usersById[$mapping.GraphUserId]
        $include = $null -eq $Identity -or $Identity.Count -eq 0
        foreach ($filter in $filters) {
            if ([string]::IsNullOrWhiteSpace($filter)) { throw 'Graph Identity filters must not be empty.' }
            $addresses = @((Get-GraphField $user 'proxyAddresses') | ForEach-Object { ([string]$_) -replace '^(?i)smtp:', '' })
            if ($filter -eq $mapping.GraphUserId -or $filter -eq $mapping.ExchangeGuid -or
                $filter -eq (Get-GraphField $user 'userPrincipalName') -or
                $filter -eq (Get-GraphField $user 'mail') -or $addresses -contains $filter) {
                $include = $true
                $matched[$filter] = $true
            }
        }
        if (-not $include) { continue }
        if ($null -eq $user) { throw "Mapped Graph user is missing from directory: $($mapping.GraphUserId)" }
        $selected.Add([pscustomobject]@{ Mapping = $mapping; User = $user })
    }
    foreach ($filter in $filters) {
        if (-not $matched.ContainsKey($filter)) { throw "Graph Identity does not match a mapped directory user: $filter" }
    }
    $downloadPath = Join-Path (Split-Path $historyPath -Parent) ("graph-mailbox-usage." + [guid]::NewGuid().ToString('N') + '.csv')
    try {
        Confirm-ParentDirectory -Path $downloadPath
        # The authenticated SDK handles the preauthenticated report download redirect.
        $null = Invoke-GraphMailboxRequest -Uri "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D7')" -OutputFilePath $downloadPath
        $report = ConvertFrom-GraphMailboxReport -Rows @(Import-Csv -LiteralPath $downloadPath -ErrorAction Stop)
        $fresh = @(foreach ($selection in $selected) {
            $upn = [string](Get-GraphField $selection.User 'userPrincipalName')
            if (-not $report.Rows.ContainsKey($upn)) {
                throw 'Selected mapped user has no Graph report row. Check report delay and concealed-name settings.'
            }
            $purpose = Get-GraphMailboxPurpose -GraphUserId $selection.Mapping.GraphUserId
            New-GraphMailboxRecord -Mapping $selection.Mapping -User $selection.User -Row $report.Rows[$upn] -RefreshDate $report.RefreshDate -GraphUserPurpose $purpose
        })
        $entries = [System.Collections.Generic.List[object]]::new()
        $index = @{}
        foreach ($entry in $history.MailboxHistory) {
            $entries.Add($entry)
            $index[(ConvertTo-GraphGuid $entry.ExchangeGuid 'Existing ExchangeGuid')] = $entry
        }
        $collected = 0
        $skipped = 0
        foreach ($record in $fresh) {
            $sample = $record.Samples[0]
            if ($index.ContainsKey($record.ExchangeGuid)) {
                $entry = $index[$record.ExchangeGuid]
                $collision = @($entry.Samples | Where-Object {
                    ([datetimeoffset]$_.TimestampUtc).UtcDateTime -eq $report.RefreshDate -and
                    (Get-GraphField (Get-GraphField $_ 'DataAvailability') 'Source') -ne 'MicrosoftGraph'
                })
                if ($collision.Count -gt 0) {
                    Write-Notice "Graph sample skipped for $($record.ExchangeGuid): report timestamp collides with an existing non-Graph sample."
                    $skipped++
                    continue
                }
                $samples = @($entry.Samples | Where-Object {
                    ([datetimeoffset]$_.TimestampUtc).UtcDateTime -ne $report.RefreshDate
                }) + @($sample)
            }
            else {
                $entry = $record
                $samples = @($sample)
                $entries.Add($entry)
            }
            $entry.Samples = @($samples | Sort-Object { ([datetimeoffset]$_.TimestampUtc).UtcDateTime } | Select-Object -Last $maxSamples)
            $latest = $entry.Samples[-1]
            if (([datetimeoffset]$latest.TimestampUtc).UtcDateTime -eq $report.RefreshDate) {
                foreach ($name in @('GraphUserId', 'PrimarySmtpAddress', 'DisplayName', 'Licensing',
                        'Permissions', 'Retention', 'RecipientTypeDetails', 'GraphUserPurpose', 'DataAvailability')) {
                    Add-Member -InputObject $entry -NotePropertyName $name -NotePropertyValue $record.$name -Force
                }
            }
            $collected++
        }
        $generated = [datetime]::UtcNow.ToString('o')
        $document = [pscustomobject]@{ GeneratedUtc = $generated; MailboxHistory = @($entries.ToArray()) }
        if ($collected -gt 0) {
            Write-MailboxJson -InputObject $document -Path $historyPath -Source 'MicrosoftGraph mailbox usage D7 + directory + mailbox purpose; explicit ExchangeGuid mapping' -RecordCount $entries.Count -Depth 100 -Confirm:$false
        }
        return [pscustomobject]@{
            Collected = $collected; Failed = 0; Skipped = $skipped
            TimestampUtc = $report.RefreshDate.ToString('o'); OutputPath = $historyPath
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction Stop }
    }
}

Export-ModuleMember -Function Invoke-MailboxDashboardGraphCollection
