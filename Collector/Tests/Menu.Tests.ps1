$collectorRoot = Split-Path -Path $PSScriptRoot -Parent
$repositoryRoot = Split-Path -Path $collectorRoot -Parent
. (Join-Path $collectorRoot "Start-MailboxDashboardMenu.ps1")

Describe "MailboxDashboard contextual operator menu" {
    BeforeEach {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MailboxDashboard.MenuTests." + [guid]::NewGuid().ToString("N"))
        $null = New-Item -Path $testRoot -ItemType Directory -Force
        $configPath = Join-Path $testRoot "dashboardConfig.json"
    }

    AfterEach {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    It "hides data actions until a configuration and required inputs exist" {
        $actions = @(Get-MailboxDashboardMenuActions -Root $repositoryRoot -ConfigFile $configPath)
        $keys = @($actions | ForEach-Object Key)

        ($keys -contains "Setup") | Should Be $true
        ($keys -contains "Host") | Should Be $true
        ($keys -contains "Url") | Should Be $true
        ($keys -contains "Exit") | Should Be $true
        ($keys -contains "Collect") | Should Be $false
        ($keys -contains "Validate") | Should Be $false
        ($keys -contains "ReplaceLiveDemo") | Should Be $false
    }

    It "shows only data actions whose configured paths and files are present" {
        $config = Get-Content -LiteralPath (Join-Path $collectorRoot "Config\dashboardConfig.example.json") -Raw |
            ConvertFrom-Json
        $paths = @{}
        foreach ($name in @(
            "MailboxesCsv", "HistoryJson", "DataJson", "CollectionStatusJson", "AlertStateJson",
            "DemoHistoryJson", "DemoDataJson", "TempDirectory", "ThreadJobsDirectory", "LogDirectory"
        )) {
            $target = Join-Path $testRoot $name
            if ($name -like "*Directory") {
                $null = New-Item -Path $target -ItemType Directory -Force
            }
            else {
                Set-Content -LiteralPath $target -Value "{}" -Encoding UTF8
            }
            $paths[$name] = $target
        }
        $config.Paths = [pscustomobject]$paths
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $actions = @(Get-MailboxDashboardMenuActions -Root $repositoryRoot -ConfigFile $configPath)
        $keys = @($actions | ForEach-Object Key)

        ($keys -contains "GenerateDemo") | Should Be $true
        ($keys -contains "ReplaceLiveDemo") | Should Be $true
        ($keys -contains "Snapshot") | Should Be $true
        ($keys -contains "Validate") | Should Be $true
        ($keys -contains "Repair") | Should Be $true
        ($keys -contains "Status") | Should Be $true
    }

    It "requires the exact confirmation token before a destructive action proceeds" {
        $confirmed = Confirm-MailboxDashboardMenuAction -Prompt "Replace live data?" -Response "YES"
        $cancelled = Confirm-MailboxDashboardMenuAction -Prompt "Replace live data?" -Response "no"

        $confirmed | Should Be $true
        $cancelled | Should Be $false
        @(Get-ChildItem -LiteralPath $testRoot -Force).Count | Should Be 0
    }

    It "offers Graph independently of Exchange modules and the Exchange mailbox list" {
        $mappingPath = Join-Path $testRoot "mapping.csv"
        Set-Content -LiteralPath $mappingPath -Value "GraphUserId,ExchangeGuid" -Encoding UTF8
        @{
            Organization = "contoso.onmicrosoft.com"
            AppID = "11111111-1111-1111-1111-111111111111"
            Thumbprint = "test-thumbprint"
            Paths = @{
                MailboxesCsv = (Join-Path $testRoot "missing.csv")
                GraphMailboxMappingCsv = $mappingPath
                HistoryJson = (Join-Path $testRoot "history.json")
                DataJson = (Join-Path $testRoot "data.json")
                CollectionStatusJson = (Join-Path $testRoot "status.json")
                AlertStateJson = (Join-Path $testRoot "alerts.json")
                TempDirectory = $testRoot
                ThreadJobsDirectory = $testRoot
                LogDirectory = $testRoot
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
        Mock Test-MailboxDashboardCollectorModule { $Name -eq "Microsoft.Graph.Authentication" }

        $keys = @(Get-MailboxDashboardMenuActions -Root $repositoryRoot -ConfigFile $configPath |
            ForEach-Object Key)
        ($keys -contains "CollectGraph") | Should Be $true
        ($keys -contains "Collect") | Should Be $false

        Remove-Item -LiteralPath $mappingPath
        $keys = @(Get-MailboxDashboardMenuActions -Root $repositoryRoot -ConfigFile $configPath |
            ForEach-Object Key)
        ($keys -contains "CollectGraph") | Should Be $false
    }

    It "does not run Graph collection or backups when confirmation is declined" {
        Mock Confirm-MailboxDashboardMenuAction { $false }
        Invoke-MailboxDashboardMenuAction -Key CollectGraph -ConfigFile $configPath
        Assert-MockCalled Confirm-MailboxDashboardMenuAction -Times 1 -Exactly
        @(Get-ChildItem -LiteralPath $testRoot -Force).Count | Should Be 0
    }

    It "creates timestamped backups only for existing live files" {
        $historyPath = Join-Path $testRoot "history.json"
        $missingPath = Join-Path $testRoot "missing.json"
        Set-Content -LiteralPath $historyPath -Value '{"MailboxHistory":[]}' -Encoding UTF8

        $backups = @(Backup-MailboxDashboardFiles -Paths @($historyPath, $missingPath) -Label "before-demo")

        $backups.Count | Should Be 1
        (Test-Path -LiteralPath $backups[0]) | Should Be $true
        (Get-Content -LiteralPath $backups[0] -Raw).Trim() | Should Be '{"MailboxHistory":[]}'
    }
}
