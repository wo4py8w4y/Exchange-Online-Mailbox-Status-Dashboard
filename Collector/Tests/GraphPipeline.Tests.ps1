$collectorRoot = Split-Path $PSScriptRoot -Parent

Describe "Graph pipeline selection" {
    BeforeEach {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MailboxDashboard.GraphPipeline." + [guid]::NewGuid().ToString("N"))
        $fixtureRoot = Join-Path $testRoot "Collector"
        $null = New-Item (Join-Path $fixtureRoot "Modules") -ItemType Directory -Force
        Copy-Item (Join-Path $collectorRoot "Modules\*.psm1") (Join-Path $fixtureRoot "Modules")
        foreach ($name in @("Invoke-MailboxDashboardCollection.ps1", "Generate-MailboxSnapshot.ps1", "Test-MailboxDashboardJSON.ps1")) {
            Copy-Item (Join-Path $collectorRoot $name) $fixtureRoot
        }
        $configPath = Join-Path $testRoot "config.json"
        $mappingPath = Join-Path $testRoot "mapping.csv"
        Set-Content $mappingPath "GraphUserId,ExchangeGuid" -Encoding UTF8
        $historyPath = Join-Path $testRoot "history.json"
        $dataPath = Join-Path $testRoot "data.json"
        $config = @{
            Organization = "contoso.onmicrosoft.com"
            AppID = "11111111-1111-1111-1111-111111111111"
            Thumbprint = "test-thumbprint"
            Paths = @{
                MailboxesCsv = (Join-Path $testRoot "missing.csv")
                GraphMailboxMappingCsv = $mappingPath
                HistoryJson = $historyPath
                DataJson = $dataPath
                CollectionStatusJson = (Join-Path $testRoot "status.json")
                AlertStateJson = (Join-Path $testRoot "alerts.json")
                TempDirectory = $testRoot
                ThreadJobsDirectory = $testRoot
                LogDirectory = $testRoot
            }
            Logging = @{ Enabled = $false }
            Console = @{ ShowProgress = $false; ShowPerItem = $false }
        }
        $config | ConvertTo-Json -Depth 6 | Set-Content $configPath -Encoding UTF8
        $entry = @{
            ExchangeGuid = "22222222-2222-2222-2222-222222222222"
            PrimarySmtpAddress = "mailbox@contoso.com"
            DisplayName = "Graph mailbox"
            Permissions = $null
            Samples = @(@{
                TimestampUtc = "2026-10-01T00:00:00Z"
                SizeGB = 10; ItemCount = 25; QuotaGB = 50; UsagePercent = 20
                ArchiveEnabled = $true; ArchiveSizeGB = $null; ArchiveItemCount = $null
                PermissionCount = $null; LastLogonTime = $null
                DataAvailability = @{
                    Source = "MicrosoftGraph"; ReportRefreshDate = "2026-10-01"
                    UnavailableFields = @("ArchiveSizeGB", "ArchiveItemCount", "Permissions", "LastLogonTime", "Retention", "RecipientTypeDetails", "LicenseRequired")
                }
            })
        }
        @{ GeneratedUtc = "2026-10-03T00:00:00Z"; MailboxHistory = @($entry) } |
            ConvertTo-Json -Depth 10 | Set-Content $historyPath -Encoding UTF8
        Set-Content (Join-Path $fixtureRoot "Collect-GraphMailboxes.ps1") @'
param($ConfigPath, [switch]$Connect, [string[]]$Identity)
if (-not $Connect) { throw "Pipeline must request Graph connection." }
Set-Content (Join-Path $PSScriptRoot "graph-invoked.txt") ($Identity -join ',')
[pscustomobject]@{ Collected = 1; Failed = 0 }
'@ -Encoding UTF8
        Set-Content (Join-Path $fixtureRoot "Invoke-MailboxDashboardAuth.ps1") 'throw "Exchange authentication must not run."' -Encoding UTF8
        Set-Content (Join-Path $fixtureRoot "Collect-ExchangeOnlineMailboxes.ps1") 'throw "Exchange collector must not run."' -Encoding UTF8
        $pipelinePath = Join-Path $fixtureRoot "Invoke-MailboxDashboardCollection.ps1"
    }

    AfterEach {
        Remove-Item $testRoot -Recurse -Force
    }

    It "routes to Graph and rebuilds and validates nullable unavailable metrics" {
        $result = & $pipelinePath -ConfigPath $configPath -Collector Graph -Identity "mailbox@contoso.com"
        $result.Status | Should Be "Partial"
        (Get-Content (Join-Path $fixtureRoot "graph-invoked.txt") -Raw).Trim() | Should Be "mailbox@contoso.com"
        $snapshot = Get-Content $dataPath -Raw | ConvertFrom-Json
        $snapshot.Mailboxes[0].current.archiveSizeGB | Should Be $null
        $snapshot.Mailboxes[0].DataAvailability.Source | Should Be "MicrosoftGraph"
        $status = Get-Content (Join-Path $testRoot "status.json") -Raw | ConvertFrom-Json
        $status.collector | Should Be "Graph"
    }

    It "does not connect or write when previewing Graph collection" {
        & $pipelinePath -ConfigPath $configPath -Collector Graph -WhatIf
        (Test-Path (Join-Path $fixtureRoot "graph-invoked.txt")) | Should Be $false
        (Test-Path $dataPath) | Should Be $false
        (Test-Path (Join-Path $testRoot "status.json")) | Should Be $false
    }

    It "rejects Exchange worker switches before touching Graph or status output" {
        { & $pipelinePath -ConfigPath $configPath -Collector Graph -Parallel } | Should Throw
        (Test-Path (Join-Path $fixtureRoot "graph-invoked.txt")) | Should Be $false
        (Test-Path (Join-Path $testRoot "status.json")) | Should Be $false
    }

    It "restores Exchange detail and removes Graph availability when switching back" {
        $config.Paths.MailboxesCsv = Join-Path $testRoot "mailboxes.csv"
        Set-Content $config.Paths.MailboxesCsv "PrimarySMTPAddress`nmailbox@contoso.com" -Encoding UTF8
        $config | ConvertTo-Json -Depth 6 | Set-Content $configPath -Encoding UTF8
        $history = Get-Content $historyPath -Raw | ConvertFrom-Json
        $history.MailboxHistory[0] | Add-Member -NotePropertyName Retention -NotePropertyValue $null
        $history.MailboxHistory[0] | Add-Member -NotePropertyName DataAvailability `
            -NotePropertyValue $history.MailboxHistory[0].Samples[0].DataAvailability
        $history | ConvertTo-Json -Depth 10 | Set-Content $historyPath -Encoding UTF8
        function Get-EXOMailbox {
            [CmdletBinding()]
            param($Identity, $Properties, $ResultSize)
            [pscustomobject]@{
                ExchangeGuid = "22222222-2222-2222-2222-222222222222"
                PrimarySmtpAddress = "mailbox@contoso.com"
                DisplayName = "Live mailbox"
                RecipientTypeDetails = "UserMailbox"
                ProhibitSendReceiveQuota = 53687091200
                ArchiveGuid = [guid]::Empty
                ArchiveStatus = "None"
                SKUAssigned = $true
                PersistedCapabilities = @("EXO_P2")
                RetentionPolicy = "Live policy"
            }
        }
        function Get-EXOMailboxStatistics {
            [CmdletBinding()]
            param($Identity)
            [pscustomobject]@{ TotalItemSize = 1073741824; ItemCount = 10 }
        }
        function Get-EXOMailboxPermission {
            [CmdletBinding()]
            param($Identity)
            [pscustomobject]@{ User = "delegate@contoso.com"; IsInherited = $false; AccessRights = @("FullAccess"); Deny = $false }
        }

        & (Join-Path $collectorRoot "Collect-ExchangeOnlineMailboxes.ps1") -ConfigPath $configPath | Out-Null
        $history = Get-Content $historyPath -Raw | ConvertFrom-Json
        $entry = $history.MailboxHistory[0]
        ($entry.PSObject.Properties.Name -contains "DataAvailability") | Should Be $false
        $entry.Retention.RetentionPolicy | Should Be "Live policy"
        @($entry.Permissions).Count | Should Be 1
        $entry.Samples[-1].ArchiveSizeGB | Should Be 0
    }
}
