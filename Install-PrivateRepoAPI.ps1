#Requires -Version 7.0

<#
.SYNOPSIS
Installs and configures the Private PowerShell Repository API.

.DESCRIPTION
Creates folders, installs dependencies, configures certificates,
creates environment settings, and prepares the repository API
for first use.

.NOTES
Run as Administrator.
#>

#region Logging

$ScriptStart = Get-Date
$LogDirectory = Join-Path $PSScriptRoot "Logs"

if (!(Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$LogFile = Join-Path $LogDirectory ("Install_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $logEntry = "$timestamp [$Level] $Message"

    Add-Content -Path $LogFile -Value $logEntry

    switch ($Level) {
        "INFO"    { Write-Host $Message -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARN"    { Write-Host $Message -ForegroundColor Yellow }
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Host $Message }
    }
}

#endregion

#region Banner

Clear-Host

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " Private Repository API Installer" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""

#endregion

#region Validation

Write-Log "Validating prerequisites..."

if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Log "Installer must be run as Administrator." "ERROR"
    exit 1
}

Write-Log "Administrator rights confirmed." "SUCCESS"

try {
    $version = $PSVersionTable.PSVersion
    Write-Log "PowerShell Version: $version"
}
catch {
    Write-Log "Unable to determine PowerShell version." "ERROR"
    exit 1
}

#endregion

#region User Input

Write-Host ""
Write-Host "Configuration Settings" -ForegroundColor Magenta
Write-Host ""

$InstallRoot = Read-Host "Install Path [Default: C:\PrivateRepoAPI]"

if (:IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = "C:\PrivateRepoAPI"
}

$ApiPort = Read-Host "HTTP Port [Default: 8080]"

if (:IsNullOrWhiteSpace($ApiPort)) {
    $ApiPort = "8080"
}

$HttpsPort = Read-Host "HTTPS Port [Default: 8443]"

if (:IsNullOrWhiteSpace($HttpsPort)) {
    $HttpsPort = "8443"
}

$ApiKey = Read-Host "API Key (Leave blank to auto-generate)"

if (:IsNullOrWhiteSpace($ApiKey)) {

    $ApiKey = :NewGuid().Guid

    Write-Log "Generated secure API key." "SUCCESS"
}

$DnsName = Read-Host "Certificate DNS Name [Default: localhost]"

if (:IsNullOrWhiteSpace($DnsName)) {
    $DnsName = "localhost"
}

#endregion

#region Folder Creation

Write-Log "Creating folder structure..."

$Folders = @(
    $InstallRoot,
    "$InstallRoot\Repository",
    "$InstallRoot\Repository\Modules",
    "$InstallRoot\Repository\Scripts",
    "$InstallRoot\Logs",
    "$InstallRoot\Certs",
    "$InstallRoot\Config"
)

foreach ($Folder in $Folders) {

    if (!(Test-Path $Folder)) {

        New-Item `
            -ItemType Directory `
            -Path $Folder `
            -Force | Out-Null

        Write-Log "Created $Folder"
    }
}

Write-Log "Folder structure completed." "SUCCESS"

#endregion

#region Install Pode

Write-Log "Checking for Pode..."

try {

    if (!(Get-Module Pode -ListAvailable)) {

        Write-Log "Installing Pode..."

        Install-Module `
            Pode `
            -Repository PSGallery `
            -Force `
            -Scope AllUsers

        Write-Log "Pode installed successfully." "SUCCESS"
    }
    else {

        Write-Log "Pode already installed." "SUCCESS"
    }
}
catch {

    Write-Log $_.Exception.Message "ERROR"
    exit 1
}

#endregion

#region Certificate

Write-Log "Creating HTTPS certificate..."

try {

    $CertPasswordPlain = :NewGuid().Guid

    $CertPassword =
        ConvertTo-SecureString `
        $CertPasswordPlain `
        -AsPlainText `
        -Force

    $CertFile =
        Join-Path `
        "$InstallRoot\Certs" `
        "PrivateRepoAPI.pfx"

    $Cert =
        New-SelfSignedCertificate `
        -DnsName $DnsName `
        -CertStoreLocation Cert:\LocalMachine\My

    Export-PfxCertificate `
        -Cert $Cert `
        -FilePath $CertFile `
        -Password $CertPassword | Out-Null

    Write-Log "Certificate created successfully." "SUCCESS"
}
catch {

    Write-Log $_.Exception.Message "ERROR"
    exit 1
}

#endregion

#region Firewall

Write-Log "Creating firewall rules..."

try {

    New-NetFirewallRule `
        -DisplayName "PrivateRepoAPI HTTP" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $ApiPort `
        -ErrorAction SilentlyContinue | Out-Null

    New-NetFirewallRule `
        -DisplayName "PrivateRepoAPI HTTPS" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $HttpsPort `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Log "Firewall rules created." "SUCCESS"
}
catch {

    Write-Log "Firewall configuration skipped." "WARN"
}

#endregion

#region Configuration File

Write-Log "Creating configuration..."

$Config = @{
    InstallRoot  = $InstallRoot
    ApiPort      = $ApiPort
    HttpsPort    = $HttpsPort
    ApiKey       = $ApiKey
    CertFile     = $CertFile
    DnsName      = $DnsName
    LogDirectory = "$InstallRoot\Logs"
}

$ConfigFile =
    Join-Path `
    "$InstallRoot\Config" `
    "settings.json"

$Config |
    ConvertTo-Json -Depth 5 |
    Set-Content $ConfigFile

Write-Log "Configuration saved." "SUCCESS"

#endregion

#region Summary

$Duration =
    (Get-Date) - $ScriptStart

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " Installation Complete" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Install Path :" $InstallRoot -ForegroundColor White
Write-Host "HTTP Port    :" $ApiPort -ForegroundColor White
Write-Host "HTTPS Port   :" $HttpsPort -ForegroundColor White
Write-Host "API Key      :" $ApiKey -ForegroundColor Yellow
Write-Host "Config File  :" $ConfigFile -ForegroundColor White
Write-Host "Log File     :" $LogFile -ForegroundColor White
Write-Host ""

Write-Log "Installation completed in $($Duration.TotalSeconds) seconds." "SUCCESS"

#endregion