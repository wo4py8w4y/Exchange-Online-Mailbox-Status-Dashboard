<#
.SYNOPSIS
    Creates or updates the Entra app registration used by the collector.
.DESCRIPTION
    Uses Microsoft Graph PowerShell to create or repair a public client app
    registration for delegated Exchange Online access. The script can:

    - create the app registration when no AppId is configured
    - update an existing app registration when an AppId already exists
    - enable the loopback redirect URI used by the token helper
    - enable public client flows
    - request the delegated Office 365 Exchange Online permission
      Exchange.Manage
    - create the service principal and grant admin consent for that scope
    - update dashboardConfig.json with the resulting AppId and tenant
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json"),

    [Parameter()]
    [string]$TenantIdOrDomain,

    [Parameter()]
    [string]$AppId,

    [Parameter()]
    [string]$DisplayName = "MailboxDashboard Collector",

    [Parameter()]
    [string]$RedirectUri = "http://localhost:8400/",

    [Parameter()]
    [switch]$CreateIfMissing,

    [Parameter()]
    [switch]$NoConfigUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Applications -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $Path))
}

function Test-PlaceholderValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value -match "^x+$"
}

function New-UniqueStringArray {
    param(
        [Parameter(Mandatory)]
        [object[]]$Values
    )

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        $stringValue = [string]$value
        if ([string]::IsNullOrWhiteSpace($stringValue)) {
            continue
        }

        if (-not $items.Contains($stringValue)) {
            $items.Add($stringValue)
        }
    }

    return @($items)
}

function ConvertTo-RequiredResourceAccess {
    param(
        [Parameter()]
        [object[]]$ExistingEntries,

        [Parameter(Mandatory)]
        [string]$ResourceAppId,

        [Parameter(Mandatory)]
        [guid]$PermissionId,

        [Parameter()]
        [string]$PermissionType = "Scope"
    )

    $result = [System.Collections.Generic.List[object]]::new()
    $resourceFound = $false

    foreach ($entry in @($ExistingEntries)) {
        if ($null -eq $entry) {
            continue
        }

        $accessItems = [System.Collections.Generic.List[object]]::new()
        foreach ($access in @($entry.ResourceAccess)) {
            if ($null -eq $access) {
                continue
            }

            $accessItems.Add(@{
                    Id   = [guid]$access.Id
                    Type = [string]$access.Type
                })
        }

        if ([string]$entry.ResourceAppId -eq $ResourceAppId) {
            $resourceFound = $true
            $alreadyPresent = $false
            foreach ($access in $accessItems) {
                if ([guid]$access.Id -eq $PermissionId -and [string]$access.Type -eq $PermissionType) {
                    $alreadyPresent = $true
                    break
                }
            }

            if (-not $alreadyPresent) {
                $accessItems.Add(@{
                        Id   = $PermissionId
                        Type = $PermissionType
                    })
            }
        }

        $result.Add(@{
                ResourceAppId = [string]$entry.ResourceAppId
                ResourceAccess = @($accessItems)
            })
    }

    if (-not $resourceFound) {
        $result.Add(@{
                ResourceAppId = $ResourceAppId
                ResourceAccess = @(@{
                        Id   = $PermissionId
                        Type = $PermissionType
                    })
            })
    }

    return @($result)
}

function Update-ConfigFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$TenantValue,

        [Parameter(Mandatory)]
        [string]$AppIdValue
    )

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $changed = $false

    if (-not [string]::IsNullOrWhiteSpace($TenantValue) -and [string]$config.Organization -ne $TenantValue) {
        $config.Organization = $TenantValue
        $changed = $true
    }

    if ([string]$config.AppID -ne $AppIdValue) {
        $config.AppID = $AppIdValue
        $changed = $true
    }

    if ($changed) {
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
    }
}

function Connect-MicrosoftGraphSession {
    param(
        [Parameter()]
        [string]$TenantValue
    )

    $requiredScopes = @(
        "Application.ReadWrite.All"
        "Directory.ReadWrite.All"
        "DelegatedPermissionGrant.ReadWrite.All"
    )

    $context = Get-MgContext
    if ($null -ne $context) {
        if ([string]::IsNullOrWhiteSpace($TenantValue) -or $context.TenantId -eq $TenantValue) {
            return
        }
    }

    $connectParams = @{
        Scopes    = $requiredScopes
        NoWelcome = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantValue)) {
        $connectParams.TenantId = $TenantValue
    }

    Connect-MgGraph @connectParams | Out-Null
}

function Get-ApplicationByIdWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationId,

        [Parameter()]
        [int]$MaxAttempts = 5,

        [Parameter()]
        [int]$DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $app = Get-MgApplication -ApplicationId $ApplicationId -Property "id,appId,displayName,requiredResourceAccess,isFallbackPublicClient,publicClient"
        if ($null -ne $app) {
            return $app
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $null
}

$resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Configuration file not found at '$resolvedConfigPath'."
}

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($TenantIdOrDomain)) {
    $TenantIdOrDomain = [string]$config.Organization
}

if ([string]::IsNullOrWhiteSpace($AppId)) {
    $AppId = [string]$config.AppID
}

if (-not [string]::IsNullOrWhiteSpace($AppId) -and (Test-PlaceholderValue -Value $AppId)) {
    $AppId = ""
}

if (-not [string]::IsNullOrWhiteSpace($TenantIdOrDomain) -and (Test-PlaceholderValue -Value $TenantIdOrDomain)) {
    $TenantIdOrDomain = ""
}

Connect-MicrosoftGraphSession -TenantValue $TenantIdOrDomain

$exchangeOnlineAppId = "00000002-0000-0ff1-ce00-000000000000"
$exchangePermissionName = "Exchange.Manage"

$exchangeSp = Get-MgServicePrincipal -Filter "appId eq '$exchangeOnlineAppId'" -Property "id,appId,displayName,oauth2PermissionScopes" -All |
    Select-Object -First 1
if ($null -eq $exchangeSp) {
    throw "Could not find the Office 365 Exchange Online service principal in the current tenant."
}

$exchangeScope = @($exchangeSp.Oauth2PermissionScopes) | Where-Object { [string]$_.Value -eq $exchangePermissionName } | Select-Object -First 1
if ($null -eq $exchangeScope) {
    throw "Could not find delegated Exchange permission '$exchangePermissionName' on the Exchange Online service principal."
}

$existingApplication = $null
if (-not [string]::IsNullOrWhiteSpace($AppId)) {
    $existingApplication = Get-MgApplication -Filter "appId eq '$AppId'" -Property "id,appId,displayName,requiredResourceAccess,isFallbackPublicClient,publicClient" -All |
        Select-Object -First 1
}

if ($null -eq $existingApplication -and -not $CreateIfMissing -and -not [string]::IsNullOrWhiteSpace($AppId)) {
    throw "App registration '$AppId' was not found. Use -CreateIfMissing to create a new registration or clear AppID in the config."
}

$requiredResourceAccess = @()
if ($null -ne $existingApplication) {
    $requiredResourceAccess = @($existingApplication.RequiredResourceAccess)
}

$requiredResourceAccess = ConvertTo-RequiredResourceAccess `
    -ExistingEntries $requiredResourceAccess `
    -ResourceAppId $exchangeOnlineAppId `
    -PermissionId ([guid]$exchangeScope.Id) `
    -PermissionType "Scope"

$publicClient = @{
    RedirectUris = @($RedirectUri)
}

if ($null -eq $existingApplication) {
    $createParams = @{
        DisplayName            = $DisplayName
        SignInAudience         = "AzureADMyOrg"
        IsFallbackPublicClient  = $true
        PublicClient           = $publicClient
        RequiredResourceAccess = $requiredResourceAccess
    }

    if ($PSCmdlet.ShouldProcess("Entra application '$DisplayName'", "Create registration")) {
        $application = New-MgApplication @createParams
    }
}
else {
    $mergedRedirectUris = @()
    if ($existingApplication.PublicClient -and $existingApplication.PublicClient.RedirectUris) {
        $mergedRedirectUris += @($existingApplication.PublicClient.RedirectUris)
    }
    $mergedRedirectUris += $RedirectUri
    $publicClient.RedirectUris = New-UniqueStringArray -Values $mergedRedirectUris

    $updateParams = @{
        ApplicationId          = $existingApplication.Id
        DisplayName            = $DisplayName
        IsFallbackPublicClient  = $true
        PublicClient           = $publicClient
        RequiredResourceAccess = $requiredResourceAccess
    }

    if ($PSCmdlet.ShouldProcess("Entra application '$DisplayName'", "Update registration")) {
        Update-MgApplication @updateParams | Out-Null
        $application = Get-ApplicationByIdWithRetry -ApplicationId $existingApplication.Id
    }
}

if ($null -eq $application) {
    if ($WhatIfPreference) {
        Write-Host "WhatIf: no Entra changes were applied." -ForegroundColor Yellow
        return
    }

    throw "Application creation or update did not return an application record."
}

$appObjectId = [string]$application.Id
$appClientId = [string]$application.AppId

$servicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$appClientId'" -Property "id,appId,displayName" -All |
    Select-Object -First 1
if ($null -eq $servicePrincipal) {
    if ($PSCmdlet.ShouldProcess("Service principal for '$DisplayName'", "Create service principal")) {
        $servicePrincipal = New-MgServicePrincipal -AppId $appClientId -DisplayName $DisplayName
    }
}

if ($null -eq $servicePrincipal) {
    throw "Failed to create or locate the service principal for app '$DisplayName'."
}

$grantScope = [string]$exchangeScope.Value
$existingGrant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($servicePrincipal.Id)' and resourceId eq '$($exchangeSp.Id)'" -All |
    Select-Object -First 1

if ($null -eq $existingGrant) {
    $grantParams = @{
        ClientId    = $servicePrincipal.Id
        ConsentType = "AllPrincipals"
        ResourceId  = $exchangeSp.Id
        Scope       = $grantScope
    }

    if ($PSCmdlet.ShouldProcess("Delegated permission grant for '$DisplayName'", "Grant '$grantScope'")) {
        $permissionGrant = New-MgOauth2PermissionGrant @grantParams
    }
}
else {
    $scopes = @($existingGrant.Scope -split '\s+') + $grantScope
    $grantParams = @{
        OAuth2PermissionGrantId = $existingGrant.Id
        Scope                   = (New-UniqueStringArray -Values $scopes) -join ' '
    }

    if ($PSCmdlet.ShouldProcess("Delegated permission grant for '$DisplayName'", "Update '$grantScope'")) {
        $permissionGrant = Update-MgOauth2PermissionGrant @grantParams
    }
}

if (-not $NoConfigUpdate) {
    if ($PSCmdlet.ShouldProcess($resolvedConfigPath, "Update dashboard config with AppId and tenant")) {
        Update-ConfigFile -Path $resolvedConfigPath -TenantValue $TenantIdOrDomain -AppIdValue $appClientId
    }
}

[pscustomobject]@{
    DisplayName        = $DisplayName
    Tenant             = $TenantIdOrDomain
    AppId              = $appClientId
    ApplicationObjectId = $appObjectId
    ServicePrincipalId = [string]$servicePrincipal.Id
    RedirectUri        = $RedirectUri
    ExchangeScope      = $grantScope
    ConfigUpdated      = -not $NoConfigUpdate
}
