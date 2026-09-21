<#
.SYNOPSIS
    Loads and validates the unified MailboxDashboard configuration.
.DESCRIPTION
    Reads dashboardConfig.json, applies defaults for anything omitted, resolves every
    configured relative path against the collector root, and validates the settings that
    the selected authentication mode requires.
#>

Set-StrictMode -Version Latest

$script:CommonModulePath = Join-Path -Path $PSScriptRoot -ChildPath "MailboxDashboard.Common.psm1"

# No -Force here: it would unload the copy the calling script already imported.
Import-Module -Name $script:CommonModulePath -DisableNameChecking

$script:ValidAuthModes = @('Certificate', 'Interactive', 'Delegated', 'Auto')

$script:PlaceholderPattern = '^(x{4,}|<.*>|your-.*|change-?me|TODO|placeholder)$'

function Get-DefaultConfig {
    return [ordered]@{
        Version           = "2.0"
        Organization      = ""
        AppID             = ""
        ClientSecret      = ""
        Thumbprint        = ""
        UserPrincipalName = ""

        Authentication = [ordered]@{
            Mode = "Auto"
        }

        Paths = [ordered]@{
            MailboxesCsv        = "..\Mailboxes\mailboxes.csv"
            HistoryJson         = "..\Web\history.json"
            DataJson            = "..\Web\data.json"
            DemoDataJson        = "..\Web\demo-data.json"
            DemoHistoryJson     = "..\Web\demo-history.json"
            TempDirectory       = ".\Temp"
            ThreadJobsDirectory = ".\Temp\ThreadJobs"
            LogDirectory        = ".\Logs"
        }

        Collection = [ordered]@{
            BatchSize         = 50
            MaxHistorySamples = 365
            UseThreading      = $true
            ThreadCount       = 10
        }

        Thresholds = [ordered]@{
            CriticalPercent = 94.0
            WarningPercent  = 85.0
        }

        Validation = [ordered]@{
            PreValidateCsv     = $true
            PostValidateJson   = $true
            AutoRepairErrors   = $false
            CullInvalidRecords = $true
        }

        Logging = [ordered]@{
            Enabled          = $true
            LogFile          = ".\Logs\failures.log"
            ExportAuditFile  = ".\Logs\exports.log"
            IncludeVariables = $true
        }

        Console = [ordered]@{
            ShowProgress = $true
            UseColour    = $true
            ShowPerItem  = $true
            ItemInterval = 25
        }
    }
}

function Test-ConfigPlaceholder {
<#
.SYNOPSIS
    Returns true when a configured value is empty or still a template placeholder.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }

    return ($Value.Trim() -match $script:PlaceholderPattern)
}

function Merge-ConfigSection {
<#
.SYNOPSIS
    Overlays user-supplied values onto a defaults hashtable, keeping unknown keys.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Default,

        [Parameter()]
        $Supplied
    )

    $merged = [ordered]@{}

    foreach ($key in $Default.Keys) {
        $merged[$key] = $Default[$key]
    }

    if ($null -ne $Supplied) {
        foreach ($property in $Supplied.PSObject.Properties) {
            $merged[$property.Name] = $property.Value
        }
    }

    return [pscustomobject]$merged
}

function Import-MailboxDashboardConfig {
<#
.SYNOPSIS
    Loads dashboardConfig.json and returns a fully resolved configuration object.
.PARAMETER ConfigPath
    Path to the configuration file. Defaults to Config\dashboardConfig.json under the
    collector root.
.PARAMETER AuthenticationMode
    Overrides the configured authentication mode for this run.
.PARAMETER SkipValidation
    Loads and resolves the configuration without enforcing authentication requirements.
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [ValidateSet('Certificate', 'Interactive', 'Delegated', 'Auto')]
        [string]$AuthenticationMode,

        [Parameter()]
        [switch]$SkipValidation
    )

    $collectorRoot = Split-Path -Path $PSScriptRoot -Parent

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path -Path $collectorRoot -ChildPath "Config\dashboardConfig.json"
    }

    $resolvedConfigPath = Resolve-MailboxPath -Path $ConfigPath -BaseDirectory $collectorRoot

    if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
        throw "Configuration file not found at '$resolvedConfigPath'. Run Initialize-MailboxDashboard.ps1 to create one."
    }

    $raw = Get-Content -LiteralPath $resolvedConfigPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Configuration file '$resolvedConfigPath' is empty."
    }

    try {
        $supplied = $raw | ConvertFrom-Json
    }
    catch {
        throw "Configuration file '$resolvedConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    $defaults = Get-DefaultConfig

    $config = [ordered]@{
        ConfigPath        = $resolvedConfigPath
        CollectorRoot     = $collectorRoot
        Version           = Get-SuppliedValue -Supplied $supplied -Name 'Version' -Default $defaults.Version
        Organization      = Get-SuppliedValue -Supplied $supplied -Name 'Organization' -Default ""
        AppID             = Get-SuppliedValue -Supplied $supplied -Name 'AppID' -Default ""
        ClientSecret      = Get-SuppliedValue -Supplied $supplied -Name 'ClientSecret' -Default ""
        Thumbprint        = Get-SuppliedValue -Supplied $supplied -Name 'Thumbprint' -Default ""
        UserPrincipalName = Get-SuppliedValue -Supplied $supplied -Name 'UserPrincipalName' -Default ""
    }

    $config.Authentication = Merge-ConfigSection -Default $defaults.Authentication -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Authentication')
    $config.Paths = Merge-ConfigSection -Default $defaults.Paths -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Paths')
    $config.Collection = Merge-ConfigSection -Default $defaults.Collection -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Collection')
    $config.Thresholds = Merge-ConfigSection -Default $defaults.Thresholds -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Thresholds')
    $config.Validation = Merge-ConfigSection -Default $defaults.Validation -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Validation')
    $config.Logging = Merge-ConfigSection -Default $defaults.Logging -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Logging')
    $config.Console = Merge-ConfigSection -Default $defaults.Console -Supplied (Get-SuppliedSection -Supplied $supplied -Name 'Console')

    # v1 configs kept paths at the root; carry them over so existing installs keep working.
    $config.Paths = Convert-LegacyPath -Supplied $supplied -Paths $config.Paths

    if ($PSBoundParameters.ContainsKey('AuthenticationMode')) {
        $config.Authentication.Mode = $AuthenticationMode
    }

    if ($script:ValidAuthModes -notcontains $config.Authentication.Mode) {
        throw "Authentication.Mode '$($config.Authentication.Mode)' is not valid. Use one of: $($script:ValidAuthModes -join ', ')."
    }

    $config.ResolvedPaths = Resolve-ConfigPath -Paths $config.Paths -BaseDirectory $collectorRoot

    Add-ResolvedLogPath -Logging $config.Logging -BaseDirectory $collectorRoot

    $configObject = [pscustomobject]$config

    Initialize-MailboxDashboardConsole -ConsoleConfig $configObject.Console -LoggingConfig $configObject.Logging

    if (-not $SkipValidation) {
        Test-MailboxDashboardConfig -Config $configObject
    }

    return $configObject
}

function Get-SuppliedValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Supplied,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        $Default
    )

    if ($null -ne $Supplied -and ($Supplied.PSObject.Properties.Name -contains $Name)) {
        return $Supplied.$Name
    }

    return $Default
}

function Get-SuppliedSection {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Supplied,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -ne $Supplied -and ($Supplied.PSObject.Properties.Name -contains $Name)) {
        return $Supplied.$Name
    }

    return $null
}

function Convert-LegacyPath {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Supplied,

        [Parameter(Mandatory)]
        $Paths
    )

    $legacyMap = @{
        MailboxesCsvPath = 'MailboxesCsv'
        CsvPath          = 'MailboxesCsv'
        HistoryJsonPath  = 'HistoryJson'
        HotDataJsonPath  = 'DataJson'
    }

    foreach ($legacyName in $legacyMap.Keys) {
        if ($null -eq $Supplied -or ($Supplied.PSObject.Properties.Name -notcontains $legacyName)) {
            continue
        }

        $legacyValue = $Supplied.$legacyName
        if ([string]::IsNullOrWhiteSpace([string]$legacyValue)) {
            continue
        }

        $targetName = $legacyMap[$legacyName]

        # An explicit Paths entry always wins over the legacy root-level key.
        if ($null -ne $Supplied.Paths -and ($Supplied.Paths.PSObject.Properties.Name -contains $targetName)) {
            continue
        }

        $Paths.$targetName = $legacyValue
    }

    return $Paths
}

function Resolve-ConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Paths,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    $resolved = [ordered]@{}

    foreach ($property in $Paths.PSObject.Properties) {
        $value = [string]$property.Value

        if ([string]::IsNullOrWhiteSpace($value)) {
            $resolved[$property.Name] = $null
            continue
        }

        $resolved[$property.Name] = Resolve-MailboxPath -Path $value -BaseDirectory $BaseDirectory
    }

    return [pscustomobject]$resolved
}

function Add-ResolvedLogPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Logging,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    $failurePath = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Logging.LogFile)) {
        $failurePath = Resolve-MailboxPath -Path ([string]$Logging.LogFile) -BaseDirectory $BaseDirectory
    }

    $exportPath = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Logging.ExportAuditFile)) {
        $exportPath = Resolve-MailboxPath -Path ([string]$Logging.ExportAuditFile) -BaseDirectory $BaseDirectory
    }

    Add-Member -InputObject $Logging -NotePropertyName 'ResolvedFailureLogPath' -NotePropertyValue $failurePath -Force
    Add-Member -InputObject $Logging -NotePropertyName 'ResolvedExportAuditPath' -NotePropertyValue $exportPath -Force
}

function Test-MailboxDashboardConfig {
<#
.SYNOPSIS
    Validates that the configuration can support the selected authentication mode.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if (Test-ConfigPlaceholder -Value $Config.Organization) {
        $problems.Add("'Organization' is not set. Provide the tenant ID or primary domain.")
    }

    if (Test-ConfigPlaceholder -Value $Config.AppID) {
        $problems.Add("'AppID' is not set. Run Register-EntraApp.ps1 to create an app registration.")
    }

    switch ($Config.Authentication.Mode) {
        'Certificate' {
            if ((Test-ConfigPlaceholder -Value $Config.ClientSecret) -and (Test-ConfigPlaceholder -Value $Config.Thumbprint)) {
                $problems.Add("Certificate authentication requires either 'ClientSecret' or 'Thumbprint'.")
            }
        }
        'Delegated' {
            if (Test-ConfigPlaceholder -Value $Config.UserPrincipalName) {
                $problems.Add("Delegated authentication requires 'UserPrincipalName'.")
            }
        }
    }

    foreach ($pathName in @('MailboxesCsv', 'HistoryJson', 'DataJson')) {
        $resolvedPath = $Config.ResolvedPaths.PSObject.Properties[$pathName]?.Value

        if ([string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
            $problems.Add("Paths.$pathName is required.")
            continue
        }

        if ($pathName -eq 'MailboxesCsv' -and -not (Test-Path -LiteralPath $resolvedPath)) {
            $problems.Add("Mailbox CSV path '$resolvedPath' does not exist.")
            continue
        }

        $parentDirectory = Split-Path -Path $resolvedPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parentDirectory) -and -not (Test-Path -LiteralPath $parentDirectory)) {
            $problems.Add("Paths.$pathName parent directory '$parentDirectory' does not exist.")
        }
    }

    foreach ($pathName in @('TempDirectory', 'ThreadJobsDirectory', 'LogDirectory')) {
        $resolvedPath = $Config.ResolvedPaths.PSObject.Properties[$pathName]?.Value
        if ([string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            $problems.Add("Paths.$pathName directory '$resolvedPath' does not exist.")
        }
    }

    $criticalPercent = [double]$Config.Thresholds.CriticalPercent
    $warningPercent = [double]$Config.Thresholds.WarningPercent

    if ($criticalPercent -le 0 -or $criticalPercent -gt 100) {
        $problems.Add("Thresholds.CriticalPercent must be between 0 and 100.")
    }

    if ($warningPercent -le 0 -or $warningPercent -gt 100) {
        $problems.Add("Thresholds.WarningPercent must be between 0 and 100.")
    }

    if ($warningPercent -ge $criticalPercent) {
        $problems.Add("Thresholds.WarningPercent must be lower than Thresholds.CriticalPercent.")
    }

    if ([int]$Config.Collection.BatchSize -lt 1) {
        $problems.Add("Collection.BatchSize must be at least 1.")
    }

    if ([int]$Config.Collection.ThreadCount -lt 1) {
        $problems.Add("Collection.ThreadCount must be at least 1.")
    }

    if ($problems.Count -gt 0) {
        $detail = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "Configuration '$($Config.ConfigPath)' is not usable:$([Environment]::NewLine)$detail"
    }
}

function Get-MailboxDashboardConfigPath {
<#
.SYNOPSIS
    Returns a resolved path from the loaded configuration by name.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Config.ResolvedPaths.PSObject.Properties.Name -notcontains $Name) {
        throw "No path named '$Name' is defined in the configuration."
    }

    $value = $Config.ResolvedPaths.$Name

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Path '$Name' is empty in '$($Config.ConfigPath)'."
    }

    return $value
}

Export-ModuleMember -Function @(
    'Import-MailboxDashboardConfig'
    'Test-MailboxDashboardConfig'
    'Get-MailboxDashboardConfigPath'
    'Test-ConfigPlaceholder'
)
