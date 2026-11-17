$collectorRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $collectorRoot 'Modules\MailboxDashboard.Graph.psm1') -Force -DisableNameChecking

# Stubs let module-scoped mocks run without installing Graph or contacting a tenant.
if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
    $script:graphCreatedRequestStub = $true
    function global:Invoke-MgGraphRequest {
        [CmdletBinding()]
        param($Method, $Uri, $OutputFilePath, $OutputType)
        throw 'Live Graph requests are forbidden in these tests.'
    }
}
if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
    $script:graphCreatedContextStub = $true
    function global:Get-MgContext {
        [CmdletBinding()]
        param()
        throw 'Live Graph context is forbidden in these tests.'
    }
}

Describe 'Strict Graph-only mailbox collection' {
    BeforeEach {
        $script:graphTestRoot = Join-Path $PSScriptRoot ('.graph-tests-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:graphTestRoot -ItemType Directory
        $script:graphHistoryPath = Join-Path $script:graphTestRoot 'history.json'
        $script:graphMappingPath = Join-Path $script:graphTestRoot 'mapping.csv'
        $script:graphUserId = '11111111-1111-1111-1111-111111111111'
        $script:graphExchangeGuid = '22222222-2222-2222-2222-222222222222'
        $script:graphConfig = [pscustomobject]@{
            Organization = 'contoso.onmicrosoft.com'; AppID = '33333333-3333-3333-3333-333333333333'
            Thumbprint = ''; ClientSecret = 'fixture-only'
            ResolvedPaths = [pscustomobject]@{
                HistoryJson = $script:graphHistoryPath; GraphMailboxMappingCsv = $script:graphMappingPath
            }
            Collection = [pscustomobject]@{ MaxHistorySamples = 3 }
        }
        Set-Content -LiteralPath $script:graphMappingPath -Encoding UTF8 -Value @(
            'GraphUserId,ExchangeGuid'
            "$script:graphUserId,$script:graphExchangeGuid"
        )
        $script:graphUser = [pscustomobject]@{
            id = $script:graphUserId; displayName = 'Mailbox'
            userPrincipalName = 'login@contoso.com'; mail = 'fallback@contoso.com'
            proxyAddresses = @('smtp:alias@contoso.com', 'SMTP:primary@contoso.com')
            assignedLicenses = @([pscustomobject]@{ skuId = '44444444-4444-4444-4444-444444444444' })
            assignedPlans = @([pscustomobject]@{ service = 'exchange'; capabilityStatus = 'Enabled' })
        }
        $script:graphReportRows = @([pscustomobject]@{
            'Report Refresh Date' = '2026-09-30'; 'User Principal Name' = 'LOGIN@contoso.com'
            'Is Deleted' = 'False'; 'Storage Used (Byte)' = '1073741824'
            'Item Count' = '123'; 'Prohibit Send/Receive Quota (Byte)' = '2147483648'
            'Has Archive' = 'True'; 'Last Activity Date' = '2026-09-29'
        })
        $script:graphPaged = $false
        $script:graphUserPurpose = 'user'
        $script:graphPageCalls = 0
        $script:graphRequestFailure = $null
        $script:graphFailuresRemaining = 0
        $script:graphRequestCount = 0
        $script:graphRetryDelays = @()
        $global:GraphCollectionTestVariables = @{}
        foreach ($variable in (Get-Variable -Scope Script -Name 'graph*')) {
            $global:GraphCollectionTestVariables[$variable.Name] = $variable
        }
        Mock Get-MgContext -ModuleName MailboxDashboard.Graph { [pscustomobject]@{ AuthType = 'AppOnly' } }
        Mock Write-Notice -ModuleName MailboxDashboard.Graph {}
        Mock Start-Sleep -ModuleName MailboxDashboard.Graph {
            $global:GraphCollectionTestVariables.graphRetryDelays.Value += $Seconds
        }
        Mock Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph {
            $fixture = $global:GraphCollectionTestVariables
            $fixture.graphRequestCount.Value++
            if ($null -ne $fixture.graphRequestFailure.Value -and $fixture.graphFailuresRemaining.Value -gt 0) {
                $fixture.graphFailuresRemaining.Value--
                throw $fixture.graphRequestFailure.Value
            }
            if ($OutputFilePath) {
                $fixture.graphReportRows.Value | Export-Csv -LiteralPath $OutputFilePath -NoTypeInformation -Encoding UTF8
                return
            }
            if ($Uri -like '*/mailboxSettings/userPurpose') {
                return [pscustomobject]@{ value = $fixture.graphUserPurpose.Value }
            }
            $fixture.graphPageCalls.Value++
            if ($fixture.graphPaged.Value -and $fixture.graphPageCalls.Value -eq 1) {
                return [pscustomobject]@{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=fixture' }
            }
            return [pscustomobject]@{ value = @($fixture.graphUser.Value) }
        }
        Mock Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -ParameterFilter { $Uri -like '*/mailboxSettings/userPurpose' } {
            $fixture = $global:GraphCollectionTestVariables
            $fixture.graphRequestCount.Value++
            [pscustomobject]@{ value = $fixture.graphUserPurpose.Value }
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:graphTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name GraphCollectionTestVariables -ErrorAction SilentlyContinue
    }

    function Invoke-TestGraphCollection {
        Invoke-MailboxDashboardGraphCollection -Config $script:graphConfig -Confirm:$false
    }

    function Save-TestGraphHistory {
        $script:graphOriginal = '{"GeneratedUtc":"2026-09-01T00:00:00Z","MailboxHistory":[]}'
        Set-Content -LiteralPath $script:graphHistoryPath -Value $script:graphOriginal -Encoding UTF8
        $script:graphOriginal = Get-Content -LiteralPath $script:graphHistoryPath -Raw
    }

    function New-TestGraphError {
        param([int]$StatusCode)
        $errorObject = [System.Exception]::new('Fixture Graph failure')
        Add-Member -InputObject $errorObject -NotePropertyName ResponseStatusCode -NotePropertyValue $StatusCode
        Add-Member -InputObject $errorObject -NotePropertyName ResponseHeaders -NotePropertyValue @{ 'Retry-After' = '120' }
        return $errorObject
    }

    function Assert-GraphCollectionThrows {
        param([scriptblock]$Action)
        $threw = $false
        try { & $Action } catch { $threw = $true }
        $threw | Should Be $true
    }

    It 'converts report bytes, preserves durable mapping, and marks unavailable metrics null' {
        $result = Invoke-TestGraphCollection
        $saved = Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json
        $entry = $saved.MailboxHistory[0]
        $sample = $entry.Samples[0]
        $result.Collected | Should Be 1
        $result.Failed | Should Be 0
        $entry.ExchangeGuid | Should Be $script:graphExchangeGuid
        $entry.ExchangeGuid | Should Not Be $script:graphUserId
        $entry.PrimarySmtpAddress | Should Be 'primary@contoso.com'
        $sample.SizeGB | Should Be 1
        $sample.ItemCount | Should Be 123
        $sample.QuotaGB | Should Be 2
        $sample.UsagePercent | Should Be 50
        ([datetimeoffset]$sample.TimestampUtc).UtcDateTime.ToString('o') | Should Be '2026-09-30T00:00:00.0000000Z'
        $sample.LastActivityDate | Should Be '2026-09-29'
        $sample.ArchiveEnabled | Should Be $true
        ($null -eq $sample.LastLogonTime) | Should Be $true
        ($null -eq $sample.ArchiveSizeGB) | Should Be $true
        ($null -eq $sample.ArchiveItemCount) | Should Be $true
        ($null -eq $sample.PermissionCount) | Should Be $true
        ($null -eq $entry.Permissions) | Should Be $true
        ($null -eq $entry.Retention) | Should Be $true
        ($null -eq $entry.Licensing.LicenseRequired) | Should Be $true
        ($null -eq $entry.Licensing.IsLicenseCompliant) | Should Be $true
        $entry.Licensing.HasLicense | Should Be $true
        $entry.RecipientTypeDetails | Should Be 'UserMailbox'
        $sample.RecipientTypeDetails | Should Be 'UserMailbox'
        $entry.Licensing.RecipientTypeDetails | Should Be 'UserMailbox'
        $entry.GraphUserPurpose | Should Be 'user'
        $sample.GraphUserPurpose | Should Be 'user'
        @($sample.DataAvailability.UnavailableFields) -contains 'RecipientTypeDetails' | Should Be $false
        $entry.Licensing.LicenseTypes[0] | Should Be '44444444-4444-4444-4444-444444444444'
        $entry.DataAvailability.Source | Should Be 'MicrosoftGraph'
        $sample.DataAvailability.Source | Should Be 'MicrosoftGraph'
        $sample.DataAvailability.ReportRefreshDate | Should Be '2026-09-30'
        @($sample.DataAvailability.UnavailableFields) -contains 'LastLogonTime' | Should Be $true
        ($saved.GeneratedUtc -ne $sample.TimestampUtc) | Should Be $true
        @(Get-ChildItem $script:graphTestRoot -Filter 'graph-mailbox-usage.*.csv').Count | Should Be 0
    }

    It 'requires an enabled Exchange plan rather than just a Microsoft 365 SKU' {
        $script:graphUser.assignedPlans = @([pscustomobject]@{ service = 'sharepoint'; capabilityStatus = 'Enabled' })
        $null = Invoke-TestGraphCollection
        $saved = Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json
        $saved.MailboxHistory[0].Licensing.HasLicense | Should Be $false
    }

    It 'represents users with empty assigned plan and SKU collections as unlicensed' {
        $script:graphUser.assignedPlans = @()
        $script:graphUser.assignedLicenses = @()
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        $entry.Licensing.HasLicense | Should Be $false
        @($entry.Licensing.LicenseTypes).Count | Should Be 0
    }

    It 'treats zero quota and absent archive data as unknown and falls back to mail' {
        $script:graphReportRows[0].'Prohibit Send/Receive Quota (Byte)' = '0'
        $script:graphReportRows[0].'Has Archive' = ''
        $script:graphUser.proxyAddresses = @()
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        $entry.PrimarySmtpAddress | Should Be 'fallback@contoso.com'
        ($null -eq $entry.Samples[0].QuotaGB) | Should Be $true
        ($null -eq $entry.Samples[0].UsagePercent) | Should Be $true
        ($null -eq $entry.Samples[0].ArchiveEnabled) | Should Be $true
        @($entry.Samples[0].DataAvailability.UnavailableFields) -contains 'ArchiveEnabled' | Should Be $true
    }

    It 'retains positive sub-gigabyte quota precision so subsequent strict history validation succeeds' {
        $script:graphReportRows[0].'Prohibit Send/Receive Quota (Byte)' = '1'
        $script:graphReportRows[0].'Storage Used (Byte)' = '0'
        $null = Invoke-TestGraphCollection
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        ($entry.Samples[0].QuotaGB -gt 0) | Should Be $true
        @($entry.Samples).Count | Should Be 1
    }

    It 'replaces the same report timestamp idempotently and retains older samples in order' {
        $null = Invoke-TestGraphCollection
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        @($entry.Samples).Count | Should Be 1
        $script:graphReportRows[0].'Report Refresh Date' = '2026-10-01'
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        @($entry.Samples).Count | Should Be 2
        ([datetimeoffset]$entry.Samples[0].TimestampUtc).UtcDateTime.ToString('yyyy-MM-dd') | Should Be '2026-09-30'
        ([datetimeoffset]$entry.Samples[1].TimestampUtc).UtcDateTime.ToString('yyyy-MM-dd') | Should Be '2026-10-01'
        $script:graphConfig.Collection.MaxHistorySamples = 1
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        @($entry.Samples).Count | Should Be 1
        $entry.DataAvailability.ReportRefreshDate | Should Be '2026-10-01'
    }

    It 'rejects duplicate Graph user IDs before any request or history write' {
        Save-TestGraphHistory
        Add-Content -LiteralPath $script:graphMappingPath -Value "$script:graphUserId,55555555-5555-5555-5555-555555555555"
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
        $script:graphRequestCount | Should Be 0
    }

    It 'rejects duplicate mailbox GUIDs and malformed mapping rows' {
        Save-TestGraphHistory
        Add-Content -LiteralPath $script:graphMappingPath -Value "55555555-5555-5555-5555-555555555555,$script:graphExchangeGuid"
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        Set-Content -LiteralPath $script:graphMappingPath -Value "GraphUserId,ExchangeGuid`nnot-a-guid,$script:graphExchangeGuid"
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
        $script:graphRequestCount | Should Be 0
    }

    It 'rejects concealed report names and preserves existing history byte for byte' {
        Save-TestGraphHistory
        $script:graphReportRows[0].'User Principal Name' = 'A1B2C3D4'
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'rejects a missing report user instead of matching the primary SMTP address' {
        Save-TestGraphHistory
        $script:graphReportRows[0].'User Principal Name' = 'primary@contoso.com'
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'rejects mapped users missing from the directory without changing history' {
        Save-TestGraphHistory
        $script:graphUser.id = '55555555-5555-5555-5555-555555555555'
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
        $script:graphRequestCount | Should Be 1
    }

    It 'validates every selected record before writing any history' {
        Save-TestGraphHistory
        $secondId = '55555555-5555-5555-5555-555555555555'
        Add-Content -LiteralPath $script:graphMappingPath -Value "$secondId,66666666-6666-6666-6666-666666666666"
        $secondUser = $script:graphUser | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $secondUser.id = $secondId
        $secondUser.userPrincipalName = 'second@contoso.com'
        $global:GraphCollectionTestVariables['graphSecondUser'] = [psvariable]::new('graphSecondUser', $secondUser)
        Mock Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph {
            $fixture = $global:GraphCollectionTestVariables
            if ($Uri -like '*/mailboxSettings/userPurpose') {
                [pscustomobject]@{ value = 'user' }
            }
            elseif ($OutputFilePath) {
                $rows = @($fixture.graphReportRows.Value)
                $secondRow = $rows[0] | ConvertTo-Json | ConvertFrom-Json
                $secondRow.'User Principal Name' = 'second@contoso.com'
                $secondRow.'Item Count' = 'invalid'
                ($rows + @($secondRow)) | Export-Csv -LiteralPath $OutputFilePath -NoTypeInformation
            }
            else {
                [pscustomobject]@{ value = @($fixture.graphUser.Value, $fixture.graphSecondUser.Value) }
            }
        }
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'rejects duplicate active report identities' {
        Save-TestGraphHistory
        $script:graphReportRows += $script:graphReportRows[0]
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'excludes deleted rows and fails when the selected mailbox has only a deleted row' {
        Save-TestGraphHistory
        $script:graphReportRows[0].'Is Deleted' = 'True'
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'rejects invalid or missing numeric metrics without partial writes' {
        Save-TestGraphHistory
        foreach ($invalid in @('-1', '1.5', '1,024', '', '9223372036854775808')) {
            $script:graphReportRows[0].'Storage Used (Byte)' = $invalid
            Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
            (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
        }
    }

    It 'rejects malformed existing history rather than recreating it' {
        foreach ($invalid in @('[]', '', '{', '{"MailboxHistory":{}}',
                '{"MailboxHistory":[{"ExchangeGuid":"22222222-2222-2222-2222-222222222222","Samples":{}}]}',
                '{"MailboxHistory":[{"ExchangeGuid":"22222222-2222-2222-2222-222222222222","Samples":[null]}]}')) {
            Set-Content -LiteralPath $script:graphHistoryPath -Value $invalid
            $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
            Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
            (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
        }
        $script:graphRequestCount | Should Be 0
    }

    It 'rejects duplicate existing mailbox GUIDs or sample timestamps' {
        $entry = [pscustomobject]@{
            ExchangeGuid = $script:graphExchangeGuid
            PrimarySmtpAddress = 'existing@contoso.com'
            Samples = @([pscustomobject]@{
                TimestampUtc = '2026-09-01T00:00:00Z'; SizeGB = 1; ItemCount = 123
                QuotaGB = 2; ArchiveEnabled = $false; ArchiveSizeGB = 0; ArchiveItemCount = 0
            })
        }
        [pscustomobject]@{ MailboxHistory = @($entry, $entry) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:graphHistoryPath
        $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
        $entry.Samples += $entry.Samples[0]
        [pscustomobject]@{ MailboxHistory = @($entry) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:graphHistoryPath
        $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
        $script:graphRequestCount | Should Be 0
    }

    It 'preserves previous samples but never carries old unsupported values into a fresh Graph sample' {
        $old = [pscustomobject]@{
            ExchangeGuid = $script:graphExchangeGuid; Permissions = @('old delegate'); Retention = 'old policy'
            PrimarySmtpAddress = 'existing@contoso.com'
            DataAvailability = [pscustomobject]@{ Source = 'ExchangeOnline' }
            Samples = @([pscustomobject]@{
                TimestampUtc = '2026-09-01T00:00:00Z'; SizeGB = 1; ItemCount = 123
                QuotaGB = 2; ArchiveEnabled = $true; ArchiveItemCount = 1
                ArchiveSizeGB = 42; LastLogonTime = '2026-08-31T00:00:00Z'
                DataAvailability = [pscustomobject]@{ Source = 'ExchangeOnline' }
            })
        }
        [pscustomobject]@{ MailboxHistory = @($old) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:graphHistoryPath
        $null = Invoke-TestGraphCollection
        $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        @($entry.Samples).Count | Should Be 2
        $entry.Samples[0].ArchiveSizeGB | Should Be 42
        $entry.Samples[0].DataAvailability.Source | Should Be 'ExchangeOnline'
        $entry.DataAvailability.Source | Should Be 'MicrosoftGraph'
        $entry.Samples[1].DataAvailability.Source | Should Be 'MicrosoftGraph'
        ($null -eq $entry.Samples[1].ArchiveSizeGB) | Should Be $true
        ($null -eq $entry.Samples[1].LastLogonTime) | Should Be $true
        ($null -eq $entry.Retention) | Should Be $true
        ($null -eq $entry.Permissions) | Should Be $true
    }

    It 'follows directory paging and filters mapped users by address or stable ID' {
        $script:graphPaged = $true
        $result = Invoke-MailboxDashboardGraphCollection -Config $script:graphConfig -Identity 'alias@contoso.com' -Confirm:$false
        $result.Collected | Should Be 1
        $script:graphPageCalls | Should Be 2
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -Scope It -Times 1 -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/users?$skiptoken=fixture'
        }
        $result = Invoke-MailboxDashboardGraphCollection -Config $script:graphConfig -Identity $script:graphUserId -Confirm:$false
        $result.Collected | Should Be 1
    }

    It 'keeps entry availability and capabilities aligned with a newer existing source sample' {
        $entry = [pscustomobject]@{
            ExchangeGuid = $script:graphExchangeGuid; Permissions = @('existing delegate'); Retention = 'existing policy'
            PrimarySmtpAddress = 'current-exo@contoso.com'; DisplayName = 'Current EXO name'
            Licensing = [pscustomobject]@{ HasLicense = $true; LicenseRequired = $true; LicenseTypes = @('ExchangeOnline') }
            DataAvailability = [pscustomobject]@{ Source = 'ExchangeOnline' }
            Samples = @([pscustomobject]@{
                TimestampUtc = '2026-10-02T12:00:00Z'; SizeGB = 1; ItemCount = 123
                QuotaGB = 2; ArchiveEnabled = $false; ArchiveSizeGB = 0; ArchiveItemCount = 0
                DataAvailability = [pscustomobject]@{ Source = 'ExchangeOnline' }
            })
        }
        [pscustomobject]@{ MailboxHistory = @($entry) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:graphHistoryPath
        $null = Invoke-TestGraphCollection
        $saved = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
        @($saved.Samples).Count | Should Be 2
        $saved.DataAvailability.Source | Should Be 'ExchangeOnline'
        $saved.Permissions[0] | Should Be 'existing delegate'
        $saved.Retention | Should Be 'existing policy'
        $saved.PrimarySmtpAddress | Should Be 'current-exo@contoso.com'
        $saved.DisplayName | Should Be 'Current EXO name'
        $saved.Licensing.LicenseTypes[0] | Should Be 'ExchangeOnline'
        $saved.Licensing.LicenseRequired | Should Be $true
        $saved.Samples[0].DataAvailability.Source | Should Be 'MicrosoftGraph'
        ($null -eq $saved.Samples[0].Permissions) | Should Be $true
    }

    It 'rejects external pagination before forwarding an authenticated request' {
        Mock Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph {
            [pscustomobject]@{ value = @(); '@odata.nextLink' = 'https://example.com/v1.0/users' }
        }
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -Scope It -Times 0 -ParameterFilter { $Uri -like '*example.com*' }
    }

    It 'retries throttling with bounded Retry-After then succeeds' {
        $script:graphRequestFailure = New-TestGraphError -StatusCode 429
        $script:graphFailuresRemaining = 1
        $result = Invoke-TestGraphCollection
        $result.Collected | Should Be 1
        $script:graphRequestCount | Should Be 4
        @($script:graphRetryDelays).Count | Should Be 1
        $script:graphRetryDelays[0] | Should Be 60
    }

    It 'bounds service-unavailable retries and preserves history when exhausted' {
        Save-TestGraphHistory
        $script:graphRequestFailure = New-TestGraphError -StatusCode 503
        $script:graphFailuresRemaining = 10
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        $script:graphRequestCount | Should Be 5
        @($script:graphRetryDelays).Count | Should Be 4
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'propagates authorization failure without retry or changing history' {
        Save-TestGraphHistory
        $script:graphRequestFailure = New-TestGraphError -StatusCode 403
        $script:graphFailuresRemaining = 1
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        $script:graphRequestCount | Should Be 1
        @($script:graphRetryDelays).Count | Should Be 0
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'performs no network or file writes under WhatIf even with Connect' {
        $result = Invoke-MailboxDashboardGraphCollection -Config $script:graphConfig -Connect -WhatIf
        $result.Collected | Should Be 0
        $script:graphRequestCount | Should Be 0
        (Test-Path -LiteralPath $script:graphHistoryPath) | Should Be $false
    }

    It 'validates app credentials before calling shared Graph authentication' {
        $script:graphConfig.ClientSecret = ''
        Mock Connect-GraphMailboxApp -ModuleName MailboxDashboard.Graph { throw 'Must not connect' }
        Assert-GraphCollectionThrows { Invoke-MailboxDashboardGraphCollection -Config $script:graphConfig -Connect -Confirm:$false }
        Assert-MockCalled Connect-GraphMailboxApp -ModuleName MailboxDashboard.Graph -Scope It -Times 0
        $script:graphRequestCount | Should Be 0
    }

    It 'uses the shared app-only authentication helper with Connect' {
        Mock Connect-GraphMailboxApp -ModuleName MailboxDashboard.Graph {}
        $result = Invoke-MailboxDashboardGraphCollection -Config $script:graphConfig -Connect -Confirm:$false
        $result.Collected | Should Be 1
        Assert-MockCalled Connect-GraphMailboxApp -ModuleName MailboxDashboard.Graph -Scope It -Times 1
        Assert-MockCalled Get-MgContext -ModuleName MailboxDashboard.Graph -Scope It -Times 0
    }

    It 'queries mailbox purpose using the durable mapped Graph directory ID, not an address' {
        $null = Invoke-TestGraphCollection
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -Scope It -Times 1 -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/users/11111111-1111-1111-1111-111111111111/mailboxSettings/userPurpose'
        }
    }

    It 'maps documented mailbox purposes without inferring license requirements' {
        $types = @{
            user = 'UserMailbox'; linked = 'LinkedMailbox'; shared = 'SharedMailbox'
            room = 'RoomMailbox'; equipment = 'EquipmentMailbox'
        }
        foreach ($purpose in @('user', 'linked', 'shared', 'room', 'equipment', 'others', 'unknownFutureValue', 'futurePurpose')) {
            $script:graphUserPurpose = $purpose
            $null = Invoke-TestGraphCollection
            $entry = (Get-Content -LiteralPath $script:graphHistoryPath -Raw | ConvertFrom-Json).MailboxHistory[0]
            $entry.GraphUserPurpose | Should Be $purpose
            $entry.Samples[0].GraphUserPurpose | Should Be $purpose
            ($entry.RecipientTypeDetails -eq $types[$purpose]) | Should Be $true
            ($entry.Samples[0].RecipientTypeDetails -eq $types[$purpose]) | Should Be $true
            ($entry.Licensing.RecipientTypeDetails -eq $types[$purpose]) | Should Be $true
            (@($entry.Samples[0].DataAvailability.UnavailableFields) -contains 'RecipientTypeDetails') |
                Should Be ($null -eq $types[$purpose])
            ($null -eq $entry.Licensing.LicenseRequired) | Should Be $true
            ($null -eq $entry.Licensing.IsLicenseCompliant) | Should Be $true
        }
    }

    It 'propagates explicit mailbox-purpose authorization errors without overwriting history' {
        Save-TestGraphHistory
        Mock Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -ParameterFilter { $Uri -like '*/mailboxSettings/userPurpose' } {
            $errorObject = [System.Exception]::new('Fixture purpose authorization failure')
            Add-Member -InputObject $errorObject -NotePropertyName ResponseStatusCode -NotePropertyValue 403
            throw $errorObject
        }
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
        Assert-MockCalled Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -Scope It -Times 1 -ParameterFilter { $Uri -like '*/mailboxSettings/userPurpose' }
        @($script:graphRetryDelays).Count | Should Be 0
    }

    It 'rejects malformed mailbox-purpose response schemas rather than hiding failures as unknown' {
        Save-TestGraphHistory
        Mock Invoke-MgGraphRequest -ModuleName MailboxDashboard.Graph -ParameterFilter { $Uri -like '*/mailboxSettings/userPurpose' } {
            [pscustomobject]@{ unexpected = 'shared' }
        }
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $script:graphOriginal
    }

    It 'skips report timestamps colliding with non-Graph samples without deleting EXO samples or profiles' {
        $entry = [pscustomobject]@{
            ExchangeGuid = $script:graphExchangeGuid; PrimarySmtpAddress = 'existing@contoso.com'
            Permissions = @('existing delegate'); Retention = 'existing policy'
            Licensing = [pscustomobject]@{ HasLicense = $true; LicenseRequired = $true }
            Samples = @([pscustomobject]@{
                TimestampUtc = '2026-09-30T00:00:00Z'; SizeGB = 0.5; ItemCount = 50
                QuotaGB = 2; ArchiveEnabled = $true; ArchiveSizeGB = 0.25; ArchiveItemCount = 20
            })
        }
        foreach ($source in @($null, 'ExchangeOnline')) {
            if ($null -ne $source) {
                Add-Member -InputObject $entry.Samples[0] -NotePropertyName DataAvailability -NotePropertyValue ([pscustomobject]@{ Source = $source })
            }
            [pscustomobject]@{ GeneratedUtc = '2026-09-30T00:00:00Z'; MailboxHistory = @($entry) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:graphHistoryPath
            $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
            $result = Invoke-TestGraphCollection
            $result.Collected | Should Be 0
            $result.Skipped | Should Be 1
            $result.Failed | Should Be 0
            (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
        }
        Assert-MockCalled Write-Notice -ModuleName MailboxDashboard.Graph -Scope It -Times 2 -ParameterFilter { $Message -like '*collides*non-Graph*' }
    }

    It 'rejects invalid existing quota and archive values before any request or write' {
        $sample = [pscustomobject]@{
            TimestampUtc = '2026-09-29T00:00:00Z'; SizeGB = 1; ItemCount = 50
            QuotaGB = 2; ArchiveEnabled = $false; ArchiveSizeGB = 0; ArchiveItemCount = 0
        }
        $entry = [pscustomobject]@{
            ExchangeGuid = '66666666-6666-6666-6666-666666666666'
            PrimarySmtpAddress = 'unmapped@contoso.com'; Samples = @($sample)
        }
        $invalidValues = @(
            @{ Field = 'QuotaGB'; Value = -1 }, @{ Field = 'QuotaGB'; Value = 0 },
            @{ Field = 'QuotaGB'; Value = 'invalid' }, @{ Field = 'QuotaGB'; Value = 'Infinity' },
            @{ Field = 'ArchiveEnabled'; Value = 'invalid' }, @{ Field = 'ArchiveEnabled'; Value = $null },
            @{ Field = 'ArchiveSizeGB'; Value = -1 }, @{ Field = 'ArchiveSizeGB'; Value = 'NaN' },
            @{ Field = 'ArchiveSizeGB'; Value = $null }, @{ Field = 'ArchiveItemCount'; Value = -1 },
            @{ Field = 'ArchiveItemCount'; Value = 0.5 }, @{ Field = 'ArchiveItemCount'; Value = $null }
        )
        foreach ($invalid in $invalidValues) {
            $original = $sample.($invalid.Field)
            $sample.($invalid.Field) = $invalid.Value
            [pscustomobject]@{ MailboxHistory = @($entry) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:graphHistoryPath
            $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
            Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
            (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
            $sample.($invalid.Field) = $original
        }
        $script:graphRequestCount | Should Be 0
    }

    It 'rejects untouched unmapped entries with empty samples or SMTP before any request or write' {
        $unmapped = [pscustomobject]@{
            ExchangeGuid = '66666666-6666-6666-6666-666666666666'
            PrimarySmtpAddress = 'unmapped@contoso.com'; Samples = @()
        }
        [pscustomobject]@{ MailboxHistory = @($unmapped) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:graphHistoryPath
        $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
        $unmapped.Samples = @([pscustomobject]@{
            TimestampUtc = '2026-09-29T00:00:00Z'; SizeGB = 1; ItemCount = 50
            QuotaGB = 2; ArchiveEnabled = $false; ArchiveSizeGB = 0; ArchiveItemCount = 0
        })
        $unmapped.PrimarySmtpAddress = ''
        [pscustomobject]@{ MailboxHistory = @($unmapped) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:graphHistoryPath
        $before = Get-Content -LiteralPath $script:graphHistoryPath -Raw
        Assert-GraphCollectionThrows { Invoke-TestGraphCollection }
        (Get-Content -LiteralPath $script:graphHistoryPath -Raw) | Should Be $before
        $script:graphRequestCount | Should Be 0
    }

    It 'validates real Graph collector output through snapshot generation and both JSON readers' {
        $result = Invoke-TestGraphCollection
        $dataPath = Join-Path $script:graphTestRoot 'data.json'
        $configPath = Join-Path $script:graphTestRoot 'config.json'
        @{
            Paths = @{
                HistoryJson = $script:graphHistoryPath
                DataJson = $dataPath
            }
            Logging = @{ Enabled = $false }
            Console = @{ ShowPerItem = $false; ShowProgress = $false }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

        & (Join-Path $collectorRoot 'Generate-MailboxSnapshot.ps1') -ConfigPath $configPath | Out-Null
        $reports = @(& (Join-Path $collectorRoot 'Test-MailboxDashboardJSON.ps1') -ConfigPath $configPath -Target Both)
        $reports.Count | Should Be 2
        @($reports | Where-Object { -not $_.IsValid }).Count | Should Be 0
        $snapshot = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json
        $snapshot.Mailboxes[0].ExchangeGuid | Should Be $script:graphExchangeGuid
        $snapshot.Mailboxes[0].DataAvailability.ReportRefreshDate | Should Be '2026-09-30'
        $snapshot.Mailboxes[0].Licensing.RecipientTypeDetails | Should Be 'UserMailbox'
        $snapshot.Mailboxes[0].current.archiveSizeGB | Should Be $null
        $snapshot.Mailboxes[0].permissions | Should Be $null
        $result.Collected | Should Be 1
    }
}

if (Get-Variable -Name graphCreatedRequestStub -Scope Script -ErrorAction SilentlyContinue) {
    Remove-Item Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
}
if (Get-Variable -Name graphCreatedContextStub -Scope Script -ErrorAction SilentlyContinue) {
    Remove-Item Function:\Get-MgContext -ErrorAction SilentlyContinue
}
