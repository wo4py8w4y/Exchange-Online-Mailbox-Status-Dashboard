<#
.SYNOPSIS
    Unified multi-threaded Exchange Online Mailbox Collector.
.DESCRIPTION
    Replaces older threaded collectors and MergeJSON utilities. Gathers primary 
    stats, archive stats, and explicit permissions in parallel memory threads, 
    then commits safely to the history database in a single disk write.
#>
[CmdletBinding()]
param(
    [string]$HistoryPath = "..\Web\history.json",
    [int]$MaxThreads = 15
)

Write-Host "Gathering Mailboxes from Exchange Online..." -ForegroundColor Cyan
# Ensure you are connected to Exchange Online before running this
$Mailboxes = Get-EXOMailbox -ResultSize Unlimited -PropertySets Minimum, Archive
$TimestampUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Processing $($Mailboxes.Count) mailboxes in parallel (Max Threads: $MaxThreads)..." -ForegroundColor Cyan

# 1. Parallel Collection (Data is saved to MEMORY, not disk)
$ThreadedResults = $Mailboxes | ForEach-Object -Parallel {
    $mbx = $_
    $Guid = $mbx.ExchangeGuid.Guid

    # Fetch primary statistics
    $PrimaryStats = Get-EXOMailboxStatistics -Identity $Guid
    
    # Fetch archive statistics (if enabled)
    $ArchiveStats = $null
    if ($mbx.ArchiveStatus -eq 'Active') {
        $ArchiveStats = try { Get-EXOMailboxStatistics -Identity $Guid -Archive } catch { $null }
    }

    # Fetch explicitly delegated permissions
    $Perms = Get-EXOMailboxPermission -Identity $Guid | 
        Where-Object { $_.User -notmatch 'NT AUTHORITY|S-1-5' -and $_.IsInherited -eq $false -and $_.User -ne $mbx.PrimarySmtpAddress }

    # Return a structured record directly to the pipeline
    [PSCustomObject]@{
        ExchangeGuid       = $Guid
        PrimarySmtpAddress = $mbx.PrimarySmtpAddress
        DisplayName        = $mbx.DisplayName
        TimestampUtc       = $using:TimestampUtc
        SizeGB             = if ($PrimaryStats.TotalItemSize.Value) { [math]::Round($PrimaryStats.TotalItemSize.Value.ToGB(), 2) } else { 0 }
        ItemCount          = $PrimaryStats.ItemCount
        QuotaGB            = 50.0 # Adjust this based on your tenant's default quota
        LastLogonTime      = $PrimaryStats.LastLogonTime
        ArchiveEnabled     = ($mbx.ArchiveStatus -eq 'Active')
        ArchiveSizeGB      = if ($ArchiveStats -and $ArchiveStats.TotalItemSize.Value) { [math]::Round($ArchiveStats.TotalItemSize.Value.ToGB(), 2) } else { 0 }
        ArchiveItemCount   = if ($ArchiveStats) { $ArchiveStats.ItemCount } else { 0 }
        Permissions        = $Perms
    }
} -ThrottleLimit $MaxThreads

Write-Host "Processing complete. Updating history database..." -ForegroundColor Cyan

# 2. Load Existing History Database
$HistoryDB = if (Test-Path $HistoryPath) { 
    Get-Content $HistoryPath -Raw | ConvertFrom-Json -AsHashtable 
} else { 
    @{} 
}

# 3. Build Final Structures
foreach ($Result in $ThreadedResults) {
    $Guid = $Result.ExchangeGuid

    # Calculate Usage Percentage
    $UsagePct = if ($Result.QuotaGB -gt 0) { [math]::Round(($Result.SizeGB / $Result.QuotaGB) * 100, 1) } else { 0 }

    # Create the Historical Sample
    $Sample = [ordered]@{
        TimestampUtc     = $Result.TimestampUtc
        PrimarySmtpAddress = $Result.PrimarySmtpAddress
        DisplayName      = $Result.DisplayName
        SizeGB           = $Result.SizeGB
        ItemCount        = $Result.ItemCount
        PermissionCount  = if ($Result.Permissions) { @($Result.Permissions).Count } else { 0 }
        QuotaGB          = $Result.QuotaGB
        UsagePercent     = $UsagePct
        LastLogonTime    = $Result.LastLogonTime
        ArchiveEnabled   = $Result.ArchiveEnabled
        ArchiveSizeGB    = $Result.ArchiveSizeGB
        ArchiveItemCount = $Result.ArchiveItemCount
        Permissions      = $Result.Permissions
    }

    # Append to History Database (Keyed by GUID)
    if (-not $HistoryDB.ContainsKey($Guid)) {
        $HistoryDB[$Guid] = [System.Collections.Generic.List[object]]::new()
    } else {
        # Ensure it acts as a list when appending
        $HistoryDB[$Guid] = [System.Collections.Generic.List[object]]::new($HistoryDB[$Guid])
    }
    $HistoryDB[$Guid].Add($Sample)
}

# 4. Perform Single Disk Write (Prevents all file-lock and overwrite bugs)
Write-Host "Writing $($HistoryDB.Keys.Count) mailboxes to disk..." -ForegroundColor Cyan

$HistoryDB | ConvertTo-Json -Depth 10 | Set-Content $HistoryPath -Encoding utf8

Write-Host "History update completed successfully!" -ForegroundColor Green