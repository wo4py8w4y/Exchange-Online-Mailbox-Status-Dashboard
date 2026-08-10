<#
.SYNOPSIS
    Bootstraps parallel mailbox history collection with thread jobs.
.DESCRIPTION
    Splits the configured mailbox CSV into chunk files, acquires an Exchange
    Online access token when needed, starts one thread job per chunk, collects
    chunk output into temporary JSON files, and merges the results into the
    configured history.json when all jobs succeed.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json"),

    [Parameter()]
    [string]$UserPrincipalName,

    [Parameter()]
    [string]$AccessToken,

    [Parameter()]
    [string]$ClientSecret,

    [Parameter()]
    [string]$RedirectUri = "http://localhost:8400/",

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$CollectorScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath "HistoryCollector.ps1"),

    [Parameter()]
    [string]$TokenHelperPath = (Join-Path -Path $PSScriptRoot -ChildPath "Get-ExchangeOnlineAccessToken.ps1"),

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ChunkSize = 25,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ThrottleLimit = 4,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BatchSize = 50,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int]$MonitorIntervalSeconds = 5,
     
    [Parameter()]
    [switch]$KeepTempFiles,

    # Path to a retained run workspace from a previous partial run.
    # When supplied, the script skips chunks that already have output and
    # re-runs only the failed ones with the current access token.
    [Parameter()]
    [string]$ResumeFromRunRoot
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
        GeneratedUtc   = ""
        MailboxHistory = @()
    }
}

function Load-HistoryData {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-EmptyHistoryData
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "History file '$Path' was invalid. Reinitializing before merge."
        return New-EmptyHistoryData
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

function Merge-HistoryEntry {
    param(
        [Parameter(Mandatory)]
        [hashtable]$HistoryIndex,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[psobject]]$MailboxHistory,

        [Parameter(Mandatory)]
        $IncomingEntry
    )

    $exchangeGuid = [string]$IncomingEntry.ExchangeGuid
    if ([string]::IsNullOrWhiteSpace($exchangeGuid)) {
        throw "Encountered merged history entry without an ExchangeGuid."
    }

    if ($HistoryIndex.ContainsKey($exchangeGuid)) {
        $existingEntry = $HistoryIndex[$exchangeGuid]
        $sampleList = [System.Collections.Generic.List[psobject]]::new()

        if ($null -ne $existingEntry.Samples) {
            foreach ($sample in $existingEntry.Samples) {
                $sampleList.Add($sample)
            }
        }

        if ($null -ne $IncomingEntry.Samples) {
            foreach ($sample in $IncomingEntry.Samples) {
                $sampleList.Add($sample)
            }
        }

        $existingEntry.PrimarySmtpAddress = [string]$IncomingEntry.PrimarySmtpAddress
        $existingEntry.DisplayName = [string]$IncomingEntry.DisplayName
        $existingEntry.Samples = @($sampleList)
        return
    }

    $MailboxHistory.Add($IncomingEntry)
    $HistoryIndex[$exchangeGuid] = $IncomingEntry
}

function ConvertFrom-Base64UrlString {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $paddedValue = $Value.Replace('-', '+').Replace('_', '/')
    switch ($paddedValue.Length % 4) {
        2 { $paddedValue += "==" }
        3 { $paddedValue += "=" }
        0 { }
        default { throw "Invalid Base64Url payload length." }
    }

    return [System.Convert]::FromBase64String($paddedValue)
}

function Get-AccessTokenExpiryUtc {
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    $segments = $Token.Split('.')
    if ($segments.Count -lt 2) {
        throw "Access token is not a valid JWT."
    }

    $payloadBytes = ConvertFrom-Base64UrlString -Value $segments[1]
    $payloadJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
    $payload = $payloadJson | ConvertFrom-Json

    if (-not ($payload.PSObject.Properties.Name -contains "exp")) {
        throw "Access token payload does not contain an exp claim."
    }

    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$payload.exp).UtcDateTime
}

function Get-AccessTokenPayload {
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    $segments = $Token.Split('.')
    if ($segments.Count -lt 2) {
        throw "Access token is not a valid JWT."
    }

    $payloadBytes = ConvertFrom-Base64UrlString -Value $segments[1]
    $payloadJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
    return $payloadJson | ConvertFrom-Json
}

function Invoke-PartialMerge {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[psobject]]$ChunkMetadata,

        [Parameter(Mandatory)]
        [string]$HistoryJsonPath,

        [Parameter(Mandatory)]
        [string]$TimestampUtc
    )

    $mergedHistory = Load-HistoryData -Path $HistoryJsonPath
    $historyIndex = @{}
    $updatedMailboxHistory = [System.Collections.Generic.List[psobject]]::new()

    if ($null -ne $mergedHistory.MailboxHistory) {
        foreach ($entry in $mergedHistory.MailboxHistory) {
            $exchangeGuid = [string]$entry.ExchangeGuid
            if ([string]::IsNullOrWhiteSpace($exchangeGuid)) { continue }
            $updatedMailboxHistory.Add($entry)
            $historyIndex[$exchangeGuid] = $entry
        }
    }

    $mergedChunks = 0
    foreach ($chunk in $ChunkMetadata) {
        if (-not (Test-Path -LiteralPath $chunk.OutputPath)) { continue }
        $chunkHistory = Load-HistoryData -Path $chunk.OutputPath
        if ($null -eq $chunkHistory.MailboxHistory) { continue }
        foreach ($incomingEntry in $chunkHistory.MailboxHistory) {
            Merge-HistoryEntry -HistoryIndex $historyIndex -MailboxHistory $updatedMailboxHistory -IncomingEntry $incomingEntry
        }
        $mergedChunks++
    }

    if ($mergedChunks -gt 0) {
        $partialHistory = [pscustomobject]@{
            GeneratedUtc   = $TimestampUtc
            MailboxHistory = @($updatedMailboxHistory)
        }
        Write-JsonSafe -InputObject $partialHistory -Path $HistoryJsonPath -Depth 100
    }

    return $mergedChunks
}

function Get-ChunkLabel {
    param(
        [Parameter(Mandatory)]
        [int]$ChunkNumber
    )

    return "Chunk {0:d4}" -f $ChunkNumber
}

$resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Configuration file not found at '$resolvedConfigPath'."
}

$collectorPath = Resolve-AbsolutePath -Path $CollectorScriptPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $collectorPath)) {
    throw "Collector script not found at '$collectorPath'."
}

$tokenScriptPath = Resolve-AbsolutePath -Path $TokenHelperPath -BaseDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $tokenScriptPath)) {
    throw "Token helper script not found at '$tokenScriptPath'."
}

Import-Module Microsoft.PowerShell.ThreadJob -ErrorAction Stop
Import-Module ExchangeOnlineManagement -ErrorAction Stop

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$configDirectory = Split-Path -Path $resolvedConfigPath -Parent
$configBaseDirectory = Split-Path -Path $configDirectory -Parent
$resolvedUserPrincipalName = if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) { [string]$config.UserPrincipalName } else { $UserPrincipalName }
$resolvedOrganization = [string]$config.Organization

# Config paths are stored relative to the Collector folder (legacy behavior),
# not the Config subfolder that contains dashboardConfig.json.
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
$resolvedCsvPath = Resolve-AbsolutePath -Path $configuredCsvPath -BaseDirectory $configBaseDirectory
$resolvedHistoryJsonPath = Resolve-AbsolutePath -Path $configuredHistoryJsonPath -BaseDirectory $configBaseDirectory

if (-not (Test-Path -LiteralPath $resolvedCsvPath)) {
    $defaultCsvPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "Mailboxes\mailboxes.csv"
    if (Test-Path -LiteralPath $defaultCsvPath) {
        Write-Warning "Configured CsvPath '$configuredCsvPath' was not found at '$resolvedCsvPath'. Falling back to '$defaultCsvPath'."
        $resolvedCsvPath = $defaultCsvPath
    }
    else {
        throw "Configured CsvPath '$configuredCsvPath' was not found at '$resolvedCsvPath', and fallback path '$defaultCsvPath' does not exist."
    }
}

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    $AccessToken = & $tokenScriptPath `
        -ConfigPath $resolvedConfigPath `
        -UserPrincipalName $resolvedUserPrincipalName `
        -RedirectUri $RedirectUri `
        -AuthenticationMode Delegated `
        -ClientSecret $ClientSecret
}

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    throw "Access token generation returned no token."
}

$tokenPayload = Get-AccessTokenPayload -Token $AccessToken
$tokenScopes = @()
if ($tokenPayload.PSObject.Properties.Name -contains "scp" -and -not [string]::IsNullOrWhiteSpace([string]$tokenPayload.scp)) {
    $tokenScopes = @(([string]$tokenPayload.scp) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if (($tokenPayload.PSObject.Properties.Name -contains "roles") -and -not ($tokenPayload.PSObject.Properties.Name -contains "scp")) {
    throw "The supplied access token appears to be an app-only token (roles claim present, scp claim missing). This collector is configured for delegated Exchange.Manage access. Omit -AccessToken and let the script acquire a delegated token, or update the app registration and auth flow for app-only Exchange access."
}

$requiredDelegatedScope = "Exchange.Manage"
if ($tokenScopes.Count -gt 0 -and -not ($tokenScopes -contains $requiredDelegatedScope)) {
    throw "The supplied access token is delegated but does not include the required '$requiredDelegatedScope' scope. Token scopes: $($tokenScopes -join ', ')."
}

$tokenExpiryUtc = Get-AccessTokenExpiryUtc -Token $AccessToken
if ($tokenExpiryUtc -le (Get-Date).ToUniversalTime().AddMinutes(5)) {
    throw "Access token expires too soon for threaded collection. Token expiry: $($tokenExpiryUtc.ToString('o'))."
}

if ([string]::IsNullOrWhiteSpace($resolvedOrganization) -and [string]::IsNullOrWhiteSpace($resolvedUserPrincipalName)) {
    throw "Organization or UserPrincipalName must be populated in config or passed as a parameter."
}

$connectionMode = "token"

# --- Resume or fresh run setup ---

$isResume = -not [string]::IsNullOrWhiteSpace($ResumeFromRunRoot)

if ($isResume) {
    $runRoot = [System.IO.Path]::GetFullPath($ResumeFromRunRoot)
    if (-not (Test-Path -LiteralPath $runRoot)) {
        throw "ResumeFromRunRoot path '$runRoot' does not exist."
    }
    $manifestPath = Join-Path -Path $runRoot -ChildPath "run-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "No run-manifest.json found in '$runRoot'. Cannot resume — was this created by a previous run of this script?"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $timestampUtc = [string]$manifest.TimestampUtc
    if ([string]::IsNullOrWhiteSpace($resolvedHistoryJsonPath)) {
        $resolvedHistoryJsonPath = [string]$manifest.ResolvedHistoryJsonPath
    }
    $chunkRoot  = Join-Path -Path $runRoot -ChildPath "Chunks"
    $outputRoot = Join-Path -Path $runRoot -ChildPath "Output"
    $logRoot    = Join-Path -Path $runRoot -ChildPath "Logs"
    if (-not (Test-Path -LiteralPath $logRoot)) {
        New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
    }
}
else {
    $mailboxes = @(Import-Csv -LiteralPath $resolvedCsvPath)
    if ($mailboxes.Count -eq 0) {
        Write-Warning "No mailbox rows were found in '$resolvedCsvPath'. Nothing to collect."
        return
    }

    $mailboxColumns = @($mailboxes[0].PSObject.Properties.Name)
    if (-not ($mailboxColumns -contains "PrimarySMTPAddress")) {
        throw "Mailbox CSV '$resolvedCsvPath' must contain a 'PrimarySMTPAddress' column. Found columns: $($mailboxColumns -join ', ')."
    }

    $timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
    $runRootMarker = New-TemporaryFile
    Remove-Item -LiteralPath $runRootMarker.FullName -Force
    $runRoot    = $runRootMarker.FullName
    $chunkRoot  = Join-Path -Path $runRoot -ChildPath "Chunks"
    $outputRoot = Join-Path -Path $runRoot -ChildPath "Output"
    $logRoot    = Join-Path -Path $runRoot -ChildPath "Logs"

    New-Item -Path $runRoot    -ItemType Directory -Force | Out-Null
    New-Item -Path $chunkRoot  -ItemType Directory -Force | Out-Null
    New-Item -Path $outputRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $logRoot    -ItemType Directory -Force | Out-Null
}

$jobs = @()
$chunkMetadata = [System.Collections.Generic.List[psobject]]::new()
$retainRunFiles = $KeepTempFiles.IsPresent

Write-Host "Resolved config: $resolvedConfigPath" -ForegroundColor DarkCyan
if (-not $isResume) {
    Write-Host "Mailbox CSV: $resolvedCsvPath" -ForegroundColor DarkCyan
}
Write-Host "History JSON: $resolvedHistoryJsonPath" -ForegroundColor DarkCyan
Write-Host "Run workspace: $runRoot" -ForegroundColor DarkCyan
if ($tokenScopes.Count -gt 0) {
    Write-Host "Token type: delegated | scopes: $($tokenScopes -join ', ') | expires: $($tokenExpiryUtc.ToString('o'))" -ForegroundColor DarkCyan
}
else {
    Write-Host "Token type: delegated | expires: $($tokenExpiryUtc.ToString('o'))" -ForegroundColor DarkCyan
}

try {
    if ($isResume) {
        # Reconstruct chunk metadata from manifest, skipping chunks that already succeeded.
        foreach ($c in $manifest.ChunkMetadata) {
            $chunkCsvPath    = [string]$c.CsvPath
            $chunkOutputPath = [string]$c.OutputPath
            $chunkLogPath    = [string]$c.LogPath
            $chunkNum        = [int]$c.ChunkNumber

            if (-not (Test-Path -LiteralPath $chunkCsvPath)) {
                Write-Warning "Resume: chunk CSV '$chunkCsvPath' not found — skipping chunk $chunkNum."
                continue
            }

            if (Test-Path -LiteralPath $chunkOutputPath) {
                Write-Host "  [SKIP] Chunk $chunkNum already has output — skipping." -ForegroundColor DarkGray
                continue
            }

            # Fresh log for the retry.
            $chunkLogPath = Join-Path -Path $logRoot -ChildPath ("history-{0:d4}.log" -f $chunkNum)

            $chunkMetadata.Add([pscustomobject]@{
                ChunkNumber = $chunkNum
                JobName     = [string]$c.JobName
                CsvPath     = $chunkCsvPath
                OutputPath  = $chunkOutputPath
                LogPath     = $chunkLogPath
                StartIndex  = [int]$c.StartIndex
                EndIndex    = [int]$c.EndIndex
            })
        }

        if ($chunkMetadata.Count -eq 0) {
            Write-Host "`nAll chunks already have output. Merging and writing final history.json.`n" -ForegroundColor Green
            $allChunks = [System.Collections.Generic.List[psobject]]::new()
            foreach ($c in $manifest.ChunkMetadata) {
                $allChunks.Add([pscustomobject]@{
                    ChunkNumber = [int]$c.ChunkNumber
                    JobName     = [string]$c.JobName
                    CsvPath     = [string]$c.CsvPath
                    OutputPath  = [string]$c.OutputPath
                    LogPath     = [string]$c.LogPath
                    StartIndex  = [int]$c.StartIndex
                    EndIndex    = [int]$c.EndIndex
                })
            }
            $null = Invoke-PartialMerge -ChunkMetadata $allChunks -HistoryJsonPath $resolvedHistoryJsonPath -TimestampUtc $timestampUtc
            Write-Host "[SUCCESS] Final history.json written from resumed run." -ForegroundColor Green
            return
        }

        Write-Host "Resuming: $($chunkMetadata.Count) chunk(s) remaining." -ForegroundColor Yellow
    }
    else {
        $chunkNumber = 0
        for ($startIndex = 0; $startIndex -lt $mailboxes.Count; $startIndex += $ChunkSize) {
            $chunkNumber++
            $endIndex = [Math]::Min($startIndex + $ChunkSize - 1, $mailboxes.Count - 1)
            $chunkRows = @($mailboxes[$startIndex..$endIndex])
            $chunkCsvPath    = Join-Path -Path $chunkRoot -ChildPath ("mailboxes-{0:d4}.csv" -f $chunkNumber)
            $chunkOutputPath = Join-Path -Path $outputRoot -ChildPath ("history-{0:d4}.json" -f $chunkNumber)
            $chunkLogPath    = Join-Path -Path $logRoot    -ChildPath ("history-{0:d4}.log"  -f $chunkNumber)

            $chunkRows | Export-Csv -LiteralPath $chunkCsvPath -NoTypeInformation

            $chunkMetadata.Add([pscustomobject]@{
                ChunkNumber = $chunkNumber
                JobName     = "MailboxHistory-$('{0:d4}' -f $chunkNumber)"
                CsvPath     = $chunkCsvPath
                OutputPath  = $chunkOutputPath
                LogPath     = $chunkLogPath
                StartIndex  = $startIndex + 1
                EndIndex    = $endIndex + 1
            })
        }

        # Write manifest so this run can be resumed if the token expires.
        $manifestPath = Join-Path -Path $runRoot -ChildPath "run-manifest.json"
        [pscustomobject]@{
            TimestampUtc             = $timestampUtc
            ResolvedHistoryJsonPath  = $resolvedHistoryJsonPath
            ChunkMetadata            = @($chunkMetadata)
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        # Warn if the token is likely to expire before all chunks finish.
        $tokenMinutesRemaining = [Math]::Floor(($tokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes)
        $estimatedMinutes = [Math]::Ceiling($chunkMetadata.Count / $ThrottleLimit) * 2
        if ($tokenMinutesRemaining -lt ($estimatedMinutes + 10)) {
            Write-Warning ("Token expires in {0} minute(s). Estimated run time is ~{1} minute(s) with ThrottleLimit {2}. " +
                "The token may expire before all chunks complete. If that happens, re-run with: " +
                "-ResumeFromRunRoot '{3}' (and a fresh -AccessToken or omit -AccessToken to re-authenticate).") `
                -f $tokenMinutesRemaining, $estimatedMinutes, $ThrottleLimit, $runRoot
        }
    }

    Write-Host "Starting $($chunkMetadata.Count) thread job(s) with throttle $ThrottleLimit..." -ForegroundColor Cyan

    foreach ($chunk in $chunkMetadata) {
        $jobName = [string]$chunk.JobName
        $chunkLabel = Get-ChunkLabel -ChunkNumber $chunk.ChunkNumber

        $jobs += Start-ThreadJob -Name $jobName -ThrottleLimit $ThrottleLimit -StreamingHost $Host -InitializationScript {
            Import-Module ExchangeOnlineManagement -ErrorAction Stop
        } -ArgumentList @(
            $collectorPath,
            $resolvedConfigPath,
            $chunk.CsvPath,
            $chunk.OutputPath,
            $BatchSize,
            $timestampUtc,
            $AccessToken,
            $connectionMode,
            $resolvedOrganization,
            $resolvedUserPrincipalName,
            $chunk.ChunkNumber,
            $chunkLabel,
            $chunk.LogPath,
            ($VerbosePreference -eq "Continue")
        ) -ScriptBlock {
            param(
                [string]$CollectorPath,
                [string]$ResolvedConfigPath,
                [string]$ChunkCsvPath,
                [string]$ChunkOutputPath,
                [int]$CollectorBatchSize,
                [string]$RunTimestampUtc,
                [string]$ThreadAccessToken,
                [string]$ThreadConnectionMode,
                [string]$ThreadOrganization,
                [string]$ThreadUserPrincipalName,
                [int]$ThreadChunkNumber,
                [string]$ThreadChunkLabel,
                [string]$ThreadLogPath,
                [bool]$ThreadVerboseEnabled
            )
  
            Set-StrictMode -Version Latest
            $ErrorActionPreference = "Stop"

            function Write-WorkerLog {
                param(
                    [Parameter(Mandatory)]
                    [string]$Message,

                    [Parameter()]
                    [ValidateSet("INFO", "WARN", "ERROR")]
                    [string]$Level = "INFO"
                )

                $timestamp = (Get-Date).ToUniversalTime().ToString("o")
                $line = "$timestamp [$ThreadChunkLabel] [$Level] $Message"
                Add-Content -LiteralPath $ThreadLogPath -Value $line

                switch ($Level) {
                    "WARN" { Write-Warning $line }
                    "ERROR" { Write-Host $line -ForegroundColor Red }
                    default { Write-Host $line -ForegroundColor DarkGray }
                }
            }

            $connectParams = @{
                AccessToken = $ThreadAccessToken
                ShowBanner  = $false
                ErrorAction = "Stop"
            }

            if (-not [string]::IsNullOrWhiteSpace($ThreadOrganization)) {
                $connectParams.Organization = $ThreadOrganization
            }
            elseif (-not [string]::IsNullOrWhiteSpace($ThreadUserPrincipalName)) {
                $connectParams.UserPrincipalName = $ThreadUserPrincipalName
            }
            else {
                throw "Organization or UserPrincipalName must be provided in config or parameters when using AccessToken."
            }

            try {
                Write-WorkerLog -Message "Starting worker for mailbox rows in '$ChunkCsvPath'."
                Write-WorkerLog -Message "Connecting to Exchange Online."
                Connect-ExchangeOnline @connectParams
                Write-WorkerLog -Message "Exchange Online connection established."

                & $CollectorPath `
                    -ConfigPath $ResolvedConfigPath `
                    -CsvPath $ChunkCsvPath `
                    -HistoryJsonPath $ChunkOutputPath `
                    -BatchSize $CollectorBatchSize `
                    -TimestampUtc $RunTimestampUtc `
                    -Verbose:$ThreadVerboseEnabled *>&1 |
                    ForEach-Object {
                        $messageText = [string]$_
                        if (-not [string]::IsNullOrWhiteSpace($messageText)) {
                            Write-WorkerLog -Message $messageText
                        }
                    }

                Write-WorkerLog -Message "Worker completed successfully."
            }
            catch {
                Write-WorkerLog -Level "ERROR" -Message $_.Exception.Message
                throw
            }
            finally {
                try {
                    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-WorkerLog -Message "Disconnected from Exchange Online."
                }
                catch {
                    Write-WorkerLog -Level "WARN" -Message "Disconnect-ExchangeOnline reported: $($_.Exception.Message)"
                }
            }
        }
    }

    while ($true) {
        $jobSnapshot = @($jobs)
        $pendingJobs = @($jobSnapshot | Where-Object { $_.State -in @("NotStarted", "Running") })
        $completedCount = @($jobSnapshot | Where-Object { $_.State -eq "Completed" }).Count
        $failedCount = @($jobSnapshot | Where-Object { $_.State -in @("Failed", "Stopped", "Suspended") }).Count

        $percentComplete = if ($jobSnapshot.Count -gt 0) {
            [int](($completedCount + $failedCount) * 100 / $jobSnapshot.Count)
        }
        else {
            100
        }

        Write-Progress -Activity "Collecting mailbox history" -Status "$completedCount/$($jobSnapshot.Count) completed, $failedCount failed, $($pendingJobs.Count) active" -PercentComplete $percentComplete

        if ($pendingJobs.Count -eq 0) {
            break
        }

        $completedJob = Wait-Job -Job $pendingJobs -Any -Timeout $MonitorIntervalSeconds
        if ($null -ne $completedJob) {
            Receive-Job -Job $completedJob -Keep -ErrorAction Continue | Out-Null
            $color = if ($completedJob.State -eq "Completed") { "Green" } else { "Red" }
            Write-Host "[Monitor] $($completedJob.Name) finished with state $($completedJob.State)." -ForegroundColor $color
        }
    }

    Write-Progress -Activity "Collecting mailbox history" -Completed

    $jobFailures = @(
        foreach ($job in $jobs) {
            Receive-Job -Job $job -Keep -ErrorAction Continue | Out-Null
            if ($job.State -ne "Completed") {
                $reasonMessage = "Unknown job failure."
                $chunk = $chunkMetadata | Where-Object { $_.JobName -eq $job.Name } | Select-Object -First 1
                if ($job.ChildJobs.Count -gt 0) {
                    $reason = $job.ChildJobs[0].JobStateInfo.Reason
                    if ($null -ne $reason -and -not [string]::IsNullOrWhiteSpace([string]$reason.Message)) {
                        $reasonMessage = [string]$reason.Message
                    }

                    $jobErrors = @($job.ChildJobs[0].Error | ForEach-Object { $_.ToString() }) -join " | "
                    if (-not [string]::IsNullOrWhiteSpace($jobErrors)) {
                        $reasonMessage = "$reasonMessage; $jobErrors"
                    }
                }

                [pscustomobject]@{
                    Name    = $job.Name
                    Reason  = $reasonMessage
                    LogPath = if ($null -ne $chunk) { [string]$chunk.LogPath } else { "" }
                }
            }
        }
    )

    # Build the full metadata list for merging (resume runs only queued the failed chunks).
    $allChunkMetadata = $chunkMetadata
    if ($isResume) {
        $allChunkMetadata = [System.Collections.Generic.List[psobject]]::new()
        foreach ($c in $manifest.ChunkMetadata) {
            $allChunkMetadata.Add([pscustomobject]@{
                ChunkNumber = [int]$c.ChunkNumber
                JobName     = [string]$c.JobName
                CsvPath     = [string]$c.CsvPath
                OutputPath  = [string]$c.OutputPath
                LogPath     = [string]$c.LogPath
                StartIndex  = [int]$c.StartIndex
                EndIndex    = [int]$c.EndIndex
            })
        }
    }

    # Always merge whatever completed chunks we have so work isn't lost.
    $mergedCount = Invoke-PartialMerge -ChunkMetadata $allChunkMetadata -HistoryJsonPath $resolvedHistoryJsonPath -TimestampUtc $timestampUtc

    if ($jobFailures.Count -gt 0) {
        $retainRunFiles = $true
        $failedJobCount = $jobFailures.Count
        $failureSummary = ($jobFailures | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_.LogPath)) {
                "$($_.Name): $($_.Reason)"
            }
            else {
                "$($_.Name): $($_.Reason) (log: $($_.LogPath))"
            }
        }) -join "; "

        Write-Warning ("$mergedCount/$($allChunkMetadata.Count) completed chunks have been merged into '$resolvedHistoryJsonPath'. " +
            "$failedJobCount chunk(s) failed. To retry only the failed chunks with a fresh token, run:`n" +
            "  .\Start-HistoryCollectorThreaded.ps1 -ResumeFromRunRoot '$runRoot'")

        throw "One or more thread jobs failed. Partial results saved. $failureSummary"
    }

    Write-Host "`n[SUCCESS] Threaded collection completed cleanly at $timestampUtc. $mergedCount chunk(s) merged into '$resolvedHistoryJsonPath'.`n" -ForegroundColor Green
}
catch {
    $retainRunFiles = $true
    throw
}
finally {
    if ($jobs.Count -gt 0) {
        foreach ($job in $jobs) {
            try {
                Remove-Job -Id $job.Id -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Remove-Job reported for '$($job.Name)': $($_.Exception.Message)"
            }
        }
    }

    if ((-not $retainRunFiles) -and (Test-Path -LiteralPath $runRoot)) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
    elseif (Test-Path -LiteralPath $runRoot) {
        Write-Host "Temporary run files retained at '$runRoot'." -ForegroundColor Yellow
    }
}
