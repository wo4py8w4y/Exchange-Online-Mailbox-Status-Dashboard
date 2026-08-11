[CmdletBinding()]
param(
    [string]$TempDir = ".\Temp\ThreadJobs",
    [string]$HistoryPath = "..\Web\history.json"
)

Write-Host "Merging Threaded JSON Files..." -ForegroundColor Cyan

# 1. Grab all individual thread files
$ThreadFiles = Get-ChildItem -Path $TempDir -Filter "*.json"
if ($ThreadFiles.Count -eq 0) {
    Write-Warning "No thread files found in $TempDir. Run Start-HistoryCollectorThreaded.ps1 first."
    return
}

# 2. Load the existing history database safely
$HistoryDB = if (Test-Path $HistoryPath) { 
    Get-Content $HistoryPath -Raw | ConvertFrom-Json -AsHashtable 
} else { 
    @{} 
}

# 3. Process each temp file
$MergeCount = 0
foreach ($File in $ThreadFiles) {
    try {
        $RawData = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $Guid = $RawData.ExchangeGuid

        $UsagePct = if ($RawData.QuotaGB -gt 0) { [math]::Round(($RawData.SizeGB / $RawData.QuotaGB) * 100, 1) } else { 0 }

        # Build the exact historical schema the dashboard charts expect
        $Sample = [ordered]@{
            TimestampUtc       = $RawData.TimestampUtc
            PrimarySmtpAddress = $RawData.PrimarySmtpAddress
            DisplayName        = $RawData.DisplayName
            SizeGB             = $RawData.SizeGB
            ItemCount          = $RawData.ItemCount
            PermissionCount    = if ($RawData.Permissions) { @($RawData.Permissions).Count } else { 0 }
            QuotaGB            = $RawData.QuotaGB
            UsagePercent       = $UsagePct
            LastLogonTime      = $RawData.LastLogonTime
            ArchiveEnabled     = $RawData.ArchiveEnabled
            ArchiveSizeGB      = $RawData.ArchiveSizeGB
            ArchiveItemCount   = $RawData.ArchiveItemCount
            Permissions        = $RawData.Permissions
        }

        # Safely append to the array inside the hashtable
        if (-not $HistoryDB.ContainsKey($Guid)) {
            $HistoryDB[$Guid] = [System.Collections.Generic.List[object]]::new()
        } else {
            # Convert existing array to a Generic List so we can use .Add()
            $HistoryDB[$Guid] = [System.Collections.Generic.List[object]]::new($HistoryDB[$Guid])
        }
        
        $HistoryDB[$Guid].Add($Sample)
        $MergeCount++

    } catch {
        Write-Warning "Failed to merge data from $($File.Name)"
    }
}

# 4. Save the merged database back to disk
Write-Host "Saving merged history for $MergeCount mailboxes..." -ForegroundColor Cyan
$HistoryDB | ConvertTo-Json -Depth 10 | Set-Content $HistoryPath -Encoding utf8

Write-Host "Merge complete!" -ForegroundColor Green