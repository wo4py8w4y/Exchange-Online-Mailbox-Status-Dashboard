<#
.SYNOPSIS
    Prepares a MailboxDashboard installation for first use.
.DESCRIPTION
    Checks prerequisites, creates the folder structure, writes a configuration file from
    the shipped example, optionally registers the Entra application, and confirms the
    result by running a validation pass.

    Safe to re-run: existing files are never overwritten unless -Force is supplied.
.PARAMETER Unattended
    Skips the prompts and uses the supplied parameters and existing configuration only.
.EXAMPLE
    .\Initialize-MailboxDashboard.ps1
    Interactive setup.
.EXAMPLE
    .\Initialize-MailboxDashboard.ps1 -Organization contoso.onmicrosoft.com -AppId 0000... -Unattended
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Organization,

    [Parameter()]
    [string]$AppId,

    [Parameter()]
    [string]$UserPrincipalName,

    [Parameter()]
    [ValidateSet('Certificate', 'Interactive', 'Delegated', 'Auto')]
    [string]$AuthenticationMode,

    [Parameter()]
    [switch]$RegisterEntraApp,

    [Parameter()]
    [switch]$GenerateTestData,

    [Parameter()]
    [switch]$Unattended,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking

$script:CollectorRoot = $PSScriptRoot
$script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent

$script:RequiredModules = @(
    @{ Name = "ExchangeOnlineManagement";        Reason = "Exchange Online collection"; Required = $true }
    @{ Name = "Microsoft.Graph.Authentication";  Reason = "interactive sign-in";        Required = $false }
    @{ Name = "graph.auth.lite";                 Reason = "interactive OAuth/PKCE";     Required = $false }
    @{ Name = "Microsoft.PowerShell.ThreadJob";  Reason = "parallel collection";        Required = $false }
)

function Read-Answer {
<#
.SYNOPSIS
    Prompts for a value, returning the existing one when the operator just presses Enter.
#>
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter()] [string]$Current,
        [Parameter()] [switch]$AllowEmpty
    )

    if ($Unattended) {
        return $Current
    }

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($Current)) { "" } else { " [$Current]" }
        $answer = (Read-Host "  $Prompt$suffix").Trim()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            if (-not [string]::IsNullOrWhiteSpace($Current) -or $AllowEmpty) {
                return $Current
            }
            Write-Notice "A value is required."
            continue
        }

        return $answer
    }
}

function Test-Prerequisite {
    Write-Stage "Checking prerequisites"

    $problems = [System.Collections.Generic.List[string]]::new()

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -lt 5) {
        $problems.Add("PowerShell 5.1 or later is required; this is $psVersion.")
    }
    else {
        Write-Success "PowerShell $psVersion"
    }

    foreach ($module in $script:RequiredModules) {
        $installed = Get-Module -ListAvailable -Name $module.Name | Select-Object -First 1

        if ($null -ne $installed) {
            Write-Success "$($module.Name) $($installed.Version)"
            continue
        }

        if ($module.Required) {
            $problems.Add("$($module.Name) is not installed. Run: Install-Module $($module.Name) -Scope CurrentUser")
        }
        else {
            Write-Notice "$($module.Name) is not installed - needed only for $($module.Reason)."
        }
    }

    if ($problems.Count -gt 0) {
        $detail = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "Prerequisites are not met:$([Environment]::NewLine)$detail"
    }
}

function New-FolderStructure {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Stage "Creating folders"

    $folders = @(
        (Join-Path -Path $script:CollectorRoot -ChildPath "Config")
        (Join-Path -Path $script:CollectorRoot -ChildPath "Temp")
        (Join-Path -Path $script:CollectorRoot -ChildPath "Temp\ThreadJobs")
        (Join-Path -Path $script:CollectorRoot -ChildPath "Logs")
        (Join-Path -Path $script:RepositoryRoot -ChildPath "Mailboxes")
        (Join-Path -Path $script:RepositoryRoot -ChildPath "Web")
    )

    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath $folder) {
            Write-Detail "exists  $folder"
            continue
        }

        if ($PSCmdlet.ShouldProcess($folder, "Create directory")) {
            $null = New-Item -Path $folder -ItemType Directory -Force
            Write-Success "created $folder"
        }
    }
}

function Initialize-Configuration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TargetPath
    )

    Write-Stage "Configuration"

    $examplePath = Join-Path -Path $script:CollectorRoot -ChildPath "Config\dashboardConfig.example.json"

    if ((Test-Path -LiteralPath $TargetPath) -and -not $Force) {
        Write-Detail "Using the existing configuration at $TargetPath"
    }
    elseif ($PSCmdlet.ShouldProcess($TargetPath, "Create configuration")) {
        if (-not (Test-Path -LiteralPath $examplePath)) {
            throw "Template not found at '$examplePath'."
        }

        Confirm-ParentDirectory -Path $TargetPath
        Copy-Item -LiteralPath $examplePath -Destination $TargetPath -Force
        Write-Success "Created $TargetPath from the shipped template."
    }

    $config = Get-Content -LiteralPath $TargetPath -Raw | ConvertFrom-Json

    $currentOrganization = if ($PSBoundParameters.ContainsKey('Organization')) { $Organization } else { [string]$config.Organization }
    $currentAppId = if ($PSBoundParameters.ContainsKey('AppId')) { $AppId } else { [string]$config.AppID }
    $currentUpn = if ($PSBoundParameters.ContainsKey('UserPrincipalName')) { $UserPrincipalName } else { [string]$config.UserPrincipalName }
    $currentMode = if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $AuthenticationMode } else { [string]$config.Authentication.Mode }

    if (-not $Unattended) {
        Write-Detail "Press Enter to keep the value shown in brackets."
        $currentOrganization = Read-Answer -Prompt "Tenant ID or primary domain" -Current $currentOrganization
        $currentAppId = Read-Answer -Prompt "Entra application (client) ID" -Current $currentAppId -AllowEmpty
        $currentUpn = Read-Answer -Prompt "Admin user principal name" -Current $currentUpn -AllowEmpty
        $currentMode = Read-Answer -Prompt "Authentication mode (Certificate/Interactive/Delegated/Auto)" -Current $currentMode
    }

    $config.Organization = $currentOrganization
    $config.AppID = $currentAppId
    $config.UserPrincipalName = $currentUpn
    $config.Authentication.Mode = $currentMode

    if ($PSCmdlet.ShouldProcess($TargetPath, "Save configuration")) {
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $TargetPath -Encoding UTF8
        Write-Success "Saved $TargetPath"
    }

    return $config
}

function Initialize-MailboxCsv {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    Write-Stage "Mailbox list"

    if (Test-Path -LiteralPath $Path) {
        $rows = @(Import-Csv -LiteralPath $Path)
        Write-Detail "$Path already exists with $($rows.Count) row(s)."
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, "Create mailbox CSV template")) {
        Confirm-ParentDirectory -Path $Path
        @(
            "PrimarySMTPAddress"
            "first.mailbox@contoso.com"
            "second.mailbox@contoso.com"
        ) | Set-Content -LiteralPath $Path -Encoding UTF8

        Write-Success "Created a template at $Path"
        Write-Notice "Replace the sample rows with the mailboxes you want to collect."
    }
}

function Protect-Secret {
<#
.SYNOPSIS
    Warns when a client secret is stored in a file tracked by git.
#>
    param(
        [Parameter(Mandatory)] [string]$ConfigFilePath
    )

    $config = Get-Content -LiteralPath $ConfigFilePath -Raw | ConvertFrom-Json
    $secret = [string]$config.ClientSecret

    if ([string]::IsNullOrWhiteSpace($secret)) {
        return
    }

    $gitDirectory = Join-Path -Path $script:RepositoryRoot -ChildPath ".git"
    if (-not (Test-Path -LiteralPath $gitDirectory)) {
        return
    }

    $gitignorePath = Join-Path -Path $script:RepositoryRoot -ChildPath ".gitignore"
    $relativeConfig = "Collector/Config/dashboardConfig.json"
    $isIgnored = (Test-Path -LiteralPath $gitignorePath) -and
        ((Get-Content -LiteralPath $gitignorePath -Raw) -match [regex]::Escape($relativeConfig))

    if (-not $isIgnored) {
        Write-Stage "Security"
        Write-Notice "The configuration holds a ClientSecret and is not excluded from git."
        Write-Detail "Add this line to .gitignore, then rotate the secret if it has been committed:"
        Write-Detail "    $relativeConfig"
    }
}

# --- Entry point -------------------------------------------------------------

$resolvedConfigPath = if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    Resolve-MailboxPath -Path $ConfigPath -BaseDirectory $PWD.Path
}
else {
    Join-Path -Path $script:CollectorRoot -ChildPath "Config\dashboardConfig.json"
}

Write-ConsoleLine ""
Write-ConsoleLine -Message "  MailboxDashboard setup" -Colour Cyan

Test-Prerequisite
New-FolderStructure
$config = Initialize-Configuration -TargetPath $resolvedConfigPath

$csvPath = Resolve-MailboxPath -Path ([string]$config.Paths.MailboxesCsv) -BaseDirectory $script:CollectorRoot
Initialize-MailboxCsv -Path $csvPath

if ($RegisterEntraApp) {
    Write-Stage "Entra application"
    $registerScript = Join-Path -Path $script:CollectorRoot -ChildPath "Register-EntraApp.ps1"

    if (-not (Test-Path -LiteralPath $registerScript)) {
        Write-Notice "Register-EntraApp.ps1 was not found; register the application manually."
    }
    elseif ($PSCmdlet.ShouldProcess("Entra application", "Register")) {
        & $registerScript -ConfigPath $resolvedConfigPath
    }
}

if ($GenerateTestData) {
    Write-Stage "Test data"
    & (Join-Path -Path $script:CollectorRoot -ChildPath "New-MailboxDashboardTestData.ps1") -ConfigPath $resolvedConfigPath | Out-Null
    Write-Detail "Demo files written; copy them over history.json and data.json to preview the dashboard."
}

Protect-Secret -ConfigFilePath $resolvedConfigPath

Write-Stage "Next steps"
Write-Detail "1. Put your mailboxes in $csvPath"
Write-Detail "2. Preview without Exchange:  .\Collector\Invoke-MailboxDashboardCollection.ps1 -TestData"
Write-Detail "3. Collect for real:          .\Collector\Invoke-MailboxDashboardCollection.ps1"
Write-Detail "4. Browse the dashboard:      .\Web\HTTPServer.ps1 -RootPath .\Web -Prefix http://localhost:8888/"
Write-Success "Setup complete."

[pscustomobject]@{
    ConfigPath   = $resolvedConfigPath
    MailboxesCsv = $csvPath
    Organization = [string]$config.Organization
    AuthMode     = [string]$config.Authentication.Mode
}
