$collectorRoot = Split-Path -Path $PSScriptRoot -Parent
$repositoryRoot = Split-Path -Path $collectorRoot -Parent
Import-Module (Join-Path $collectorRoot "Modules\MailboxDashboard.Config.psm1") -Force
Import-Module (Join-Path $collectorRoot "Modules\MailboxDashboard.Operations.psm1") -Force

Describe "MailboxDashboard operations" {
    BeforeEach {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MailboxDashboard.Tests." + [guid]::NewGuid().ToString("N"))
        $null = New-Item -Path $testRoot -ItemType Directory -Force
        $dataPath = Join-Path $testRoot "data.json"
        $statePath = Join-Path $testRoot "alert-state.json"
        $statusPath = Join-Path $testRoot "collection-status.json"
        $script:sendCount = 0
        $script:sendFailure = $false

        $config = Import-MailboxDashboardConfig `
            -ConfigPath (Join-Path $collectorRoot "Config\dashboardConfig.example.json") -SkipValidation
        $config.Notifications.Enabled = $true
        $config.Notifications.SenderMailbox = "dashboard@contoso.com"
        $config.Notifications.Recipients = @("operator@contoso.com")
        $config.ClientSecret = "test-secret"
        $mailboxesCsvPath = Join-Path $testRoot "mailboxes.csv"
        Set-Content -LiteralPath $mailboxesCsvPath -Value "PrimarySMTPAddress`nmailbox@contoso.com" -Encoding UTF8
        $config.ResolvedPaths = [pscustomobject]@{
            MailboxesCsv = $mailboxesCsvPath
            HistoryJson = $dataPath
            DataJson = $dataPath
            CollectionStatusJson = $statusPath
            AlertStateJson = $statePath
            TempDirectory = $testRoot
            ThreadJobsDirectory = $testRoot
            LogDirectory = $testRoot
        }

        $script:sendAction = {
            param($settings, $subject, $body)
            $script:sendCount++
            if ($script:sendFailure) {
                throw "Graph rejected the message"
            }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    function Set-TestSnapshot {
        param([double]$UsagePercent = 90)

        $snapshot = [pscustomobject]@{
            GeneratedUtc = (Get-Date).ToUniversalTime().ToString("o")
            Mailboxes = @(
                [pscustomobject]@{
                    ExchangeGuid = "e45d71d0-1111-2222-3333-123456789abc"
                    DisplayName = "Test mailbox"
                    PrimarySmtpAddress = "mailbox@contoso.com"
                    current = [pscustomobject]@{ usagePercent = $UsagePercent }
                }
            )
        }
        $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dataPath -Encoding UTF8
    }

    function New-TestCollectionStatus {
        param(
            [string]$RunStatus = "Succeeded",
            [switch]$Partial,
            [switch]$TestData
        )

        return [pscustomobject]@{
            status = $RunStatus
            partialCollection = [bool]$Partial
            testData = [bool]$TestData
        }
    }

    It "loads monitoring and disabled-notification defaults from existing configuration" {
        $loaded = Import-MailboxDashboardConfig `
            -ConfigPath (Join-Path $collectorRoot "Config\dashboardConfig.example.json") -SkipValidation

        $loaded.Monitoring.StaleAfterMinutes | Should Be 60
        $loaded.Notifications.Enabled | Should Be $false
        $loaded.ResolvedPaths.CollectionStatusJson | Should Be (Join-Path $repositoryRoot "Web\collection-status.json")
        $loaded.ResolvedPaths.AlertStateJson | Should Be (Join-Path $collectorRoot "Logs\alert-state.json")
    }

    It "rejects enabled notifications without sender, recipients, and app credentials" {
        $config.Notifications.SenderMailbox = ""
        $config.Notifications.Recipients = @()
        $config.ClientSecret = ""

        $threwForNotifications = $false
        try {
            Test-MailboxDashboardConfig -Config $config
        }
        catch {
            $threwForNotifications = $_.Exception.Message -match "Notifications\."
        }
        $threwForNotifications | Should Be $true
    }

    It "writes collection status as valid JSON without exposing mailbox details" {
        $status = [pscustomobject]@{
            schemaVersion = 1
            runId = [guid]::NewGuid().ToString()
            status = "Succeeded"
            startedUtc = (Get-Date).ToUniversalTime().ToString("o")
            completedUtc = (Get-Date).ToUniversalTime().ToString("o")
            durationSeconds = 2.5
            authenticationMode = "TestData"
            testData = $true
            partialCollection = $false
            staleAfterMinutes = 60
            steps = @()
            failureSummary = $null
            notification = [pscustomobject]@{
                enabled = $false; deliveryStatus = "Disabled"; transitionCount = 0; errorSummary = $null
            }
        }

        Write-MailboxDashboardCollectionStatus -Status $status -Path $statusPath
        $saved = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json

        $saved.schemaVersion | Should Be 1
        $saved.status | Should Be "Succeeded"
        (Get-Content -LiteralPath $statusPath -Raw) | Should Not Match "mailbox@contoso.com|test-secret"
    }

    It "sends only new, changed, and resolved threshold transitions" {
        Set-TestSnapshot -UsagePercent 90
        $first = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction
        $same = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction
        Set-TestSnapshot -UsagePercent 95
        $changed = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction
        Set-TestSnapshot -UsagePercent 50
        $resolved = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction

        $first.DeliveryStatus | Should Be "Sent"
        $same.DeliveryStatus | Should Be "NoChanges"
        $changed.DeliveryStatus | Should Be "Sent"
        $resolved.DeliveryStatus | Should Be "Sent"
        $script:sendCount | Should Be 3
    }

    It "does not advance alert state after Graph delivery fails and retries next run" {
        Set-TestSnapshot -UsagePercent 90
        $script:sendFailure = $true
        $failed = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction
        $stateWasWritten = Test-Path -LiteralPath $statePath
        $script:sendFailure = $false
        $retried = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction

        $failed.DeliveryStatus | Should Be "Failed"
        $stateWasWritten | Should Be $false
        $retried.DeliveryStatus | Should Be "Sent"
        $script:sendCount | Should Be 2
    }

    It "tracks collection failure and recovery transitions" {
        $failed = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus -RunStatus "Failed") `
            -DataPath $dataPath -StatePath $statePath -GraphSendAction $sendAction
        Set-TestSnapshot -UsagePercent 50
        $recovered = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) `
            -DataPath $dataPath -StatePath $statePath -GraphSendAction $sendAction

        $failed.DeliveryStatus | Should Be "Sent"
        $recovered.DeliveryStatus | Should Be "Sent"
        $script:sendCount | Should Be 2
    }

    It "does not send or save state for WhatIf, disabled, or synthetic-data runs" {
        Set-TestSnapshot -UsagePercent 90
        $whatIf = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction -WhatIf
        $disabledConfig = [pscustomobject]@{
            Notifications = [pscustomobject]@{ Enabled = $false }
        }
        $disabled = Invoke-MailboxDashboardAlerting -Config $disabledConfig `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction
        $testData = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus -TestData) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction

        $whatIf.DeliveryStatus | Should Be "WhatIf"
        $disabled.DeliveryStatus | Should Be "Disabled"
        $testData.DeliveryStatus | Should Be "SkippedTestData"
        (Test-Path -LiteralPath $statePath) | Should Be $false
        $script:sendCount | Should Be 0
    }

    It "preserves prior mailbox alerts when a failed or partial run has no complete snapshot" {
        Set-TestSnapshot -UsagePercent 90
        $null = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus) -DataPath $dataPath -StatePath $statePath `
            -GraphSendAction $sendAction
        Remove-Item -LiteralPath $dataPath -Force
        $partial = Invoke-MailboxDashboardAlerting -Config $config `
            -CollectionStatus (New-TestCollectionStatus -RunStatus "Partial" -Partial) `
            -DataPath $dataPath -StatePath $statePath -GraphSendAction $sendAction
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

        $partial.DeliveryStatus | Should Be "Sent"
        @($saved.conditions).Count | Should Be 1
        $saved.conditions[0].Severity | Should Be "Warning"
    }

    It "matches generated status records to the documented schema contract" {
        $status = [pscustomobject]@{
            schemaVersion = 1; runId = [guid]::NewGuid().ToString(); status = "Succeeded"
            startedUtc = (Get-Date).ToUniversalTime().ToString("o")
            completedUtc = (Get-Date).ToUniversalTime().ToString("o")
            durationSeconds = 0; authenticationMode = "Certificate"; testData = $false
            partialCollection = $false; staleAfterMinutes = 60; steps = @()
            failureSummary = $null
            notification = [pscustomobject]@{
                enabled = $false; deliveryStatus = "Disabled"; transitionCount = 0; errorSummary = $null
            }
        }
        Write-MailboxDashboardCollectionStatus -Status $status -Path $statusPath
        $saved = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        $schema = Get-Content -LiteralPath (Join-Path $repositoryRoot "Web\collection-status.schema.json") -Raw | ConvertFrom-Json

        foreach ($requiredName in $schema.required) {
            (@($saved.PSObject.Properties.Name) -contains $requiredName) | Should Be $true
        }
        (@($schema.properties.status.enum) -contains $saved.status) | Should Be $true
        $rawStatus = Get-Content -LiteralPath $statusPath -Raw
        $rawStatus | Should Match '"startedUtc"\s*:\s*"[^"]*(Z|\+00:00)"'
        $rawStatus | Should Match '"completedUtc"\s*:\s*"[^"]*(Z|\+00:00)"'
    }
}
