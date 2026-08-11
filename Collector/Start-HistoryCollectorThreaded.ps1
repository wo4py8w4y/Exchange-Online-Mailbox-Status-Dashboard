[CmdletBinding()]
param(
    [int]$MaxThreads = 15,
    [string]$TempDir = ".\Temp\ThreadJobs"
)

# 1. Setup Temp Directory
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
# Clear out yesterday's temp files so we don't merge old data
Remove-Item "$TempDir\*.json" -Force -ErrorAction SilentlyContinue

Write-Host "Gathering Mailbox list from Exchange Online..." -ForegroundColor Cyan
$Mailboxes = Get-EXOMailbox -ResultSize Unlimited -PropertySets Minimum, Archive
$TimestampUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Spawning threads for $($Mailboxes.Count) mailboxes..." -ForegroundColor Cyan

# 2. Run background threads in parallel
$Mailboxes | ForEach-Object -Parallel {
    $mbx = $_
    $Guid = $mbx.ExchangeGuid.Guid
    $OutDir = $using:TempDir
    $CurrentTime = $using:TimestampUtc

    # Fetch stats
    $PrimaryStats = Get-EXOMailboxStatistics -Identity $Guid
    
    $ArchiveStats = $null
    if ($mbx.ArchiveStatus -eq 'Active') {
        $ArchiveStats = try { Get-EXOMailboxStatistics -Identity $Guid -Archive } catch { $null }
    }

    $Perms = Get-EXOMailboxPermission -Identity $Guid | 
        Where-Object { $_.User -notmatch 'NT AUTHORITY|S-1-5' -and $_.IsInherited -eq $false -and $_.User -ne $mbx.PrimarySmtpAddress }

    # Build the record
    $Record = [ordered]@{
        ExchangeGuid       = $Guid
        PrimarySmtpAddress = $mbx.PrimarySmtpAddress
        DisplayName        = $mbx.DisplayName
        TimestampUtc       = $CurrentTime
        SizeGB             = if ($PrimaryStats.TotalItemSize.Value) { [math]::Round($PrimaryStats.TotalItemSize.Value.ToGB(), 2) } else { 0 }
        ItemCount          = $PrimaryStats.ItemCount
        QuotaGB            = 50.0 
        LastLogonTime      = $PrimaryStats.LastLogonTime
        ArchiveEnabled     = ($mbx.ArchiveStatus -eq 'Active')
        ArchiveSizeGB      = if ($ArchiveStats -and $ArchiveStats.TotalItemSize.Value) { [math]::Round($ArchiveStats.TotalItemSize.Value.ToGB(), 2) } else { 0 }
        ArchiveItemCount   = if ($ArchiveStats) { $ArchiveStats.ItemCount } else { 0 }
        Permissions        = $Perms
    }

    # WRITE TO A UNIQUE TEMP FILE NAMED AFTER THE GUID
    $TempFilePath = Join-Path -Path $OutDir -ChildPath "$Guid.json"
    $Record | ConvertTo-Json -Depth 10 | Set-Content -Path $TempFilePath -Encoding utf8

} -ThrottleLimit $MaxThreads

Write-Host "Threaded collection complete. Check $TempDir for files." -ForegroundColor Green