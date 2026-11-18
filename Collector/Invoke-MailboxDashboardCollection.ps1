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
.PARAMETER Collector
    ExchangeOnline (default) collects live Exchange statistics. Graph uses only Graph
    requests, an explicit GraphUserId/ExchangeGuid mapping, and delayed usage reports.
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
    [ValidateSet('ExchangeOnline', 'Graph')]
    [string]$Collector = 'ExchangeOnline',

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
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Modules\MailboxDashboard.Operations.psm1") -Force -DisableNameChecking

$script:StepResults = [System.Collections.Generic.List[object]]::new()
$pipelineParameters = $PSBoundParameters

function Set-CollectorCompletionMetadata {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CollectionProperty,
        [Parameter(Mandatory)][string]$TimestampUtc
    )

    $document = Read-MailboxJson -Path $Path
    if ($null -eq $document) {
        throw "Cannot record collector completion; file is missing or empty: $Path"
    }

    Add-Member -InputObject $document -NotePropertyName 'CollectorLastCompletedUtc' -NotePropertyValue $TimestampUtc -Force
    $records = Get-PropertyValueOrNull -Object $document -Name $CollectionProperty
    Write-MailboxJson -InputObject $document -Path $Path -Source 'MailboxDashboard collection completed' -RecordCount @($records).Count -Depth 100
}

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
$runFailed = $false
$partialCollection = $false
$runFailureSummary = $null
$notificationResult = $null
$connection = $null

$configParams = @{}
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configParams.ConfigPath = $ConfigPath }
if ($PSBoundParameters.ContainsKey('AuthenticationMode')) { $configParams.AuthenticationMode = $AuthenticationMode }

# Test data never touches Exchange, so credentials do not have to be valid for it.
$config = if ($TestData -or $Collector -eq 'Graph') {
    Import-MailboxDashboardConfig @configParams -SkipValidation
}
else {
    Import-MailboxDashboardConfig @configParams
}

if ($Collector -eq 'Graph' -and -not $TestData) {
    if ($Parallel -or $PSBoundParameters.ContainsKey('ThrottleLimit') -or
        $PSBoundParameters.ContainsKey('BatchSize') -or $KeepWorkerFiles) {
        throw "Graph collection uses paged requests and one atomic history write; omit -Parallel, -ThrottleLimit, -BatchSize, and -KeepWorkerFiles."
    }
    if ($PSBoundParameters.ContainsKey('AuthenticationMode') -and $AuthenticationMode -notin @('Certificate', 'Auto')) {
        throw "Graph collection supports app-only certificate/client-secret authentication, not '$AuthenticationMode'."
    }
    Test-MailboxDashboardConfig -Config $config -Collector Graph
    if (-not $PSCmdlet.ShouldProcess($config.ResolvedPaths.HistoryJson, "Collect Graph report data and rebuild the dashboard snapshot")) {
        return
    }
}

$historyPath = $config.ResolvedPaths.HistoryJson
$dataPath = $config.ResolvedPaths.DataJson
$workerDirectory = $config.ResolvedPaths.ThreadJobsDirectory
$collectionStatusPath = $config.ResolvedPaths.CollectionStatusJson
$alertStatePath = $config.ResolvedPaths.AlertStateJson
$partialCollection = ($null -ne $Identity -and $Identity.Count -gt 0)

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
    elseif ($Collector -eq 'Graph') {
        $null = Invoke-PipelineStep -Name "Collect (Graph)" -Action {
            $collectParams = @{ ConfigPath = $config.ConfigPath; Connect = $true }
            if ($pipelineParameters.ContainsKey('Identity')) { $collectParams.Identity = $Identity }
            & (Join-Path $PSScriptRoot "Collect-GraphMailboxes.ps1") @collectParams
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
            if ($pipelineParameters.ContainsKey('AuthenticationMode')) { $connectParams.Mode = $AuthenticationMode }
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

            $parallelResult = Invoke-PipelineStep -Name "Collect (parallel)" -Action {
                Invoke-ParallelCollection `
                    -Config $config `
                    -WorkerDirectory $workerDirectory `
                    -TotalMailboxes $total `
                    -Workers $effectiveThrottle `
                    -Timestamp $timestamp `
                    -CollectorPath (Join-Path -Path $PSScriptRoot -ChildPath "Collect-ExchangeOnlineMailboxes.ps1")
            }
            if ($parallelResult.Failed -gt 0) {
                $partialCollection = $true
                Write-Notice "Parallel collection produced partial results; mailboxes assigned to failed workers were not updated."
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
                if ($pipelineParameters.ContainsKey('BatchSize')) { $collectParams.BatchSize = $BatchSize }
                if ($pipelineParameters.ContainsKey('Identity')) { $collectParams.Identity = $Identity }

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
catch {
    $runFailed = $true
    $runFailureSummary = "Collection pipeline failed. See Collector/Logs/failures.log."
    throw
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
        $completedUtc = (Get-Date).ToUniversalTime().ToString("o")
        foreach ($target in @(
            @{ Path = $historyPath; CollectionProperty = 'MailboxHistory' },
            @{ Path = $dataPath; CollectionProperty = 'Mailboxes' }
        )) {
            try {
                Set-CollectorCompletionMetadata -Path $target.Path -CollectionProperty $target.CollectionProperty -TimestampUtc $completedUtc
            }
            catch {
                Write-Notice "Could not save collector completion to '$($target.Path)': $($_.Exception.Message)"
            }
        }
        Write-Success "Pipeline completed successfully."
    }
    else {
        Write-Notice "$($failedSteps.Count) step(s) failed - see the failure log."
        $runFailed = $true
        if ([string]::IsNullOrWhiteSpace($runFailureSummary)) {
            $runFailureSummary = "One or more pipeline steps failed. See Collector/Logs/failures.log."
        }
    }

    $runStatus = if ($runFailed) { "Failed" } elseif ($partialCollection) { "Partial" } else { "Succeeded" }
    $statusSteps = @(
        foreach ($step in $script:StepResults) {
            [pscustomobject]@{
                name            = $step.Step
                status          = $step.Status
                durationSeconds = [math]::Round($step.Duration.TotalSeconds, 3)
            }
        }
    )

    $collectionStatus = [pscustomobject]@{
        schemaVersion       = 1
        collector           = $Collector
        runId               = [guid]::NewGuid().ToString()
        status              = $runStatus
        startedUtc          = $pipelineStarted.ToUniversalTime().ToString("o")
        completedUtc        = (Get-Date).ToUniversalTime().ToString("o")
        durationSeconds     = [math]::Round($elapsed.TotalSeconds, 3)
        authenticationMode  = if ($TestData) { "TestData" } elseif ($Collector -eq 'Graph') { "Certificate" } elseif ($null -ne $connection) { [string]$connection.Mode } else { [string]$config.Authentication.Mode }
        testData            = [bool]$TestData
        partialCollection   = [bool]$partialCollection
        staleAfterMinutes   = [int]$config.Monitoring.StaleAfterMinutes
        steps               = $statusSteps
        failureSummary      = $runFailureSummary
        notification        = [pscustomobject]@{
            enabled         = [bool]$config.Notifications.Enabled
            deliveryStatus  = if ($config.Notifications.Enabled) { "Pending" } else { "Disabled" }
            transitionCount = 0
            errorSummary    = $null
        }
    }

    if ($config.Notifications.Enabled) {
        try {
            $notificationResult = Invoke-MailboxDashboardAlerting `
                -Config $config -CollectionStatus $collectionStatus `
                -DataPath $dataPath -StatePath $alertStatePath
            $collectionStatus.notification = [pscustomobject]@{
                enabled         = [bool]$notificationResult.Enabled
                deliveryStatus  = [string]$notificationResult.DeliveryStatus
                transitionCount = [int]$notificationResult.TransitionCount
                errorSummary    = $notificationResult.ErrorSummary
            }
        }
        catch {
            Write-FailureDiagnostic -ErrorRecord $_ -Context "MailboxDashboard alert orchestration"
            Write-Notice "Email alert processing failed; collection status was still recorded."
            $notificationResult = [pscustomobject]@{
                Enabled = $true; DeliveryStatus = "Failed"; TransitionCount = 0
                ErrorSummary = "Alert processing failed. See Collector/Logs/failures.log."
            }
            $collectionStatus.notification = [pscustomobject]@{
                enabled = $true; deliveryStatus = "Failed"; transitionCount = 0
                errorSummary = $notificationResult.ErrorSummary
            }
        }
    }

    try {
        Write-MailboxDashboardCollectionStatus -Status $collectionStatus -Path $collectionStatusPath
    }
    catch {
        Write-FailureDiagnostic -ErrorRecord $_ -Context "Writing collection status"
        if (-not $runFailed) {
            throw
        }
        Write-Notice "Collection status could not be saved; see the failure log."
    }
}

[pscustomobject]@{
    Steps        = @($script:StepResults)
    Failed       = @($script:StepResults | Where-Object { $_.Status -ne "OK" }).Count
    Elapsed      = (Get-Date) - $pipelineStarted
    HistoryPath  = $historyPath
    DataPath     = $dataPath
    StatusPath   = $collectionStatusPath
    Status       = $runStatus
    Notification = $notificationResult
    TimestampUtc = $timestamp
}
