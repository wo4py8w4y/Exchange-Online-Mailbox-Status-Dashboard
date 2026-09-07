<#
.SYNOPSIS
    Connects the collector to Exchange Online using a selected authentication mode.
.DESCRIPTION
    Presents an authentication menu when Authentication.Mode is 'Auto', otherwise uses
    the configured mode directly. Supports certificate/app-only, interactive OAuth with
    PKCE via graph.auth.lite, and delegated sign-in.

    Dot-source this script to use Connect-MailboxDashboard from another script, or run it
    directly to establish a connection in the current session.
.EXAMPLE
    . .\Invoke-MailboxDashboardAuth.ps1
    Connect-MailboxDashboard -Config $config
.EXAMPLE
    .\Invoke-MailboxDashboardAuth.ps1 -AuthenticationMode Interactive
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('Certificate', 'Interactive', 'Delegated', 'Auto')]
    [string]$AuthenticationMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AuthModuleRoot = $PSScriptRoot
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

function Import-ExchangeModule {
<#
.SYNOPSIS
    Imports the Graph and Exchange modules in the order that avoids assembly conflicts.
.DESCRIPTION
    Microsoft.Graph.Authentication must load before ExchangeOnlineManagement; loading them
    the other way round produces Microsoft.Identity assembly version conflicts.
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeGraph
    )

    if ($IncludeGraph) {
        if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
                throw "Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
            }
            Import-Module -Name Microsoft.Graph.Authentication -ErrorAction Stop
        }
    }

    if (-not (Get-Module -Name ExchangeOnlineManagement)) {
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
            throw "ExchangeOnlineManagement is not installed. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser"
        }
        Import-Module -Name ExchangeOnlineManagement -ErrorAction Stop
    }
}

function Show-AuthenticationMenu {
<#
.SYNOPSIS
    Prompts the operator to choose an authentication mode.
.OUTPUTS
    The selected mode name, or $null if the operator quit.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $certificateReady = -not ((Test-ConfigPlaceholder -Value $Config.ClientSecret) -and (Test-ConfigPlaceholder -Value $Config.Thumbprint))
    $delegatedReady = -not (Test-ConfigPlaceholder -Value $Config.UserPrincipalName)

    while ($true) {
        Write-ConsoleLine ""
        Write-ConsoleLine -Message "  +------------------------------------+" -Colour Magenta
        Write-ConsoleLine -Message "  |  MailboxDashboard Authentication   |" -Colour Magenta
        Write-ConsoleLine -Message "  +------------------------------------+" -Colour Magenta
        Write-ConsoleLine -Message "  |  1) Certificate (app-only)         |" -Colour $(if ($certificateReady) { 'Magenta' } else { 'DarkGray' })
        Write-ConsoleLine -Message "  |  2) Interactive (OAuth / PKCE)     |" -Colour Magenta
        Write-ConsoleLine -Message "  |  3) Delegated (user sign-in)       |" -Colour $(if ($delegatedReady) { 'Magenta' } else { 'DarkGray' })
        Write-ConsoleLine -Message "  |  Q) Quit                           |" -Colour Magenta
        Write-ConsoleLine -Message "  +------------------------------------+" -Colour Magenta

        if (-not $certificateReady) {
            Write-Detail "Option 1 needs ClientSecret or Thumbprint in the configuration."
        }
        if (-not $delegatedReady) {
            Write-Detail "Option 3 needs UserPrincipalName in the configuration."
        }

        $choice = (Read-Host "  Select authentication mode").Trim()

        switch ($choice) {
            '1' {
                if (-not $certificateReady) {
                    Write-Notice "Certificate authentication is not configured."
                    continue
                }
                return 'Certificate'
            }
            '2' { return 'Interactive' }
            '3' {
                if (-not $delegatedReady) {
                    Write-Notice "Delegated authentication is not configured."
                    continue
                }
                return 'Delegated'
            }
            { $_ -in @('Q', 'q') } { return $null }
            default { Write-Notice "Enter 1, 2, 3, or Q." }
        }
    }
}

function Connect-CertificateAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    Import-ExchangeModule

    if (-not (Test-ConfigPlaceholder -Value $Config.Thumbprint)) {
        Write-Detail "Using certificate thumbprint $($Config.Thumbprint)"
        Connect-ExchangeOnline `
            -AppId $Config.AppID `
            -Organization $Config.Organization `
            -CertificateThumbprint $Config.Thumbprint `
            -ShowBanner:$false `
            -ErrorAction Stop
        return
    }

    Write-Detail "Using client secret for app-only access"
    $secureSecret = ConvertTo-SecureString -String ([string]$Config.ClientSecret) -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new($Config.AppID, $secureSecret)

    Connect-ExchangeOnline `
        -Organization $Config.Organization `
        -Credential $credential `
        -ShowBanner:$false `
        -ErrorAction Stop
}

function Connect-InteractiveAuth {
<#
.SYNOPSIS
    Signs in interactively with graph.auth.lite and attaches the token to Graph.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    if (-not (Get-Command -Name Get-GraphToken -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name graph.auth.lite)) {
            throw "Interactive sign-in requires the 'graph.auth.lite' module. Run: Install-Module graph.auth.lite -Scope CurrentUser"
        }
        Import-Module -Name graph.auth.lite -ErrorAction Stop
    }

    Import-ExchangeModule -IncludeGraph

    Write-Attention "A sign-in window is opening - it may appear behind this terminal."

    $graphToken = Get-GraphToken `
        -tenantId $Config.Organization `
        -clientId $Config.AppID `
        -scopes "User.Read.All offline_access openid profile" `
        -redirectUri "https://login.microsoftonline.com/common/oauth2/nativeclient"

    if ($null -eq $graphToken -or [string]::IsNullOrWhiteSpace([string]$graphToken.access_token)) {
        throw "Interactive sign-in did not return an access token."
    }

    $secureToken = ConvertTo-SecureString -String ([string]$graphToken.access_token) -AsPlainText -Force
    Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop

    Connect-ExchangeOnline `
        -UserPrincipalName $Config.UserPrincipalName `
        -ShowBanner:$false `
        -ErrorAction Stop
}

function Connect-DelegatedAuth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    Import-ExchangeModule

    Write-Attention "A sign-in window is opening for $($Config.UserPrincipalName) - it may appear behind this terminal."

    Connect-ExchangeOnline `
        -UserPrincipalName $Config.UserPrincipalName `
        -ShowBanner:$false `
        -ErrorAction Stop
}

function Connect-MailboxDashboard {
<#
.SYNOPSIS
    Establishes an Exchange Online connection using the configured or selected mode.
.OUTPUTS
    An object describing the connection: Mode, Organization, Account, ConnectedUtc.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config,

        [Parameter()]
        [ValidateSet('Certificate', 'Interactive', 'Delegated', 'Auto')]
        [string]$Mode
    )

    Write-Stage "Authenticating"

    $selectedMode = if ($PSBoundParameters.ContainsKey('Mode')) { $Mode } else { [string]$Config.Authentication.Mode }

    if ($selectedMode -eq 'Auto') {
        $selectedMode = Show-AuthenticationMenu -Config $Config

        if ($null -eq $selectedMode) {
            throw "Authentication cancelled by the operator."
        }
    }

    Write-Detail "Mode: $selectedMode"

    $existing = Get-ConnectionInformation -ErrorAction SilentlyContinue
    if ($null -ne $existing -and @($existing).Count -gt 0) {
        Write-Detail "Reusing the existing Exchange Online session."
    }
    else {
        try {
            switch ($selectedMode) {
                'Certificate' { Connect-CertificateAuth -Config $Config }
                'Interactive' { Connect-InteractiveAuth -Config $Config }
                'Delegated'   { Connect-DelegatedAuth -Config $Config }
            }
        }
        catch {
            Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0) -Context "Exchange Online sign-in ($selectedMode)"
            throw
        }
    }

    $connection = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
    $account = if ($null -ne $connection) { $connection.UserPrincipalName } else { $Config.AppID }

    Write-Success "Connected to $($Config.Organization) as $account"

    return [pscustomobject]@{
        Mode         = $selectedMode
        Organization = $Config.Organization
        Account      = $account
        ConnectedUtc = (Get-Date).ToUniversalTime()
    }
}

function Disconnect-MailboxDashboard {
    [CmdletBinding()]
    param()

    if (Get-Command -Name Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Get-Command -Name Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
    }
}

# Only connect when run directly; dot-sourcing just publishes the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $configParams = @{}
    if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
    if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $configParams.AuthenticationMode = $AuthenticationMode }

    $loadedConfig = Import-MailboxDashboardConfig @configParams
    Connect-MailboxDashboard -Config $loadedConfig
}
