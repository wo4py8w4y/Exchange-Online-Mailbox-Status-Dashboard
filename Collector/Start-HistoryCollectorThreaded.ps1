[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath "Config\dashboardConfig.json"),

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BatchSize = 50,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [string]$HistoryJsonPath,

    [Parameter()]
    [string]$HotDataJsonPath,

    [Parameter()]
    [string]$TimestampUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$historyCollectorPath = Join-Path -Path $PSScriptRoot -ChildPath "HistoryCollector.ps1"

if (-not (Test-Path -LiteralPath $historyCollectorPath)) {
    throw "History collector not found at '$historyCollectorPath'."
}

Write-Host "Starting mailbox collection pipeline..." -ForegroundColor Cyan

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
