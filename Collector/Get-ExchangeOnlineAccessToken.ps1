<#
.SYNOPSIS
    Creates an Exchange Online access token for the collector.
.DESCRIPTION
    Acquires a delegated Exchange Online token with browser sign-in by default
    when a user principal name is available. Can also request an app-only token
    with client credentials when -AuthenticationMode AppOnly is specified.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json"),

    [Parameter()]
    [string]$UserPrincipalName,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$TenantIdOrDomain,

    [Parameter()]
    [string]$ClientSecret,

    [Parameter()]
    [string]$RedirectUri = "http://localhost:8400/",

    [Parameter()]
    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 300,

    [Parameter()]
    [ValidateSet("Auto", "Delegated", "AppOnly")]
    [string]$AuthenticationMode = "Auto"
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

    $rootDirectory = if ([string]::IsNullOrWhiteSpace($BaseDirectory)) { $scriptBaseDirectory } else { $BaseDirectory }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $rootDirectory -ChildPath $Path))
}

function Test-PlaceholderValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value -match "^x+$"
}

function ConvertTo-Base64UrlString {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-CodeVerifier {
    $randomBytes = [byte[]]::new(64)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
    }
    finally {
        $rng.Dispose()
    }

    return ConvertTo-Base64UrlString -Bytes $randomBytes
}

function New-CodeChallenge {
    param(
        [Parameter(Mandatory)]
        [string]$CodeVerifier
    )

    $verifierBytes = [System.Text.Encoding]::ASCII.GetBytes($CodeVerifier)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($verifierBytes)
    }
    finally {
        $sha256.Dispose()
    }

    return ConvertTo-Base64UrlString -Bytes $hashBytes
}

function New-FormUrlEncodedBody {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Body
    )

    $pairs = foreach ($key in $Body.Keys) {
        "{0}={1}" -f [System.Uri]::EscapeDataString([string]$key), [System.Uri]::EscapeDataString([string]$Body[$key])
    }

    return ($pairs -join "&")
}

function Parse-QueryParameters {
    param(
        [AllowEmptyString()]
        [string]$Query
    )

    $parameters = @{}
    $trimmedQuery = $Query.TrimStart('?')
    if ([string]::IsNullOrWhiteSpace($trimmedQuery)) {
        return $parameters
    }

    foreach ($pair in $trimmedQuery.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        $name = [System.Net.WebUtility]::UrlDecode($parts[0])
        $value = if ($parts.Count -gt 1) { [System.Net.WebUtility]::UrlDecode($parts[1]) } else { "" }
        $parameters[$name] = $value
    }

    return $parameters
}

$resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Configuration file not found at '$resolvedConfigPath'."
}

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    $ClientId = [string]$config.AppID
}

if ([string]::IsNullOrWhiteSpace($TenantIdOrDomain)) {
    $TenantIdOrDomain = [string]$config.Organization
}

if ([string]::IsNullOrWhiteSpace($UserPrincipalName) -and ($config.PSObject.Properties.Name -contains "UserPrincipalName")) {
    $UserPrincipalName = [string]$config.UserPrincipalName
}

if ([string]::IsNullOrWhiteSpace($ClientId) -or (Test-PlaceholderValue -Value $ClientId)) {
    throw "AppID must be populated in config or passed with -ClientId to create an Exchange Online access token."
}

if ([string]::IsNullOrWhiteSpace($TenantIdOrDomain) -or (Test-PlaceholderValue -Value $TenantIdOrDomain)) {
    throw "Organization must be populated in config or passed with -TenantIdOrDomain to create an Exchange Online access token."
}

$clientSecretValue = $ClientSecret
if ([string]::IsNullOrWhiteSpace($clientSecretValue) -and ($config.PSObject.Properties.Name -contains "ClientSecret")) {
    $clientSecretValue = [string]$config.ClientSecret
}

if ([string]::IsNullOrWhiteSpace($clientSecretValue) -and ($config.PSObject.Properties.Name -contains "AppSecret")) {
    $clientSecretValue = [string]$config.AppSecret
}

if ([string]::IsNullOrWhiteSpace($clientSecretValue)) {
    $clientSecretValue = [string]$env:MAILBOXDASHBOARD_CLIENT_SECRET
}

$hasClientSecret = -not [string]::IsNullOrWhiteSpace($clientSecretValue) -and -not (Test-PlaceholderValue -Value $clientSecretValue)

$resolvedAuthenticationMode = switch ($AuthenticationMode) {
    "Delegated" { "Delegated" }
    "AppOnly" { "AppOnly" }
    default {
        if (-not [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
            "Delegated"
        }
        elseif ($hasClientSecret) {
            "AppOnly"
        }
        else {
            "Delegated"
        }
    }
}

$tenantSegment = [System.Uri]::EscapeDataString($TenantIdOrDomain)
$tokenUri = "https://login.microsoftonline.com/$tenantSegment/oauth2/v2.0/token"

if ($resolvedAuthenticationMode -eq "AppOnly") {
    if (-not $hasClientSecret) {
        throw "ClientSecret must be populated in config, passed with -ClientSecret, or provided through the MAILBOXDASHBOARD_CLIENT_SECRET environment variable when using -AuthenticationMode AppOnly."
    }

    $tokenRequestBody = New-FormUrlEncodedBody -Body @{
        client_id     = $ClientId
        client_secret = $clientSecretValue
        grant_type    = "client_credentials"
        scope         = "https://outlook.office365.com/.default"
    }

    try {
        $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $tokenRequestBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($null -ne $_.ErrorDetails) {
            $message = [string]$_.ErrorDetails.Message
        }

        throw "App-only token request failed: $message. Confirm the app registration has Exchange Online application permissions such as Exchange.ManageAsApp granted and the client secret is valid."
    }

    $accessToken = [string]$tokenResponse.access_token
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Token endpoint response did not contain an access_token."
    }

    Write-Output $accessToken
    return
}

$redirectUriObject = [System.Uri]$RedirectUri
if (-not $redirectUriObject.IsLoopback) {
    throw "RedirectUri must be a loopback address for delegated browser sign-in."
}

$listenerPrefix = $redirectUriObject.GetLeftPart([System.UriPartial]::Path)
if (-not $listenerPrefix.EndsWith("/")) {
    $listenerPrefix += "/"
}

$scope = "https://outlook.office365.com/.default offline_access openid profile"
$state = [guid]::NewGuid().ToString("N")
$codeVerifier = New-CodeVerifier
$codeChallenge = New-CodeChallenge -CodeVerifier $codeVerifier

$authorizeParameters = [ordered]@{
    client_id             = $ClientId
    response_type         = "code"
    redirect_uri          = $RedirectUri
    response_mode         = "query"
    scope                 = $scope
    code_challenge        = $codeChallenge
    code_challenge_method = "S256"
    state                 = $state
    prompt                = "select_account"
}

if (-not [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
    $authorizeParameters.login_hint = $UserPrincipalName
}

$authorizeQuery = New-FormUrlEncodedBody -Body $authorizeParameters
$authorizeUri = "https://login.microsoftonline.com/$tenantSegment/oauth2/v2.0/authorize?$authorizeQuery"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($listenerPrefix)

try {
    $listener.Start()
    Start-Process $authorizeUri | Out-Null

    Write-Host "Opened browser sign-in for Exchange Online token acquisition." -ForegroundColor Cyan
    Write-Host "This flow requires the delegated Exchange Online permission 'Exchange.Manage' and the redirect URI '$RedirectUri' on the app registration." -ForegroundColor Yellow

    $contextTask = $listener.GetContextAsync()
    if (-not $contextTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        throw "Timed out waiting for browser authentication to complete after $TimeoutSeconds seconds."
    }

    $context = $contextTask.Result
    $request = $context.Request
    $response = $context.Response

    $query = Parse-QueryParameters -Query $request.Url.Query
    $authorizationError = $query["error"]
    if (-not [string]::IsNullOrWhiteSpace($authorizationError)) {
        $authorizationErrorDescription = $query["error_description"]
        throw "Authorization failed: $authorizationError $authorizationErrorDescription"
    }

    $authorizationCode = $query["code"]
    if ([string]::IsNullOrWhiteSpace($authorizationCode)) {
        throw "Authorization response did not include a code."
    }

    if ($query["state"] -ne $state) {
        throw "Authorization state validation failed."
    }

    $responseHtml = @"
<html>
  <head><title>Exchange Online Token</title></head>
  <body>
    <h2>Authentication completed.</h2>
    <p>You can close this browser window and return to PowerShell.</p>
  </body>
</html>
"@

    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseHtml)
    $response.ContentType = "text/html; charset=utf-8"
    $response.ContentLength64 = $responseBytes.Length
    $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
    $response.OutputStream.Close()

    $tokenRequestBody = New-FormUrlEncodedBody -Body @{
        client_id     = $ClientId
        grant_type    = "authorization_code"
        code          = $authorizationCode
        redirect_uri  = $RedirectUri
        code_verifier = $codeVerifier
        scope         = $scope
    }

    try {
        $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $tokenRequestBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($null -ne $_.ErrorDetails) {
            $message = [string]$_.ErrorDetails.Message
        }

        throw "Delegated token request failed: $message. Confirm the app registration allows public client flows, the redirect URI '$RedirectUri' is configured, and the delegated Exchange Online permission 'Exchange.Manage' is granted."
    }

    $accessToken = [string]$tokenResponse.access_token
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Token endpoint response did not contain an access_token."
    }

    Write-Output $accessToken
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }

    $listener.Close()
}
