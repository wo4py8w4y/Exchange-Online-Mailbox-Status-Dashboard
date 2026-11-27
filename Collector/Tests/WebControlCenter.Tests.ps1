$collectorRoot = Split-Path -Path $PSScriptRoot -Parent
$repositoryRoot = Split-Path -Path $collectorRoot -Parent
$webRoot = Join-Path $repositoryRoot "Web"
$reportingPath = Join-Path $webRoot "modern\reporting.js"

Describe "Exchange Control Center web reporting" {
    It "builds stable aggregate and report values from normalized mailboxes" {
        $node = Get-Command node -ErrorAction Stop
        $script = @"
const reporting = require(process.argv[1]);
const now = Date.parse('2026-11-27T00:00:00Z');
const mailboxes = [
  { name: 'Warning mailbox', smtp: 'warning@contoso.com', type: 'UserMailbox', totalGB: 90, archiveGB: 10, quotaGB: 100, usagePercent: 90, status: 'warning', archiveEnabled: true, lastLogon: '2026-11-26T00:00:00Z', licenseRequired: true, hasLicense: false, licenseType: '', retentionPolicy: '', litigationHold: false, permissions: [{ User: 'delegate@contoso.com', AccessRights: ['FullAccess'], IsInherited: false }] },
  { name: 'Over quota mailbox', smtp: 'over@contoso.com', type: 'SharedMailbox', totalGB: 55, archiveGB: 0, quotaGB: 50, usagePercent: 110, status: 'over', archiveEnabled: false, lastLogon: '2026-01-01T00:00:00Z', licenseRequired: false, hasLicense: false, licenseType: '', retentionPolicy: 'Default MRM Policy', litigationHold: true, permissions: [] }
];
const summary = reporting.aggregate(mailboxes, now);
const capacity = reporting.buildReport('capacity', mailboxes, now);
const permissions = reporting.buildReport('permissions', mailboxes, now);
console.log(JSON.stringify({
  summary,
  firstCapacityMailbox: capacity.rows[0][0],
  permissionRows: permissions.rows.length,
  csvHeader: reporting.toCsv(capacity).split('\\r\\n')[0],
  unknownStatus: reporting.statusOf({ quotaGB: null, usagePercent: null })
}));
"@
        $raw = & $node.Source -e $script $reportingPath 2>&1
        $LASTEXITCODE | Should Be 0
        $result = (($raw | Out-String).Trim() | ConvertFrom-Json)

        $result.summary.mailboxCount | Should Be 2
        $result.summary.primaryGB | Should Be 145
        $result.summary.warningCount | Should Be 1
        $result.summary.overQuotaCount | Should Be 1
        $result.summary.inactive90Count | Should Be 1
        $result.summary.licenseGapCount | Should Be 1
        $result.summary.noRetentionPolicyCount | Should Be 1
        $result.summary.delegationCount | Should Be 1
        $result.firstCapacityMailbox | Should Be "Over quota mailbox"
        $result.permissionRows | Should Be 1
        $result.csvHeader | Should Match '"Mailbox","SMTP address".*"Status"'
        $result.unknownStatus | Should Be "unlimited"
    }

    It "rejects an unknown report type instead of producing a misleading empty export" {
        $node = Get-Command node -ErrorAction Stop
        $script = @"
const reporting = require(process.argv[1]);
try {
  reporting.buildReport('invented', []);
  process.exitCode = 2;
} catch (error) {
  console.log(error.name + ':' + error.message);
}
"@
        $raw = & $node.Source -e $script $reportingPath 2>&1
        $LASTEXITCODE | Should Be 0
        (($raw | Out-String).Trim()) | Should Match "^RangeError:Unknown report type"
    }

    It "keeps the control center entry point wired to reports, settings, and compatibility views" {
        $index = Get-Content -LiteralPath (Join-Path $webRoot "index.html") -Raw
        $index | Should Match 'id="collectionHealth"'
        $index | Should Match 'href="reports\.html"'
        $index | Should Match 'href="settings\.html"'
        $index | Should Match 'href="classic\.html"'
        $index | Should Match 'src="modern/reporting\.js"'
        Test-Path -LiteralPath (Join-Path $webRoot "reports.html") | Should Be $true
        Test-Path -LiteralPath (Join-Path $webRoot "settings.html") | Should Be $true
        Test-Path -LiteralPath (Join-Path $webRoot "classic.html") | Should Be $true
    }

    It "ships valid themes with the background and accent fields required by the UI" {
        $themes = Get-Content -LiteralPath (Join-Path $webRoot "modern\themes.json") -Raw | ConvertFrom-Json
        @($themes).Count | Should BeGreaterThan 7
        foreach ($theme in @($themes)) {
            $theme.name | Should Not BeNullOrEmpty
            $theme.background | Should Match "^#[0-9A-Fa-f]{6}$"
            $theme.foreground | Should Match "^#[0-9A-Fa-f]{6}$"
            $theme.blue | Should Match "^#[0-9A-Fa-f]{6}$"
        }
    }
}
