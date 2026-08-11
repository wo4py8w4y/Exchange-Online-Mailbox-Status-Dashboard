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

# 1. Load the raw JSON
$RawData = Get-Content $HistoryPath -Raw | ConvertFrom-Json

# 2. Handle the mixed array (Skip the first item if it's a timestamp string)
$Mailboxes = if ($RawData[0] -is [string]) { 
    $RawData[1..($RawData.Count - 1)] 
} else { 
    $RawData 
}

$HotDataList = [System.Collections.Generic.List[object]]::new()

# 3. Iterate, flatten, and extract the latest sample
foreach ($mbx in $Mailboxes) {
    # Safety check: Ensure it has the Samples array
    if ($null -eq $mbx.Samples -or $mbx.Samples.Count -eq 0) { continue }

    # Grab the very last sample in the array (the newest one)
    $LatestSample = $mbx.Samples[-1]

    # Map the nested data to a flat object for the HTML frontend
    $FlatRecord = [ordered]@{
        ExchangeGuid       = $mbx.ExchangeGuid
        PrimarySmtpAddress = $mbx.PrimarySmtpAddress
        DisplayName        = $mbx.DisplayName
        MailboxSizeGB      = $LatestSample.SizeGB
        ItemCount          = $LatestSample.ItemCount
        PermissionCount    = $LatestSample.PermissionCount
        QuotaGB            = $LatestSample.QuotaGB
        UsagePercent       = $LatestSample.UsagePercent
        LastLogonTime      = $LatestSample.LastLogonTime
        ArchiveEnabled     = $LatestSample.ArchiveEnabled
        ArchiveSizeGB      = $LatestSample.ArchiveSizeGB
        ArchiveItemCount   = $LatestSample.ArchiveItemCount
    }
    
    $HotDataList.Add($FlatRecord)
}

# 4. Save the cleanly formatted Hot Data payload
$HotDataList | ConvertTo-Json -Depth 10 | Set-Content $HotDataPath -Encoding utf8

Write-Host "Successfully extracted and flattened $($HotDataList.Count) active records to $HotDataPath" -ForegroundColor Green