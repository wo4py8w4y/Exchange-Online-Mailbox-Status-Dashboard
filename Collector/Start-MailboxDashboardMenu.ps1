<#
.SYNOPSIS
    Opens a contextual operator menu for MailboxDashboard collection and data workflows.
.DESCRIPTION
    Only shows actions whose scripts, configuration, and required inputs are available.
    Live-data replacements and repairs require typing YES before any write occurs.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:CollectorRoot = $PSScriptRoot
$script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$script:ConfigModulePath = Join-Path $PSScriptRoot "Modules\MailboxDashboard.Config.psm1"
Import-Module -Name $script:ConfigModulePath -Force -DisableNameChecking
Import-Module -Name (Join-Path $PSScriptRoot "Modules\MailboxDashboard.Common.psm1") -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "Config\dashboardConfig.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Resolve-MailboxPath -Path $ConfigPath -BaseDirectory $PWD.Path
}
$script:MenuConfigPath = $ConfigPath

function Test-MailboxDashboardCollectorModule {
    param([Parameter(Mandatory)] [string]$Name)
    return $null -ne (Get-Module -ListAvailable -Name $Name | Select-Object -First 1)
}

function Get-MailboxDashboardMenuActions {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Root = $script:RepositoryRoot,

        [Parameter()]
        [string]$ConfigFile = $script:MenuConfigPath
    )

    $collector = Join-Path $Root "Collector"
    $web = Join-Path $Root "Web"
    $scripts = @{
        Setup      = Join-Path $collector "Initialize-MailboxDashboard.ps1"
        Collection = Join-Path $collector "Invoke-MailboxDashboardCollection.ps1"
        GraphCollection = Join-Path $collector "Collect-GraphMailboxes.ps1"
        TestData   = Join-Path $collector "New-MailboxDashboardTestData.ps1"
        Snapshot   = Join-Path $collector "Generate-MailboxSnapshot.ps1"
        Validator  = Join-Path $collector "Test-MailboxDashboardJSON.ps1"
        Url        = Join-Path $collector "New-MailboxDashboardUrl.ps1"
        Server     = Join-Path $web "HTTPServer.ps1"
    }
    $actions = [System.Collections.Generic.List[object]]::new()
    $actions.Add([pscustomobject]@{ Key = "Setup"; Label = "Set up or update configuration"; ScriptPath = $scripts.Setup })

    $config = $null
    $configurationValid = $false
    if ((Test-Path -LiteralPath $ConfigFile) -and (Test-Path -LiteralPath $scripts.Collection)) {
        try {
            $config = Import-MailboxDashboardConfig -ConfigPath $ConfigFile -SkipValidation
            Test-MailboxDashboardConfig -Config $config
            $configurationValid = $true
        }
        catch {
            $configurationValid = $false
        }
    }

    if ($null -ne $config) {
        $historyPath = $config.ResolvedPaths.HistoryJson
        $dataPath = $config.ResolvedPaths.DataJson
        $demoHistoryPath = $config.ResolvedPaths.DemoHistoryJson
        $demoDataPath = $config.ResolvedPaths.DemoDataJson

        if ($configurationValid -and (Test-MailboxDashboardCollectorModule -Name ExchangeOnlineManagement) -and
            (Test-Path -LiteralPath $config.ResolvedPaths.MailboxesCsv)) {
            $actions.Add([pscustomobject]@{ Key = "Collect"; Label = "Collect mailbox data - Exchange Online (live, full detail)"; ScriptPath = $scripts.Collection })
        }

        if ((Test-Path -LiteralPath $scripts.Collection) -and
            (Test-Path -LiteralPath $scripts.GraphCollection) -and
            (Test-MailboxDashboardCollectorModule -Name Microsoft.Graph.Authentication)) {
            $graphReady = $false
            try {
                Test-MailboxDashboardConfig -Config $config -Collector Graph
                $graphReady = $true
            }
            catch {
                $graphReady = $false
            }
            if ($graphReady) {
                $actions.Add([pscustomobject]@{
                    Key = "CollectGraph"
                    Label = "Collect mailbox data - Graph only (delayed report, limited detail)"
                    ScriptPath = $scripts.Collection
                })
            }
        }

        if ((Test-Path -LiteralPath $scripts.TestData) -and
            (Test-Path -LiteralPath (Split-Path -Path $demoHistoryPath -Parent)) -and
            (Test-Path -LiteralPath (Split-Path -Path $demoDataPath -Parent))) {
            $actions.Add([pscustomobject]@{ Key = "GenerateDemo"; Label = "Generate isolated demo data"; ScriptPath = $scripts.TestData })
        }

        if ((Test-Path -LiteralPath $demoHistoryPath) -and (Test-Path -LiteralPath $demoDataPath)) {
            $actions.Add([pscustomobject]@{ Key = "ReplaceLiveDemo"; Label = "Replace live data with demo data (backup + confirmation)"; ScriptPath = $scripts.TestData })
        }

        if ((Test-Path -LiteralPath $historyPath) -and (Test-Path -LiteralPath $scripts.Snapshot)) {
            $actions.Add([pscustomobject]@{ Key = "Snapshot"; Label = "Rebuild current snapshot (backup + confirmation)"; ScriptPath = $scripts.Snapshot })
        }

        if ((Test-Path -LiteralPath $historyPath) -and (Test-Path -LiteralPath $dataPath) -and
            (Test-Path -LiteralPath $scripts.Validator)) {
            $actions.Add([pscustomobject]@{ Key = "Validate"; Label = "Validate history and snapshot (read-only)"; ScriptPath = $scripts.Validator })
            $actions.Add([pscustomobject]@{ Key = "Repair"; Label = "Repair and cull invalid records (backup + confirmation)"; ScriptPath = $scripts.Validator })
        }

        if (Test-Path -LiteralPath $config.ResolvedPaths.CollectionStatusJson) {
            $actions.Add([pscustomobject]@{ Key = "Status"; Label = "Show latest collection status"; ScriptPath = $config.ResolvedPaths.CollectionStatusJson })
        }
    }

    if ((Test-Path -LiteralPath $scripts.Server) -and (Test-Path -LiteralPath (Join-Path $web "index.html"))) {
        $actions.Add([pscustomobject]@{ Key = "Host"; Label = "Start local dashboard server"; ScriptPath = $scripts.Server })
    }
    if (Test-Path -LiteralPath $scripts.Url) {
        $actions.Add([pscustomobject]@{ Key = "Url"; Label = "Create a shareable dashboard URL"; ScriptPath = $scripts.Url })
    }

    $actions.Add([pscustomobject]@{ Key = "Exit"; Label = "Exit"; ScriptPath = $null })
    return $actions.ToArray()
}

function Confirm-MailboxDashboardMenuAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter()]
        [string]$Response
    )

    if (-not $PSBoundParameters.ContainsKey("Response")) {
        $Response = Read-Host "$Prompt Type YES to continue"
    }

    return ([string]$Response).Trim() -ceq "YES"
}

function Backup-MailboxDashboardFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter()]
        [string]$Label = "before-change"
    )

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $backups = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $backupPath = "$path.$Label.$stamp.bak"
        Copy-Item -LiteralPath $path -Destination $backupPath -ErrorAction Stop
        $backups.Add($backupPath)
    }
    return $backups.ToArray()
}

function Invoke-MailboxDashboardMenuAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter()]
        [string]$ConfigFile = $script:MenuConfigPath
    )

    $config = $null
    if (Test-Path -LiteralPath $ConfigFile) {
        $config = Import-MailboxDashboardConfig -ConfigPath $ConfigFile -SkipValidation
    }

    switch ($Key) {
        "Setup" {
            & (Join-Path $script:CollectorRoot "Initialize-MailboxDashboard.ps1") -ConfigPath $ConfigFile
        }
        "Collect" {
            if (-not (Confirm-MailboxDashboardMenuAction -Prompt "Collect live Exchange Online data?")) {
                Write-Notice "Collection cancelled; no live data was changed."
                return
            }
            & (Join-Path $script:CollectorRoot "Invoke-MailboxDashboardCollection.ps1") -ConfigPath $ConfigFile
        }
        "GenerateDemo" {
            & (Join-Path $script:CollectorRoot "New-MailboxDashboardTestData.ps1") -ConfigPath $ConfigFile
        }
        "CollectGraph" {
            Write-Attention "Graph usage reports are delayed. Archive statistics, mailbox permissions, logon and retention details are unavailable."
            if (-not (Confirm-MailboxDashboardMenuAction -Prompt "Collect Graph-only data into the configured history and snapshot?")) {
                Write-Notice "Graph collection cancelled; no live data was changed."
                return
            }
            $backups = Backup-MailboxDashboardFiles -Paths @(
                $config.ResolvedPaths.HistoryJson, $config.ResolvedPaths.DataJson
            ) -Label "before-graph"
            foreach ($backup in $backups) { Write-Detail "Backup: $backup" }
            & (Join-Path $script:CollectorRoot "Invoke-MailboxDashboardCollection.ps1") -ConfigPath $ConfigFile -Collector Graph
        }
        "ReplaceLiveDemo" {
            if (-not (Confirm-MailboxDashboardMenuAction -Prompt "Replace live history and snapshot with synthetic demo data?")) {
                Write-Notice "Demo replacement cancelled; live data was not changed."
                return
            }
            $backups = Backup-MailboxDashboardFiles -Paths @(
                $config.ResolvedPaths.HistoryJson,
                $config.ResolvedPaths.DataJson
            ) -Label "before-demo"
            foreach ($backup in $backups) { Write-Detail "Backup: $backup" }
            & (Join-Path $script:CollectorRoot "New-MailboxDashboardTestData.ps1") -ConfigPath $ConfigFile -Live
        }
        "Snapshot" {
            if (-not (Confirm-MailboxDashboardMenuAction -Prompt "Overwrite the current snapshot from history?")) {
                Write-Notice "Snapshot rebuild cancelled; live data was not changed."
                return
            }
            $backups = Backup-MailboxDashboardFiles -Paths @($config.ResolvedPaths.DataJson) -Label "before-snapshot"
            foreach ($backup in $backups) { Write-Detail "Backup: $backup" }
            & (Join-Path $script:CollectorRoot "Generate-MailboxSnapshot.ps1") -ConfigPath $ConfigFile
        }
        "Validate" {
            & (Join-Path $script:CollectorRoot "Test-MailboxDashboardJSON.ps1") -ConfigPath $ConfigFile -Target Both
        }
        "Repair" {
            if (-not (Confirm-MailboxDashboardMenuAction -Prompt "Repair and cull invalid history/snapshot records?")) {
                Write-Notice "Repair cancelled; live data was not changed."
                return
            }
            & (Join-Path $script:CollectorRoot "Test-MailboxDashboardJSON.ps1") `
                -ConfigPath $ConfigFile -Target Both -Repair -Cull
        }
        "Status" {
            $status = Get-Content -LiteralPath $config.ResolvedPaths.CollectionStatusJson -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            $status | Select-Object status, collector, startedUtc, completedUtc, durationSeconds, authenticationMode, partialCollection, steps, notification |
                Format-List
        }
        "Host" {
            $serverPath = Join-Path $script:RepositoryRoot "Web\HTTPServer.ps1"
            $webRoot = Join-Path $script:RepositoryRoot "Web"
            $serverExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $arguments = @(
                "-NoProfile", "-File", "`"$serverPath`"",
                "-RootPath", "`"$webRoot`"",
                "-Prefix", "http://localhost:8888/", "-NoSpinner"
            )
            $process = Start-Process -FilePath $serverExecutable -ArgumentList $arguments -PassThru
            Write-Success "Dashboard server started (process $($process.Id)): http://localhost:8888/"
            Start-Process "http://localhost:8888/"
        }
        "Url" {
            & (Join-Path $script:CollectorRoot "New-MailboxDashboardUrl.ps1") -BaseUrl "http://localhost:8888/"
        }
        "Exit" { return }
        default { throw "Unknown MailboxDashboard menu action '$Key'." }
    }
}

function Start-MailboxDashboardMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        Write-Host "MailboxDashboard operator menu" -ForegroundColor Cyan
        Write-Host "-------------------------------" -ForegroundColor DarkCyan
        $actions = @(Get-MailboxDashboardMenuActions)
        if (-not (Test-Path -LiteralPath $script:MenuConfigPath)) {
            Write-Host "Configuration not found; data and collection actions are hidden until setup." -ForegroundColor Yellow
        }
        else {
            Write-Host "Unavailable actions are hidden. Live-data changes require typing YES." -ForegroundColor DarkGray
        }

        for ($index = 0; $index -lt $actions.Count; $index++) {
            Write-Host ("{0,2}. {1}" -f ($index + 1), $actions[$index].Label)
        }

        $selection = Read-Host "Select an action by number"
        $selectedIndex = 0
        if (-not [int]::TryParse($selection, [ref]$selectedIndex) -or
            $selectedIndex -lt 1 -or $selectedIndex -gt $actions.Count) {
            Write-Notice "Enter one of the displayed menu numbers."
            continue
        }

        $action = $actions[$selectedIndex - 1]
        if ($action.Key -eq "Exit") {
            return
        }

        Invoke-MailboxDashboardMenuAction -Key $action.Key
        if ($action.Key -ne "Host") {
            [void](Read-Host "Press Enter to return to the menu")
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-MailboxDashboardMenu
}
