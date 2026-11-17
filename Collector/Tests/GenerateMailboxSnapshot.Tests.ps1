$collectorRoot = Split-Path -Path $PSScriptRoot -Parent
$generatorPath = Join-Path $collectorRoot "Generate-MailboxSnapshot.ps1"

Describe "MailboxDashboard history snapshot generation" {
    BeforeEach {
        $testRoot = Join-Path $PSScriptRoot ("MailboxDashboard.SnapshotTests." + [guid]::NewGuid().ToString("N"))
        $null = New-Item -Path $testRoot -ItemType Directory -Force
        $historyPath = Join-Path $testRoot "history.json"
        $dataPath = Join-Path $testRoot "data.json"
        $configPath = Join-Path $testRoot "dashboardConfig.json"
        $config = [pscustomobject]@{
            Paths = [pscustomobject]@{
                HistoryJson = $historyPath
                DataJson = $dataPath
            }
        }
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }

    AfterEach {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    function New-TestSample {
        param(
            [string]$TimestampUtc = (Get-Date).ToUniversalTime().ToString("o"),
            [double]$SizeGB = 10,
            [double]$QuotaGB = 20,
            [long]$ItemCount = 100
        )

        return [pscustomobject]@{
            TimestampUtc = $TimestampUtc
            SizeGB = $SizeGB
            ItemCount = $ItemCount
            QuotaGB = $QuotaGB
            UsagePercent = 0
            LastLogonTime = $null
            ArchiveEnabled = $false
            ArchiveSizeGB = 0
            ArchiveItemCount = 0
        }
    }

    function New-TestMailbox {
        param(
            [string]$ExchangeGuid = "e45d71d0-1111-2222-3333-123456789abc",
            [object[]]$Samples = @((New-TestSample))
        )

        return [pscustomobject]@{
            ExchangeGuid = $ExchangeGuid
            PrimarySmtpAddress = "mailbox@contoso.com"
            DisplayName = "Test mailbox"
            Samples = $Samples
        }
    }

    function Write-TestHistory {
        param([object[]]$Mailboxes)

        $document = [pscustomobject]@{
            GeneratedUtc = (Get-Date).ToUniversalTime().ToString("o")
            MailboxHistory = $Mailboxes
        }
        $document | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $historyPath -Encoding UTF8
    }

    function Write-ExistingSnapshot {
        Set-Content -LiteralPath $dataPath -Value '{"GeneratedUtc":"old","Mailboxes":[]}' -Encoding UTF8
    }

    function Get-GeneratorFailure {
        param([hashtable]$Parameters)
        try {
            & $generatorPath @Parameters | Out-Null
        }
        catch {
            return $_.Exception.Message
        }
        return $null
    }

    function New-GraphTestMailbox {
        $sample = New-TestSample -TimestampUtc '2026-09-28T00:00:00Z' -ItemCount 1500000
        $sample.ArchiveEnabled = $null
        $sample.ArchiveSizeGB = $null
        $sample.ArchiveItemCount = $null
        $metadata = [pscustomobject]@{
            Source = 'MicrosoftGraph'
            ReportRefreshDate = '2026-09-28'
            UnavailableFields = @('ArchiveSizeGB', 'ArchiveItemCount', 'Permissions', 'LastLogonTime', 'Retention', 'RecipientTypeDetails', 'LicenseRequired')
        }
        $sample | Add-Member DataAvailability $metadata
        $sample | Add-Member PermissionCount $null
        $sample | Add-Member LastActivityDate '2026-09-25'
        $mailbox = New-TestMailbox -Samples @($sample)
        $mailbox | Add-Member DataAvailability $metadata
        $mailbox | Add-Member Permissions $null
        $mailbox | Add-Member Retention $null
        $mailbox | Add-Member Licensing ([pscustomobject]@{ HasLicense = $true; LicenseRequired = $null; IsLicenseCompliant = $null; RecipientTypeDetails = $null; LicenseTypes = @('sku-id') })
        return $mailbox
    }

    It "preserves Graph unavailable nulls and report dates through snapshot validation and recovery" {
        Write-TestHistory -Mailboxes @((New-GraphTestMailbox))
        & $generatorPath -ConfigPath $configPath | Out-Null
        $validatorPath = Join-Path $collectorRoot 'Test-MailboxDashboardJSON.ps1'
        & $validatorPath -ConfigPath $configPath -Repair -NoBackup | Out-Null
        $snapshot = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json
        $mailbox = $snapshot.Mailboxes[0]
        $mailbox.DataAvailability.Source | Should Be 'MicrosoftGraph'
        $mailbox.current.archiveEnabled | Should Be $null
        $mailbox.current.archiveSizeGB | Should Be $null
        $mailbox.current.archiveItemCount | Should Be $null
        $mailbox.current.lastActivityDate | Should Be '2026-09-25'
        $mailbox.permissions | Should Be $null
        $mailbox.Licensing.LicenseRequired | Should Be $null
        ([datetime]$mailbox.current.sampleTimestamp).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') | Should Be '2026-09-28T00:00:00'
        $history = Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json
        $history.MailboxHistory[0].Samples[0].PermissionCount | Should Be $null
        $history.MailboxHistory[0].Samples = @()
        $history | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $historyPath -Encoding UTF8
        & $validatorPath -ConfigPath $configPath -Repair -RestoreSamplesFromData -NoBackup | Out-Null
        $restored = (Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json).MailboxHistory[0].Samples[0]
        $restored.DataAvailability.Source | Should Be 'MicrosoftGraph'
        $restored.ArchiveEnabled | Should Be $null
        $restored.ArchiveSizeGB | Should Be $null
        $restored.ArchiveItemCount | Should Be $null
        $restored.PermissionCount | Should Be $null
        $restored.ItemCount | Should Be 1500000
        $restored.LastActivityDate | Should Be '2026-09-25'
    }

    It "ignores stale record availability when the latest sample is Exchange" {
        $mailbox = New-GraphTestMailbox
        $mailbox.Samples += New-TestSample -TimestampUtc '2026-09-30T12:00:00Z' -SizeGB 12
        Write-TestHistory -Mailboxes @($mailbox)
        & $generatorPath -ConfigPath $configPath | Out-Null
        $result = (Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json).Mailboxes[0]
        $result.PSObject.Properties.Name -contains 'DataAvailability' | Should Be $false
        $result.current.archiveSizeGB | Should Be 0
        $result.current.totalGB | Should Be 12
    }

    It "preserves known Graph mailbox purpose and archive presence without inferring compliance" {
        $mailbox = New-GraphTestMailbox
        $sample = $mailbox.Samples[0]
        $sample.DataAvailability.UnavailableFields = @($sample.DataAvailability.UnavailableFields | Where-Object { $_ -ne 'RecipientTypeDetails' })
        $sample.ArchiveEnabled = $true
        $sample | Add-Member Licensing ([pscustomobject]@{
            HasLicense = $true; RecipientTypeDetails = 'SharedMailbox'
            LicenseRequired = $null; IsLicenseCompliant = $null
        })
        Write-TestHistory -Mailboxes @($mailbox)
        & $generatorPath -ConfigPath $configPath | Out-Null
        $result = (Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json).Mailboxes[0]
        $result.Licensing.RecipientTypeDetails | Should Be 'SharedMailbox'
        $result.Licensing.LicenseRequired | Should Be $null
        $result.Licensing.IsLicenseCompliant | Should Be $null
        $result.current.archiveEnabled | Should Be $true
        $result.DataAvailability.UnavailableFields -contains 'RecipientTypeDetails' | Should Be $false
    }

    It "does not let Graph availability bypass required metrics or timestamps" {
        $mailbox = New-GraphTestMailbox
        $mailbox.Samples[0].SizeGB = $null
        Write-TestHistory -Mailboxes @($mailbox)
        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        $mailbox.Samples[0].SizeGB = 10
        $mailbox.Samples[0].TimestampUtc = 'invalid'
        Write-TestHistory -Mailboxes @($mailbox)
        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
    }

    It "validates required Graph fields while accepting explicit unavailable nulls" {
        $mailbox = New-GraphTestMailbox
        $mailbox.Samples[0].ItemCount = 'invalid'
        $mailbox.Samples[0].TimestampUtc = 'invalid'
        Write-TestHistory -Mailboxes @($mailbox)
        $validatorPath = Join-Path $collectorRoot 'Test-MailboxDashboardJSON.ps1'
        $report = & $validatorPath -ConfigPath $configPath -Target History
        $report.IsValid | Should Be $false
        ($report.Problems -join ' ') | Should Match 'ItemCount'
        ($report.Problems -join ' ') | Should Match 'TimestampUtc'
        ($report.Problems -join ' ') | Should Not Match 'ArchiveSizeGB|ArchiveItemCount|PermissionCount'
    }

    It "keeps unavailable values in the dashboard reader merges exports and charts" {
        $dashboardPath = Join-Path (Split-Path $collectorRoot -Parent) 'Web\dashboard.js'
        $code = @'
const fs = require("fs"), vm = require("vm"), assert = require("assert");
const context = vm.createContext({ window: {}, document: { addEventListener() {} }, console });
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), context);
vm.runInContext(`
const availability = { Source: "MicrosoftGraph", ReportRefreshDate: "2026-09-28",
    UnavailableFields: ["ArchiveSizeGB", "ArchiveItemCount", "Permissions", "LastLogonTime", "Retention", "RecipientTypeDetails", "LicenseRequired"] };
const graph = { ExchangeGuid: "guid", PrimarySmtpAddress: "mail@example.com", DataAvailability: availability,
    Permissions: null, Retention: null, Licensing: { HasLicense: true, LicenseRequired: null, IsLicenseCompliant: null },
    Samples: [{ TimestampUtc: "2026-09-28T00:00:00Z", SizeGB: 10, ItemCount: 100, QuotaGB: 20,
        ArchiveEnabled: null, ArchiveSizeGB: null, ArchiveItemCount: null, PermissionCount: null, DataAvailability: availability }] };
const historyMailbox = normaliseMailbox(graph);
const snapshotMailbox = normaliseMailbox({ ...graph, Samples: undefined,
    current: { totalGB: 10, itemCount: 100, quotaGB: 20, archiveEnabled: null, archiveSizeGB: null,
        archiveItemCount: null, sampleTimestamp: "2026-09-28T00:00:00Z" } });
const exo = normaliseMailbox({ ExchangeGuid: "guid", Permissions: [{ User: "delegate" }],
    Samples: [{ TimestampUtc: "2026-09-27T00:00:00Z", SizeGB: 8, ArchiveSizeGB: 3 }] });
const newerExo = normaliseMailbox({ ExchangeGuid: "guid", DataAvailability: availability,
    Samples: [{ TimestampUtc: "2026-09-30T00:00:00Z", SizeGB: 12, ArchiveSizeGB: 4 }] });
globalThis.result = { historyMailbox, snapshotMailbox,
    merged: mergeMailbox(exo, snapshotMailbox), newer: mergeMailbox(newerExo, snapshotMailbox),
    permissionCount: getPermissionCount(snapshotMailbox), retention: getRetentionLabel(snapshotMailbox),
    exported: TABLE_EXPORT_CONFIG.usageTable.toExportRow(snapshotMailbox),
    sample: normaliseHistorySamples(graph.Samples)[0], format: formatGB(null) };
drawRingChart = (id, segments, label) => { globalThis.ring = { segments, label }; };
getChartColor = () => "#000";
drawMailboxStorageRing("chart", snapshotMailbox);
const elements = { totalArchiveStorage: {} };
document.getElementById = id => elements[id] || null;
document.createElement = () => ({ setAttribute(name, value) { this[name] = value; } });
document.querySelector = () => ({ prepend(element) { elements[element.id] = element; } });
state.currentMailboxes = [snapshotMailbox, newerExo];
renderDataAvailability();
updateTopCards(state.currentMailboxes);
globalThis.banner = elements.dataAvailabilityStatus;
globalThis.archiveTotal = elements.totalArchiveStorage.textContent;
const knownAvailability = { ...availability, UnavailableFields: availability.UnavailableFields.filter(field => field !== "RecipientTypeDetails") };
const knownPurpose = normaliseMailbox({ ...graph, Samples: [{ ...graph.Samples[0],
    DataAvailability: knownAvailability, ArchiveEnabled: true, RecipientTypeDetails: "SharedMailbox",
    Licensing: { HasLicense: true, RecipientTypeDetails: "SharedMailbox", LicenseRequired: null, IsLicenseCompliant: null } }] });
state.currentMailboxes = [knownPurpose];
renderDataAvailability();
globalThis.knownPurpose = knownPurpose;
globalThis.knownBannerText = elements.dataAvailabilityStatus.textContent;
`, context);
for (const mailbox of [context.result.historyMailbox, context.result.snapshotMailbox, context.result.merged]) {
    assert.strictEqual(mailbox.current.archiveEnabled, null);
    assert.strictEqual(mailbox.current.archiveSizeGB, null);
    assert.strictEqual(mailbox.current.archiveItemCount, null);
    assert.strictEqual(mailbox.licensing.licenseRequired, null);
    assert.strictEqual(mailbox.licensing.isLicenseCompliant, null);
    assert.strictEqual(mailbox.permissions.length, 0);
}
assert.strictEqual(context.result.newer.current.totalGB, 12);
assert.strictEqual(context.result.newer.dataAvailability, null);
assert.strictEqual(context.result.permissionCount, null);
assert.strictEqual(context.result.exported.permissions, null);
assert.strictEqual(context.result.exported.archiveSizeGB, null);
assert.strictEqual(context.result.sample.PermissionCount, null);
assert.strictEqual(context.result.sample.DataAvailability.Source, "MicrosoftGraph");
assert.strictEqual(context.result.format, "Unavailable");
assert.match(context.result.retention, /Unavailable/);
assert.strictEqual(context.ring.segments.some(segment => segment.label === "Archive"), false);
assert.strictEqual(context.archiveTotal, "Unavailable");
assert.strictEqual(context.banner.role, "status");
assert.match(context.banner.textContent, /2026-09-28/);
assert.match(context.banner.textContent, /GeneratedUtc.*not a live/);
assert.strictEqual(context.knownPurpose.licensing.recipientTypeDetails, "SharedMailbox");
assert.strictEqual(context.knownPurpose.licensing.licenseRequired, null);
assert.strictEqual(context.knownPurpose.licensing.isLicenseCompliant, null);
assert.strictEqual(context.knownPurpose.current.archiveEnabled, true);
assert.strictEqual(context.knownBannerText.includes("RecipientTypeDetails"), false);
assert.strictEqual(context.knownBannerText.includes("ArchiveEnabled"), false);
console.log("Dashboard Graph availability regressions passed.");
'@
        $code | & node - $dashboardPath
        $LASTEXITCODE | Should Be 0
    }

    It "selects the newest timestamp and calculates consistent usage metrics" {
        $older = (Get-Date).ToUniversalTime().AddDays(-2).ToString("o")
        $newer = (Get-Date).ToUniversalTime().ToString("o")
        $mailbox = New-TestMailbox -Samples @(
            (New-TestSample -TimestampUtc $older -SizeGB 2),
            (New-TestSample -TimestampUtc $newer -SizeGB 18)
        )
        Write-TestHistory -Mailboxes @($mailbox)

        & $generatorPath -ConfigPath $configPath | Out-Null
        $snapshot = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json

        @($snapshot.Mailboxes).Count | Should Be 1
        $snapshot.Mailboxes[0].current.totalGB | Should Be 18
        $snapshot.Mailboxes[0].current.usagePercent | Should Be 90
        ([datetime]$snapshot.Mailboxes[0].current.sampleTimestamp).ToUniversalTime().ToString("o") |
            Should Be ([datetime]$newer).ToUniversalTime().ToString("o")
        @(Get-ChildItem -LiteralPath $testRoot -Filter "*.writing").Count | Should Be 0
    }

    It "preserves singleton permission arrays in the generated dashboard record" {
        $mailbox = New-TestMailbox
        $mailbox | Add-Member -NotePropertyName Permissions -NotePropertyValue @(
            [pscustomobject]@{
                User = "delegate@contoso.com"
                AccessRights = @("FullAccess")
                Deny = $false
                IsInherited = $false
            }
        )
        Write-TestHistory -Mailboxes @($mailbox)

        & $generatorPath -ConfigPath $configPath | Out-Null
        $snapshot = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json

        @($snapshot.Mailboxes[0].permissions).Count | Should Be 1
        @($snapshot.Mailboxes[0].permissions[0].AccessRights).Count | Should Be 1
        $snapshot.Mailboxes[0].permissions[0].AccessRights[0] | Should Be "FullAccess"
    }

    It "refuses an empty history without replacing data unless explicitly allowed" {
        Write-TestHistory -Mailboxes @()
        Write-ExistingSnapshot

        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        (Get-Content -LiteralPath $dataPath -Raw).Trim() | Should Be '{"GeneratedUtc":"old","Mailboxes":[]}'

        & $generatorPath -ConfigPath $configPath -AllowEmptySnapshot | Out-Null
        $snapshot = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json
        @($snapshot.Mailboxes).Count | Should Be 0
    }

    It "rejects malformed records and preserves the previous snapshot" {
        $valid = New-TestMailbox
        $invalid = New-TestMailbox -ExchangeGuid "not-a-guid"
        Write-TestHistory -Mailboxes @($valid, $invalid)
        Write-ExistingSnapshot

        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        (Get-Content -LiteralPath $dataPath -Raw).Trim() | Should Be '{"GeneratedUtc":"old","Mailboxes":[]}'
    }

    It "rejects duplicate ExchangeGuid values instead of emitting duplicate dashboard records" {
        $first = New-TestMailbox
        $second = New-TestMailbox -ExchangeGuid "E45D71D0-1111-2222-3333-123456789ABC"
        Write-TestHistory -Mailboxes @($first, $second)
        Write-ExistingSnapshot

        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        (Get-Content -LiteralPath $dataPath -Raw).Trim() | Should Be '{"GeneratedUtc":"old","Mailboxes":[]}'
    }

    It "refuses invalid sample timestamps and incomplete current metrics without partial output" {
        $invalidTimestamp = New-TestMailbox -Samples @((New-TestSample -TimestampUtc "not-a-date"))
        Write-TestHistory -Mailboxes @($invalidTimestamp)
        Write-ExistingSnapshot

        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        (Get-Content -LiteralPath $dataPath -Raw).Trim() | Should Be '{"GeneratedUtc":"old","Mailboxes":[]}'

        $missingSize = New-TestSample
        $missingSize.SizeGB = $null
        Write-TestHistory -Mailboxes @((New-TestMailbox -Samples @($missingSize)))
        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        (Get-Content -LiteralPath $dataPath -Raw).Trim() | Should Be '{"GeneratedUtc":"old","Mailboxes":[]}'
    }

    It "never overwrites the history file when source and destination resolve to the same path" {
        Write-TestHistory -Mailboxes @((New-TestMailbox))
        $original = Get-Content -LiteralPath $historyPath -Raw
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.Paths.DataJson = $historyPath
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

        (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        (Get-Content -LiteralPath $historyPath -Raw) | Should Be $original
    }

    It "preserves the previous snapshot and removes staging files when a reader locks the destination" {
        Write-TestHistory -Mailboxes @((New-TestMailbox))
        Write-ExistingSnapshot
        $reader = [System.IO.File]::Open(
            $dataPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

        try {
            (Get-GeneratorFailure -Parameters @{ ConfigPath = $configPath }) | Should Not Be $null
        }
        finally {
            $reader.Dispose()
        }

        (Get-Content -LiteralPath $dataPath -Raw).Trim() | Should Be '{"GeneratedUtc":"old","Mailboxes":[]}'
        @(Get-ChildItem -LiteralPath $testRoot -Filter "*.writing").Count | Should Be 0
        @(Get-ChildItem -LiteralPath $testRoot -Filter "*.backup").Count | Should Be 0
    }
}
