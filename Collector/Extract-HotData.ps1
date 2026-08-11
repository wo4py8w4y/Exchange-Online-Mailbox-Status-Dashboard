<#
.SYNOPSIS
    Generates a lightweight 'Hot Data' cache for the web dashboard.
.DESCRIPTION
    Reads the history.json database, extracts the most recent snapshot for every 
    mailbox, and formats it into a flat array schema expected by dashboard.js.
#>
[CmdletBinding()]
param (
    [string]$HistoryPath = "..\Web\history.json",
    [string]$HotDataPath = "..\Web\data.json"
)

Write-Host "Extracting Hot Data from History..." -ForegroundColor Cyan

if (-not (Test-Path $HistoryPath)) {
    Write-Error "History file not found at $HistoryPath"
    return
}

# 1. Load the Historical Database
$HistoryDB = Get-Content $HistoryPath -Raw | ConvertFrom-Json -AsHashtable

$HotDataList = [System.Collections.Generic.List[object]]::new()

# 2. Iterate and extract the latest snapshot for each Mailbox
foreach ($Guid in $HistoryDB.Keys) {
    $Records = $HistoryDB[$Guid]
    
    # Grab the very last sample in the array (the newest one)
    $LatestSample = $Records[-1] 

    # Map the nested data to the schema expected by the frontend
    $FlatRecord = [ordered]@{
        ExchangeGuid       = $Guid
        PrimarySmtpAddress = $LatestSample.PrimarySmtpAddress
        DisplayName        = $LatestSample.DisplayName
        MailboxSizeGB      = $LatestSample.SizeGB
        ItemCount          = $LatestSample.ItemCount
        PermissionCount    = $LatestSample.PermissionCount
        QuotaGB            = $LatestSample.QuotaGB
        UsagePercent       = $LatestSample.UsagePercent
        LastLogonTime      = $LatestSample.LastLogonTime
        ArchiveEnabled     = $LatestSample.ArchiveEnabled
        ArchiveSizeGB      = $LatestSample.ArchiveSizeGB
        ArchiveItemCount   = $LatestSample.ArchiveItemCount
        Permissions        = $LatestSample.Permissions
    }
    
    $HotDataList.Add($FlatRecord)
}

# 3. Save the neatly formatted Hot Data payload
$HotDataList | ConvertTo-Json -Depth 10 | Set-Content $HotDataPath -Encoding utf8

Write-Host "Successfully extracted and flattened $($HotDataList.Count) active records to $HotDataPath" -ForegroundColor Green