<#
.SYNOPSIS
    Runs the full MailboxDashboard collection pipeline.
.DESCRIPTION
    Chains the individual steps into one operation:

        authenticate -> collect -> merge -> validate -> snapshot -> validate

    Each step is a standalone script that can also be run on its own; this orchestrator
    only sequences them and reports the result.

    Collection is sequential by default, which needs a single Exchange Online session.
    -Parallel splits the mailbox list across worker threads, each opening its own
    app-only session, so it requires certificate or client-secret authentication.
.PARAMETER TestData
    Skips Exchange entirely and builds the dashboard from generated data. Useful for
    verifying a deployment before credentials are in place.
.PARAMETER Repair
    Lets the validation steps fix recoverable records instead of only reporting them.
.EXAMPLE
    .\Invoke-MailboxDashboardCollection.ps1
    Full run using the authentication mode in the configuration.
.EXAMPLE
    .\Invoke-MailboxDashboardCollection.ps1 -Parallel -ThrottleLimit 8
    App-only run with eight workers.
.EXAMPLE
    .\Invoke-MailboxDashboardCollection.ps1 -TestData
    Builds the dashboard from synthetic data without contacting Exchange.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('Certificate', 'Interactive', 'Delegated', 'Auto')]
    [string]$AuthenticationMode,

    [Parameter()]
    [switch]$Parallel,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BatchSize,

    [Parameter()]
    [string[]]$Identity,

    [Parameter()]
    [switch]$TestData,

    [Parameter()]
    [switch]$Repair,

    [Parameter()]
    [switch]$SkipValidation,

    [Parameter()]
    [switch]$KeepWorkerFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Config.psm1") -Force -DisableNameChecking

$script:StepResults = [System.Collections.Generic.List[object]]::new()

function Invoke-PipelineStep {
<#
.SYNOPSIS
    Runs one pipeline step, recording its outcome and duration.
#>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Parameter()] [switch]$ContinueOnFailure
    )

    $started = Get-Date
    $status = "OK"
    $result = $null

    try {
        $result = & $Action
    }
    catch {
        $status = "FAILED"
        Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0) -Context "Pipeline step: $Name"

        if (-not $ContinueOnFailure) {
            $script:StepResults.Add([pscustomobject]@{
                Step = $Name; Status = $status; Duration = ((Get-Date) - $started); Result = $null
            })
            throw
        }
    }

    $script:StepResults.Add([pscustomobject]@{
        Step     = $Name
        Status   = $status
        Duration = ((Get-Date) - $started)
        Result   = $result
    })

    return $result
}

function Get-MailboxCountFromCsv {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Mailbox CSV not found at '$Path'."
    }

    return @(Import-Csv -LiteralPath $Path).Count
}

function Invoke-ParallelCollection {
<#
.SYNOPSIS
    Splits the mailbox list across worker threads, each writing its own output file.
.DESCRIPTION
    Every worker opens its own app-only Exchange Online session, so this path is only
    valid for certificate or client-secret authentication. Workers never write to
    history.json directly; Merge-CollectionResults.ps1 combines their output afterwards.
#>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$WorkerDirectory,
        [Parameter(Mandatory)] [int]$TotalMailboxes,
        [Parameter(Mandatory)] [int]$Workers,
        [Parameter(Mandatory)] [string]$Timestamp,
        [Parameter(Mandatory)] [string]$CollectorPath
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.ThreadJob)) {
        throw "Parallel collection needs the Microsoft.PowerShell.ThreadJob module. Run: Install-Module Microsoft.PowerShell.ThreadJob -Scope CurrentUser"
    }

    Import-Module -Name Microsoft.PowerShell.ThreadJob -ErrorAction Stop

    $sliceSize = [math]::Ceiling($TotalMailboxes / $Workers)
    Write-Detail "Splitting $TotalMailboxes mailbox(es) across $Workers worker(s), $sliceSize each."

    $jobs = @()
    for ($worker = 0; $worker -lt $Workers; $worker++) {
        $skip = $worker * $sliceSize
        if ($skip -ge $TotalMailboxes) { break }

        $outputPath = Join-Path -Path $WorkerDirectory -ChildPath ("worker-{0:D2}.json" -f $worker)

        $jobs += Start-ThreadJob -Name "collector-$worker" -ScriptBlock {
            param($script, $configPath, $skip, $take, $out, $timestamp)

            & $script -ConfigPath $configPath -Skip $skip -First $take -OutputPath $out `
                -TimestampUtc $timestamp -Connect -AuthenticationMode Certificate
        } -ArgumentList $CollectorPath, $Config.ConfigPath, $skip, $sliceSize, $outputPath, $Timestamp
    }

    Write-Detail "Started $($jobs.Count) worker(s); waiting for completion."

    $completed = 0
    $failed = 0

    foreach ($job in $jobs) {
        $null = Wait-Job -Job $job

        if ($job.State -eq 'Failed') {
            $failed++
            Write-Notice "$($job.Name) failed: $($job.JobStateInfo.Reason.Message)"
        }
        else {
            $completed++
            Receive-Job -Job $job | Out-Null
            Write-Item -Name $job.Name -Index $completed -Total $jobs.Count
        }

        Remove-Job -Job $job -Force
    }

    if ($completed -eq 0) {
        throw "Every collection worker failed; nothing was collected."
    }

    if ($failed -gt 0) {
        Write-Notice "$failed of $($jobs.Count) worker(s) failed - the merge will use what succeeded."
    }

    return [pscustomobject]@{ Workers = $jobs.Count; Completed = $completed; Failed = $failed }
}

# --- Entry point -------------------------------------------------------------

$pipelineStarted = Get-Date

$configParams = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $configParams.AuthenticationMode = $AuthenticationMode }

# Test data never touches Exchange, so credentials do not have to be valid for it.
$config = if ($TestData) {
    Import-MailboxDashboardConfig @configParams -SkipValidation
}
else {
    Import-MailboxDashboardConfig @configParams
}

$historyPath = $config.ResolvedPaths.HistoryJson
$dataPath = $config.ResolvedPaths.DataJson
$workerDirectory = $config.ResolvedPaths.ThreadJobsDirectory

$effectiveThrottle = if ($PSBoundParameters.ContainsKey('ThrottleLimit')) { $ThrottleLimit } else { [int]$config.Collection.ThreadCount }
$timestamp = (Get-Date).ToUniversalTime().ToString("o")

Write-ConsoleLine ""
Write-ConsoleLine -Message "  MailboxDashboard collection pipeline" -Colour Cyan
Write-Detail "Configuration: $($config.ConfigPath)"
Write-Detail "Started: $timestamp"

if ($TestData) {
    Write-Attention "Test-data mode: Exchange Online will not be contacted."
}

try {
    if ($TestData) {
        $null = Invoke-PipelineStep -Name "Generate test data" -Action {
            & (Join-Path -Path $PSScriptRoot -ChildPath "New-MailboxDashboardTestData.ps1") `
                -ConfigPath $config.ConfigPath -Live
        }
    }
    else {
        $authMode = [string]$config.Authentication.Mode

        if ($Parallel -and $authMode -notin @('Certificate', 'Auto')) {
            throw "Parallel collection requires certificate or client-secret authentication; the configured mode is '$authMode'. Run without -Parallel, or set Authentication.Mode to Certificate."
        }

        $connection = Invoke-PipelineStep -Name "Authenticate" -Action {
            . (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-MailboxDashboardAuth.ps1")
            $connectParams = @{ Config = $config }
            if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $connectParams.Mode = $AuthenticationMode }
            Connect-MailboxDashboard @connectParams
        }

        if ($Parallel -and $connection.Mode -ne 'Certificate') {
            throw "Parallel collection needs an app-only session, but the connection used '$($connection.Mode)'."
        }

        if ($Parallel) {
            $csvPath = $config.ResolvedPaths.MailboxesCsv
            $total = Get-MailboxCountFromCsv -Path $csvPath

            Write-Stage "Collecting mailboxes (parallel)"

            if (Test-Path -LiteralPath $workerDirectory) {
                Get-ChildItem -LiteralPath $workerDirectory -Filter "worker-*.json" -File |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
            else {
                $null = New-Item -Path $workerDirectory -ItemType Directory -Force
            }

            $null = Invoke-PipelineStep -Name "Collect (parallel)" -Action {
                Invoke-ParallelCollection `
                    -Config $config `
                    -WorkerDirectory $workerDirectory `
                    -TotalMailboxes $total `
                    -Workers $effectiveThrottle `
                    -Timestamp $timestamp `
                    -CollectorPath (Join-Path -Path $PSScriptRoot -ChildPath "Collect-ExchangeOnlineMailboxes.ps1")
            }

            $null = Invoke-PipelineStep -Name "Merge worker output" -Action {
                $mergeParams = @{
                    ConfigPath      = $config.ConfigPath
                    InputPath       = $workerDirectory
                    Filter          = "worker-*.json"
                    RemoveProcessed = (-not $KeepWorkerFiles)
                }
                & (Join-Path -Path $PSScriptRoot -ChildPath "Merge-CollectionResults.ps1") @mergeParams
            }
        }
        else {
            $null = Invoke-PipelineStep -Name "Collect" -Action {
                $collectParams = @{
                    ConfigPath   = $config.ConfigPath
                    TimestampUtc = $timestamp
                }
                if ($PSBoundParameters.ContainsKey('BatchSize')) { $collectParams.BatchSize = $BatchSize }
                if ($PSBoundParameters.ContainsKey('Identity')) { $collectParams.Identity = $Identity }

                & (Join-Path -Path $PSScriptRoot -ChildPath "Collect-ExchangeOnlineMailboxes.ps1") @collectParams
            }
        }
    }

    if (-not $SkipValidation) {
        $null = Invoke-PipelineStep -Name "Validate history" -ContinueOnFailure -Action {
            $validateParams = @{
                ConfigPath = $config.ConfigPath
                Target     = 'History'
            }
            if ($Repair) {
                $validateParams.Repair = $true
                $validateParams.Cull = $true
            }
            & (Join-Path -Path $PSScriptRoot -ChildPath "Test-MailboxDashboardJSON.ps1") @validateParams
        }
    }

    $null = Invoke-PipelineStep -Name "Generate snapshot" -Action {
        & (Join-Path -Path $PSScriptRoot -ChildPath "Generate-MailboxSnapshot.ps1") -ConfigPath $config.ConfigPath
    }

    if (-not $SkipValidation) {
        $null = Invoke-PipelineStep -Name "Validate snapshot" -ContinueOnFailure -Action {
            & (Join-Path -Path $PSScriptRoot -ChildPath "Test-MailboxDashboardJSON.ps1") -ConfigPath $config.ConfigPath -Target Data
        }
    }
}
finally {
    $elapsed = (Get-Date) - $pipelineStarted

    Write-Stage "Pipeline summary"

    foreach ($step in $script:StepResults) {
        $line = "{0,-22} {1,-7} {2}" -f $step.Step, $step.Status, $step.Duration.ToString("hh\:mm\:ss")
        if ($step.Status -eq "OK") {
            Write-ConsoleLine -Message "  $line" -Colour Green
        }
        else {
            Write-ConsoleLine -Message "  $line" -Colour Red
        }
    }

    Write-Detail "Total elapsed: $($elapsed.ToString('hh\:mm\:ss'))"
    Write-Detail "History: $historyPath"
    Write-Detail "Data   : $dataPath"

    $failedSteps = @($script:StepResults | Where-Object { $_.Status -ne "OK" })
    if ($failedSteps.Count -eq 0) {
        Write-Success "Pipeline completed successfully."
    }
    else {
        Write-Notice "$($failedSteps.Count) step(s) failed - see the failure log."
    }
}

[pscustomobject]@{
    Steps        = @($script:StepResults)
    Failed       = @($script:StepResults | Where-Object { $_.Status -ne "OK" }).Count
    Elapsed      = (Get-Date) - $pipelineStarted
    HistoryPath  = $historyPath
    DataPath     = $dataPath
    TimestampUtc = $timestamp
}
