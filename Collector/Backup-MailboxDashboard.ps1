<#
.SYNOPSIS
    Validates and backs up the configured MailboxDashboard data files.
.DESCRIPTION
    Runs the configured JSON validator in read-only mode for each source before creating
    any backup. Validated files are copied to a timestamped, web-served backup folder,
    checked against their source SHA-256 hashes, and indexed in backup-status.json.
    BackupDirectory must be the Backups folder directly under the configured WebRoot;
    IIS and the built-in server allow only the status manifest and known JSON copies.
.EXAMPLE
    .\Backup-MailboxDashboard.ps1
    Validates and backs up the sources in dashboardConfig.json.
.EXAMPLE
    .\Backup-MailboxDashboard.ps1 -WhatIf
    Validates the sources and previews the destination without writing a backup.
.NOTES
    GitHub Summary: Validates, stages, hashes, and publishes dashboard data backups
    with an integrity manifest for the separate status page.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\MailboxDashboard.Common.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\MailboxDashboard.Config.psm1') -Force -DisableNameChecking

$configArguments = @{ SkipValidation = $true }
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    $configArguments.ConfigPath = $ConfigPath
}
$config = Import-MailboxDashboardConfig @configArguments

$backupDirectory = [string]$config.ResolvedPaths.BackupDirectory
if ([string]::IsNullOrWhiteSpace($backupDirectory)) {
    throw "Paths.BackupDirectory is required in '$($config.ConfigPath)'."
}

$webRoot = [string]$config.ResolvedPaths.WebRoot
if ([string]::IsNullOrWhiteSpace($webRoot)) {
    throw "Paths.WebRoot is required to publish backup copies safely."
}

$backupRoot = [System.IO.Path]::GetFullPath($backupDirectory)
$expectedBackupRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $webRoot -ChildPath 'Backups'))
if (-not [string]::Equals($backupRoot.TrimEnd('\'), $expectedBackupRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Paths.BackupDirectory must resolve to '$expectedBackupRoot' so the dashboard and web.config can restrict backup access."
}

$configuredSources = @($config.Backup.Sources)
if ($configuredSources.Count -eq 0) {
    throw "Backup.Sources must contain HistoryJson and/or DataJson in '$($config.ConfigPath)'."
}

$sourcePaths = [System.Collections.Generic.List[object]]::new()
$seenSources = @{}
$seenFileNames = @{}
foreach ($sourceNameValue in $configuredSources) {
    $sourceName = [string]$sourceNameValue
    if ($sourceName -notin @('HistoryJson', 'DataJson')) {
        throw "Unsupported Backup.Sources value '$sourceName'. Use HistoryJson and/or DataJson."
    }

    $sourceKey = $sourceName.ToLowerInvariant()
    if ($seenSources.ContainsKey($sourceKey)) {
        throw "Backup.Sources contains duplicate entry '$sourceName'."
    }
    $seenSources[$sourceKey] = $true

    $sourcePath = [string]$config.ResolvedPaths.$sourceName
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        throw "Paths.$sourceName is required for this backup."
    }

    $fileName = [System.IO.Path]::GetFileName($sourcePath)
    if ($seenFileNames.ContainsKey($fileName)) {
        throw "Backup sources '$($seenFileNames[$fileName])' and '$sourceName' resolve to the same filename '$fileName'."
    }
    $seenFileNames[$fileName] = $sourceName

    $sourcePaths.Add([pscustomobject]@{
        Name = $sourceName
        Kind = if ($sourceName -eq 'HistoryJson') { 'History' } else { 'Data' }
        Path = $sourcePath
    })
}

$validatorPath = Join-Path $PSScriptRoot 'Test-MailboxDashboardJSON.ps1'
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
    throw "Dashboard JSON validator not found at '$validatorPath'."
}

Write-Stage 'Validating backup sources'
$validationReports = [System.Collections.Generic.List[object]]::new()
foreach ($source in $sourcePaths) {
    $validationArguments = @{
        ConfigPath     = $config.ConfigPath
        Target         = $source.Kind
        FailOnInvalid  = $true
        Confirm        = $false
        WhatIf         = $false
    }
    $reports = @(& $validatorPath @validationArguments)
    if ($reports.Count -ne 1 -or -not $reports[0].IsValid) {
        throw "Validation did not confirm '$($source.Path)' as valid. No backup was created."
    }
    $validationReports.Add($reports[0])
}

$sourceHashes = @{}
foreach ($source in $sourcePaths) {
    $sourceHashes[$source.Name] = (Get-FileHash -LiteralPath $source.Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

$runId = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$finalDirectory = Join-Path $backupRoot "MailboxDashboard_$runId"
if (Test-Path -LiteralPath $finalDirectory) {
    throw "Backup destination already exists: '$finalDirectory'."
}

$manifestPath = Join-Path $backupRoot 'backup-status.json'
$previousBackups = @()
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Backup status manifest '$manifestPath' is invalid; refusing to overwrite it: $($_.Exception.Message)"
    }
    if ($existingManifest.PSObject.Properties.Name -notcontains 'Backups' -or $existingManifest.Backups -isnot [array]) {
        throw "Backup status manifest '$manifestPath' has no Backups array; refusing to overwrite it."
    }
    $previousBackups = @($existingManifest.Backups)
}

if (-not $PSCmdlet.ShouldProcess($finalDirectory, "Back up validated dashboard data")) {
    return [pscustomobject]@{
        Status            = 'WhatIf'
        BackupDirectory   = $finalDirectory
        Files             = @($sourcePaths | ForEach-Object { $_.Path })
        ValidationReports = @($validationReports)
    }
}

$stagingDirectory = "$finalDirectory.$([guid]::NewGuid().ToString('N')).writing"
$manifestTempPath = "$manifestPath.$([guid]::NewGuid().ToString('N')).writing"
$stagedFileDetails = [System.Collections.Generic.List[object]]::new()
try {
    $null = New-Item -Path $backupRoot -ItemType Directory -Force -ErrorAction Stop
    $null = New-Item -Path $stagingDirectory -ItemType Directory -Force -ErrorAction Stop
    foreach ($source in $sourcePaths) {
        $stagedFile = Join-Path $stagingDirectory (Split-Path -Path $source.Path -Leaf)
        Copy-Item -LiteralPath $source.Path -Destination $stagedFile -ErrorAction Stop

        $sourceHash = (Get-FileHash -LiteralPath $source.Path -Algorithm SHA256 -ErrorAction Stop).Hash
        $backupHash = (Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHashes[$source.Name] -cne $sourceHash -or $sourceHash -cne $backupHash) {
            throw "Backup integrity check failed for '$($source.Path)' because the source changed or the copy differs."
        }

        $stagedValidationArguments = @{
            ConfigPath    = $config.ConfigPath
            Target        = $source.Kind
            Path          = $stagedFile
            FailOnInvalid = $true
            Confirm       = $false
            WhatIf        = $false
        }
        $stagedReports = @(& $validatorPath @stagedValidationArguments)
        if ($stagedReports.Count -ne 1 -or -not $stagedReports[0].IsValid) {
            throw "Staged copy '$stagedFile' failed validation. No backup was finalized."
        }
        $validationReports.Add($stagedReports[0])
        $stagedFileDetails.Add([pscustomobject]@{
            Name = [System.IO.Path]::GetFileName($stagedFile)
            SHA256 = $backupHash
            SizeBytes = (Get-Item -LiteralPath $stagedFile -ErrorAction Stop).Length
            ValidationStatus = 'Valid'
        })
    }

    $newBackup = [pscustomobject]@{
        Id = "MailboxDashboard_$runId"
        CreatedUtc = [datetime]::UtcNow.ToString('o')
        ValidationStatus = 'Valid'
        Files = @($stagedFileDetails)
    }
    $manifestDocument = [pscustomobject]@{
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        Backups = @($previousBackups) + @($newBackup)
    }
    $manifestJson = ConvertTo-Json -InputObject $manifestDocument -Depth 10
    [System.IO.File]::WriteAllText(
        $manifestTempPath,
        $manifestJson,
        [System.Text.UTF8Encoding]::new($false)
    )

    Move-Item -LiteralPath $stagingDirectory -Destination $finalDirectory -ErrorAction Stop
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        [System.IO.File]::Replace($manifestTempPath, $manifestPath, $null)
    }
    else {
        Move-Item -LiteralPath $manifestTempPath -Destination $manifestPath -ErrorAction Stop
    }
}
catch {
    $operationError = $_
    foreach ($temporaryPath in @($stagingDirectory, $manifestTempPath)) {
        if (Test-Path -LiteralPath $temporaryPath) {
            try {
                Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                throw "Backup failed: $($operationError.Exception.Message) Temporary-file cleanup also failed for '$temporaryPath': $($_.Exception.Message)"
            }
        }
    }
    if (Test-Path -LiteralPath $finalDirectory) {
        throw "Backup files were finalized at '$finalDirectory', but status manifest update failed: $($operationError.Exception.Message)"
    }
    throw $operationError
}

Write-Success "Validated backup created at $finalDirectory"
return [pscustomobject]@{
    Status            = 'Succeeded'
    BackupDirectory   = $finalDirectory
    Files             = @($sourcePaths | ForEach-Object { $_.Path })
    ValidationReports = @($validationReports)
}
