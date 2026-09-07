[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath ".\Collector\Config\dashboardConfig.json"),

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BatchSize = 50,
    
    [Parameter(HelpMessage = "Optional. If provided, the script will output the collected data to a CSV file at this path.")]
    [Parameter()]
    [string]$CsvPath = (Join-Path -Path $PSScriptRoot -ChildPath ".\Mailboxes\mailboxes.csv"),
   
    [Parameter(HelpMessage = "Optional. If provided, the script will output the collected history data to a JSON file at this path.")]
    [Parameter()]
    [string]$HistoryJsonPath = (Join-Path -Path $PSScriptRoot -ChildPath ".\Web\history.json"),
    
    [Parameter(HelpMessage = "Optional. If provided, the script will output the collected hot data to a JSON file at this path.")]
    [Parameter()]
    [string]$HotDataJsonPath = (Join-Path -Path $PSScriptRoot -ChildPath ".\Web\data.json"),
    
    [Parameter(HelpMessage = "Optional. If provided, the script will use this timestamp for the collection.")]
    [Parameter()]
    [string]$TimestampUtc
)


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$historyCollectorPath = Join-Path -Path $PSScriptRoot -ChildPath "HistoryCollector.ps1"

if (-not (Test-Path -LiteralPath $historyCollectorPath)) {
    throw "History collector not found at '$historyCollectorPath'."
}

Write-Host -ForegroundColor Cyan "Starting mailbox collection pipeline..."

$invocationParams = @{
    ConfigPath = $ConfigPath
    BatchSize  = $BatchSize
}

if ($PSBoundParameters.ContainsKey("CsvPath")) {
    $invocationParams.CsvPath = $CsvPath
}

if ($PSBoundParameters.ContainsKey("HistoryJsonPath")) {
    $invocationParams.HistoryJsonPath = $HistoryJsonPath
}

if ($PSBoundParameters.ContainsKey("HotDataJsonPath")) {
    $invocationParams.HotDataJsonPath = $HotDataJsonPath
}

if ($PSBoundParameters.ContainsKey("TimestampUtc")) {
    $invocationParams.TimestampUtc = $TimestampUtc
}

& $historyCollectorPath @invocationParams

Write-Host "Mailbox collection pipeline completed successfully." -ForegroundColor Green
& .\Collector\HistoryCollector.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json -BatchSize 50
& .\Collector\MergeJSON.ps1
& .\Collector\Extract-HotData.ps1 -ConfigPath .\Collector\Config\dashboardConfig.json -HistoryJsonPath .\Web\history.json -HotDataJsonPath .\Web\data.json