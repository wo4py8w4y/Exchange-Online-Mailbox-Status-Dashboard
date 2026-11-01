<#
.SYNOPSIS
    Pester coverage for validated MailboxDashboard backup creation and status manifests.
.DESCRIPTION
    Uses isolated temporary source and web-root folders; no production data is modified.
.NOTES
    GitHub Summary: Exercises pre-backup validation, integrity manifests, WhatIf, and
    destination-path safety.
#>
$backupScript = Join-Path $PSScriptRoot '..\Backup-MailboxDashboard.ps1'

Describe 'Backup-MailboxDashboard.ps1' {
    BeforeEach {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MailboxDashboardBackupTests_$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -Path $testRoot -ItemType Directory -Force
        $historyPath = Join-Path $testRoot 'history.json'
        $dataPath = Join-Path $testRoot 'data.json'
        $webRoot = Join-Path $testRoot 'web'
        $backupPath = Join-Path $webRoot 'Backups'
        $configPath = Join-Path $testRoot 'dashboardConfig.json'

        $sample = @{
            TimestampUtc     = '2026-01-01T00:00:00Z'
            SizeGB           = 1
            ItemCount        = 10
            PermissionCount  = 0
            QuotaGB          = 100
            UsagePercent     = 1
            LastLogonTime    = '2026-01-01T00:00:00Z'
            ArchiveEnabled   = $false
            ArchiveSizeGB    = 0
            ArchiveItemCount = 0
        }
        $mailbox = @{
            ExchangeGuid       = 'fa05d634-c9b1-43ba-9816-5e02c1554b53'
            PrimarySmtpAddress = 'test@contoso.com'
            DisplayName        = 'Test Mailbox'
            Permissions        = @()
            Samples            = @($sample)
        }
        @{
            GeneratedUtc = '2026-01-01T00:00:00Z'
            MailboxHistory = @($mailbox)
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $historyPath -Encoding UTF8

        $current = @{
            totalGB         = 1
            itemCount       = 10
            quotaGB         = 100
            usagePercent    = 1
            archiveSizeGB   = 0
            archiveItemCount = 0
        }
        @{
            GeneratedUtc = '2026-01-01T00:00:00Z'
            Mailboxes = @(@{
                ExchangeGuid       = $mailbox.ExchangeGuid
                PrimarySmtpAddress = $mailbox.PrimarySmtpAddress
                DisplayName        = $mailbox.DisplayName
                current            = $current
                permissions        = @()
            })
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dataPath -Encoding UTF8
        $testConfig = @{
            Paths = @{
                HistoryJson     = $historyPath
                DataJson        = $dataPath
                BackupDirectory = $backupPath
                WebRoot         = $webRoot
            }
            Backup = @{
                Sources = @('HistoryJson', 'DataJson')
            }
        }
        $testConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }

    AfterEach {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    It 'backs up validated sources and preserves their hashes' {
        $result = & $backupScript -ConfigPath $configPath

        $result.Status | Should Be 'Succeeded'
        Test-Path -LiteralPath $result.BackupDirectory -PathType Container | Should Be $true
        foreach ($source in @(@{ Original = $historyPath; Name = 'history.json' }, @{ Original = $dataPath; Name = 'data.json' })) {
            $backupFile = Join-Path $result.BackupDirectory $source.Name
            (Get-FileHash -LiteralPath $source.Original -Algorithm SHA256).Hash |
                Should Be (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash
        }
        $manifest = Get-Content -LiteralPath (Join-Path $backupPath 'backup-status.json') -Raw | ConvertFrom-Json
        @($manifest.Backups).Count | Should Be 1
        $manifest.Backups[0].ValidationStatus | Should Be 'Valid'
        @($manifest.Backups[0].Files).Count | Should Be 2
        foreach ($file in $manifest.Backups[0].Files) {
            $file.ValidationStatus | Should Be 'Valid'
            [string]::IsNullOrWhiteSpace($file.SHA256) | Should Be $false
            $file.SizeBytes | Should BeGreaterThan 0
        }
        @($result.ValidationReports).Count | Should Be 4
    }

    It 'does not create a backup when a source is invalid' {
        Set-Content -LiteralPath $dataPath -Value '{"GeneratedUtc":"2026-01-01T00:00:00Z"}'

        $threw = $false
        try { & $backupScript -ConfigPath $configPath } catch { $threw = $true }
        $threw | Should Be $true
        Test-Path -LiteralPath $backupPath | Should Be $false
    }

    It 'does not create a backup when a source is missing' {
        Remove-Item -LiteralPath $dataPath

        $threw = $false
        try { & $backupScript -ConfigPath $configPath } catch { $threw = $true }
        $threw | Should Be $true
        Test-Path -LiteralPath $backupPath | Should Be $false
    }

    It 'validates but writes nothing with WhatIf' {
        $result = & $backupScript -ConfigPath $configPath -WhatIf

        $result.Status | Should Be 'WhatIf'
        Test-Path -LiteralPath $backupPath | Should Be $false
        @($result.ValidationReports).Count | Should Be 2
    }

    It 'rejects unsupported and duplicate source entries before writing' {
        foreach ($sources in @(@('HistoryJson', 'OtherJson'), @('HistoryJson', 'historyjson'))) {
            $testConfig.Backup.Sources = $sources
            $testConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

            $threw = $false
            try { & $backupScript -ConfigPath $configPath } catch { $threw = $true }
            $threw | Should Be $true
            Test-Path -LiteralPath $backupPath | Should Be $false
        }
    }

    It 'requires backups to be stored directly under the configured web root' {
        $testConfig.Paths.BackupDirectory = Join-Path $testRoot 'outside'
        $testConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $threw = $false
        try { & $backupScript -ConfigPath $configPath } catch { $threw = $true }
        $threw | Should Be $true
        Test-Path -LiteralPath (Join-Path $testRoot 'outside') | Should Be $false
    }

    It 'does not finalize a backup when the destination path is not a directory' {
        New-Item -Path $webRoot -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $backupPath -Value 'destination is a file'

        $threw = $false
        try { & $backupScript -ConfigPath $configPath } catch { $threw = $true }
        $threw | Should Be $true
        @(Get-ChildItem -LiteralPath $testRoot -Directory -Filter 'MailboxDashboard_*').Count | Should Be 0
    }
}
