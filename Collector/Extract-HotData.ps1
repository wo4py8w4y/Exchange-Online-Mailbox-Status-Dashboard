[CmdletBinding()]
param (
    [string]$HistoryPath = ".\history.json",
    [string]$HotDataPath = ".\data.json"
)

Write-Host "Extracting Hot Data from History..." -ForegroundColor Cyan

# 1. Load the Historical Database (using PS7 AsHashtable for speed)
if (-not (Test-Path $HistoryPath)) {
    Write-Error "History file not found at $HistoryPath"
    return
}

$HistoryDB = Get-Content $HistoryPath -Raw | ConvertFrom-Json -AsHashtable
$HotDataList = [System.Collections.Generic.List[object]]::new()

# 2. Iterate and extract the latest snapshot for each Mailbox
foreach ($Guid in $HistoryDB.Keys) {
    $Records = $HistoryDB[$Guid]
    
    # Assuming your collector appends to the array, the last item [-1] is the newest.
    # If it prepends, change this to [0].
    $LatestRecord = $Records[-1] 

    # Ensure the ExchangeGuid is attached to the hot record for UI reference
    $LatestRecord | Add-Member -MemberType NoteProperty -Name "ExchangeGuid" -Value $Guid -Force
    
    $HotDataList.Add($LatestRecord)
}

# 3. Save the Hot Data payload
$HotDataList | ConvertTo-Json -Depth 10 | Set-Content $HotDataPath -Encoding utf8

Write-Host "Successfully extracted $($HotDataList.Count) active records to $HotDataPath" -ForegroundColor Green