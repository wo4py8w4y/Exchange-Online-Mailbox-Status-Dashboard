<#
.SYNOPSIS
    Compares a live MailboxDashboard installation with the GitHub repository and optionally pulls the changed files.

.DESCRIPTION
    Downloads the repository archive (no git client required), recursively compares every file against the
    installation by SHA256 (line-ending insensitive for text files), and reports Modified, Missing, LocalOnly,
    and Protected files. With -Apply, Modified and Missing files are copied into the installation after the
    current versions are backed up. Protected files (local config, generated data) are never overwritten and
    LocalOnly files are never deleted.

    Every operation is written to the console in colour and appended to a log file
    (default: <InstallRoot>\Collector\Logs\Sync-MailboxDashboard-<timestamp>.log).

.EXAMPLE
    .\Sync-MailboxDashboardFromGitHub.ps1 -InstallRoot F:\Website\Qbuild-Mon
    Reports drift only.

.EXAMPLE
    .\Sync-MailboxDashboardFromGitHub.ps1 -InstallRoot F:\Website\Qbuild-Mon -Apply -ReportPath .\sync-report.csv
    Backs up and replaces changed files, then writes the comparison report.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$InstallRoot = $PSScriptRoot,

    [Parameter()]
    [string]$RepositoryUrl = "https://github.com/wo4py8w4y/Exchange-Online-Mailbox-Status-Dashboard.git",

    [Parameter()]
    [string]$Branch,

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [string]$BackupRoot,

    [Parameter()]
    [string]$ReportPath,

    [Parameter()]
    [string[]]$ExcludedPrefix = @(
        ".git\",
        ".github\",
        ".vs\",
        ".vscode\",
        "Mailboxes\",
        "Collector\Legacy\",
        "Collector\Temp\",
        "Collector\Logs\",
        "Web\logs\",
        "_SyncBackup\"
    ),

    [Parameter()]
    [string[]]$ProtectedPath = @(
        "Collector\Config\dashboardConfig.json",
        "Web\data.json",
        "Web\history.json",
        "Web\scopes.json",
        "Web\web.config"
    ),

    [Parameter()]
    [string]$LogPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$textExtensions = @(".ps1", ".psm1", ".psd1", ".js", ".html", ".htm", ".css", ".json", ".jsonc", ".md", ".txt", ".config", ".code-workspace", ".xml", ".csv")
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:LogFile = $null

$logColours = @{
    Stage     = "Cyan"
    Info      = "White"
    Detail    = "DarkGray"
    Success   = "Green"
    Warning   = "Yellow"
    Error     = "Red"
    Match     = "DarkGreen"
    Modified  = "Yellow"
    Missing   = "Magenta"
    LocalOnly = "DarkYellow"
    Protected = "DarkCyan"
    Updated   = "Green"
    Backup    = "Blue"
    Skipped   = "DarkGray"
}

function Write-SyncLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateScript({ $logColours.ContainsKey($_) })][string]$Level = "Info"
    )

    $line = "[{0}] [{1,-9}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level.ToUpperInvariant(), $Message
    Write-Host $line -ForegroundColor $logColours[$Level]

    if ($null -ne $script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false
    }
}

function Get-RepositoryCoordinate {
    param([Parameter(Mandatory)][string]$Url)

    if ($Url -notmatch "github\.com[/:](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?/?$") {
        throw "RepositoryUrl '$Url' is not a recognised GitHub repository URL."
    }

    return [pscustomobject]@{ Owner = $Matches.owner; Repo = $Matches.repo }
}

function Test-PathMatch {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string[]]$Prefixes,
        [string[]]$ExactPaths
    )

    foreach ($prefix in $Prefixes) {
        if ($RelativePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($path in $ExactPaths) {
        if ($RelativePath -ieq $path) { return $true }
    }
    return $false
}

function Get-NormalizedFileHash {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($textExtensions -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        # Latin-1 round-trips bytes exactly, so only CRLF -> LF changes; avoids git autocrlf false positives.
        $bytes = $latin1.GetBytes($latin1.GetString($bytes).Replace("`r`n", "`n"))
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileInventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )

    Write-SyncLog -Level Stage -Message "Scanning $Label files under $Root"
    $inventory = @{}
    $excludedCount = 0
    $rootLength = $Root.TrimEnd("\").Length + 1
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force) {
        $relativePath = $file.FullName.Substring($rootLength)
        if (Test-PathMatch -RelativePath $relativePath -Prefixes $ExcludedPrefix) {
            $excludedCount++
            continue
        }
        $inventory[$relativePath] = $file.FullName
    }
    Write-SyncLog -Level Info -Message "$Label inventory: $($inventory.Count) file(s) in scope, $excludedCount excluded"
    return $inventory
}

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    Write-SyncLog -Level Error -Message "InstallRoot '$InstallRoot' does not exist."
    throw "InstallRoot '$InstallRoot' does not exist."
}

$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $InstallRoot "Collector\Logs\Sync-MailboxDashboard-$runStamp.log"
}
$LogPath = [System.IO.Path]::GetFullPath($LogPath)
New-Item -Path (Split-Path $LogPath -Parent) -ItemType Directory -Force -WhatIf:$false | Out-Null
$script:LogFile = $LogPath

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MailboxDashboardSync-" + [guid]::NewGuid().ToString("N"))

try {
    Write-SyncLog -Level Stage -Message "MailboxDashboard sync started"
    Write-SyncLog -Level Info -Message "Host: $env:COMPUTERNAME  User: $env:USERDOMAIN\$env:USERNAME  PowerShell: $($PSVersionTable.PSVersion)"
    Write-SyncLog -Level Info -Message "Install root: $InstallRoot"
    Write-SyncLog -Level Info -Message "Mode: $(if ($Apply) { if ($WhatIfPreference) { 'Apply (WhatIf)' } else { 'Apply' } } else { 'Report only' })"
    Write-SyncLog -Level Info -Message "Log file: $LogPath"
    Write-SyncLog -Level Detail -Message "Excluded prefixes: $($ExcludedPrefix -join ', ')"
    Write-SyncLog -Level Detail -Message "Protected paths: $($ProtectedPath -join ', ')"

    # Windows PowerShell 5.1 on older servers may not negotiate TLS 1.2 by default.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $repository = Get-RepositoryCoordinate -Url $RepositoryUrl
    Write-SyncLog -Level Info -Message "Repository: $($repository.Owner)/$($repository.Repo)"
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        Write-SyncLog -Level Stage -Message "Querying default branch from GitHub API"
        try {
            $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$($repository.Owner)/$($repository.Repo)" -UseBasicParsing -Headers @{ "User-Agent" = "MailboxDashboard-Sync" }
            $Branch = $repoInfo.default_branch
        }
        catch {
            Write-SyncLog -Level Warning -Message "Could not query the default branch ($($_.Exception.Message)). Falling back to 'main'."
            $Branch = "main"
        }
    }
    Write-SyncLog -Level Info -Message "Branch: $Branch"

    New-Item -Path $workRoot -ItemType Directory -Force -WhatIf:$false | Out-Null
    Write-SyncLog -Level Detail -Message "Working folder: $workRoot"

    $archivePath = Join-Path $workRoot "repo.zip"
    $archiveUrl = "https://codeload.github.com/$($repository.Owner)/$($repository.Repo)/zip/refs/heads/$Branch"
    Write-SyncLog -Level Stage -Message "Downloading $archiveUrl"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
    Write-SyncLog -Level Success -Message ("Downloaded archive ({0:N0} bytes)" -f (Get-Item -LiteralPath $archivePath).Length)

    $extractPath = Join-Path $workRoot "extract"
    Write-SyncLog -Level Stage -Message "Extracting archive to $extractPath"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force -WhatIf:$false
    $remoteRoot = @(Get-ChildItem -LiteralPath $extractPath -Directory)
    if ($remoteRoot.Count -ne 1) {
        throw "Unexpected archive layout in '$extractPath'."
    }
    $remoteRoot = $remoteRoot[0].FullName
    Write-SyncLog -Level Success -Message "Extracted repository root: $remoteRoot"

    $remoteFiles = Get-FileInventory -Root $remoteRoot -Label "Repository"
    $localFiles = Get-FileInventory -Root $InstallRoot -Label "Installation"

    Write-SyncLog -Level Stage -Message "Comparing files (SHA256, line-ending normalised for text)"
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in ($remoteFiles.Keys | Sort-Object)) {
        $remoteHash = Get-NormalizedFileHash -Path $remoteFiles[$relativePath]
        $localHash = $null
        if ($localFiles.ContainsKey($relativePath)) {
            $localHash = Get-NormalizedFileHash -Path $localFiles[$relativePath]
        }

        $status = if ($null -eq $localHash) { "Missing" } elseif ($localHash -eq $remoteHash) { "Match" } else { "Modified" }
        if ($status -ne "Match" -and (Test-PathMatch -RelativePath $relativePath -ExactPaths $ProtectedPath)) {
            $status = "Protected"
        }
        Write-SyncLog -Level $status -Message $relativePath

        $results.Add([pscustomobject]@{
            RelativePath = $relativePath
            Status       = $status
            LocalHash    = $localHash
            RemoteHash   = $remoteHash
            Action       = ""
        })
    }

    foreach ($relativePath in ($localFiles.Keys | Where-Object { -not $remoteFiles.ContainsKey($_) } | Sort-Object)) {
        if (Test-PathMatch -RelativePath $relativePath -ExactPaths $ProtectedPath) {
            Write-SyncLog -Level Protected -Message "$relativePath (local only)"
            continue
        }
        Write-SyncLog -Level LocalOnly -Message $relativePath
        $results.Add([pscustomobject]@{
            RelativePath = $relativePath
            Status       = "LocalOnly"
            LocalHash    = Get-NormalizedFileHash -Path $localFiles[$relativePath]
            RemoteHash   = $null
            Action       = ""
        })
    }

    $delta = @($results | Where-Object { $_.Status -in @("Modified", "Missing") })

    $failedCount = 0

    if ($Apply -and $delta.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
            $BackupRoot = Join-Path $InstallRoot "_SyncBackup\$runStamp"
        }
        Write-SyncLog -Level Stage -Message "Applying $($delta.Count) change(s); backups go to $BackupRoot"

        foreach ($item in $delta) {
            $sourcePath = $remoteFiles[$item.RelativePath]
            $destinationPath = Join-Path $InstallRoot $item.RelativePath

            if (-not $PSCmdlet.ShouldProcess($destinationPath, "Update from $($repository.Repo)@$Branch")) {
                $item.Action = "Skipped"
                Write-SyncLog -Level Skipped -Message "$($item.RelativePath) (not confirmed)"
                continue
            }

            try {
                if (Test-Path -LiteralPath $destinationPath) {
                    $backupPath = Join-Path $BackupRoot $item.RelativePath
                    New-Item -Path (Split-Path $backupPath -Parent) -ItemType Directory -Force | Out-Null
                    Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Force
                    Write-SyncLog -Level Backup -Message "$($item.RelativePath) -> $backupPath"
                }

                New-Item -Path (Split-Path $destinationPath -Parent) -ItemType Directory -Force | Out-Null
                Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
                # Downloaded content carries Mark-of-the-Web, which blocks scripts under RemoteSigned.
                Unblock-File -LiteralPath $destinationPath -ErrorAction SilentlyContinue
                $item.Action = "Updated"
                Write-SyncLog -Level Updated -Message "$($item.RelativePath) ($($item.Status))"
            }
            catch {
                $failedCount++
                $item.Action = "Failed"
                Write-SyncLog -Level Error -Message "$($item.RelativePath): $($_.Exception.Message)"
            }
        }
    }

    Write-SyncLog -Level Stage -Message "Summary for $($repository.Owner)/$($repository.Repo)@$Branch"
    foreach ($group in ($results | Group-Object Status | Sort-Object Name)) {
        Write-SyncLog -Level $group.Name -Message ("{0,-10}: {1}" -f $group.Name, $group.Count)
    }

    if ($Apply -and $delta.Count -gt 0) {
        $updatedCount = @($delta | Where-Object { $_.Action -eq "Updated" }).Count
        $skippedCount = @($delta | Where-Object { $_.Action -eq "Skipped" }).Count
        Write-SyncLog -Level Info -Message "Updated: $updatedCount  Skipped: $skippedCount  Failed: $failedCount"
        Write-SyncLog -Level Backup -Message "Backup folder: $BackupRoot"
    }
    elseif ($delta.Count -gt 0) {
        Write-SyncLog -Level Warning -Message "Run again with -Apply to pull the $($delta.Count) changed file(s)."
    }
    else {
        Write-SyncLog -Level Success -Message "Operational files match the repository."
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
        Write-SyncLog -Level Success -Message "Report written: $([System.IO.Path]::GetFullPath($ReportPath))"
    }

    if ($failedCount -gt 0) {
        Write-SyncLog -Level Error -Message "Sync finished with $failedCount failure(s)."
    }
    else {
        Write-SyncLog -Level Success -Message "Sync finished."
    }

    if ($PassThru) {
        $results
    }
}
catch {
    Write-SyncLog -Level Error -Message "Sync aborted: $($_.Exception.Message)"
    Write-SyncLog -Level Error -Message "At: $($_.InvocationInfo.PositionMessage)"
    throw
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
        Write-SyncLog -Level Detail -Message "Removed working folder $workRoot"
    }
    Write-SyncLog -Level Detail -Message "Log saved to $LogPath"
}
