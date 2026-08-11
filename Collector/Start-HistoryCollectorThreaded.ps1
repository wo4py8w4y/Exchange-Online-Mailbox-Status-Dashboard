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
# EXPLICITLY requesting ExchangeGuid to ensure the EXO module populates it
$Mailboxes = Get-EXOMailbox -ResultSize 200 -PropertySets Minimum, Archive -Properties ExchangeGuid, ExternalDirectoryObjectId
$TimestampUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
write-color -Color Yellow -BackGroundColor DarkBlue -Text "TEST MODE! ONLY PROCESSING 200 MAILBOXES"
Write-Host "Spawning threads for $($Mailboxes.Count) mailboxes..." -ForegroundColor Cyan

# 2. Run background threads in parallel
$Mailboxes | ForEach-Object -Parallel {
    $mbx = $_
    $OutDir = $using:TempDir
    $CurrentTime = $using:TimestampUtc

    # EXPLICIT EXTRACTION AND FALLBACK LOGIC
    $SafeIdentity = $null
    
    if ($null -ne $mbx.ExchangeGuid) {
        # Sometimes it's a string, sometimes it's an object with a .Guid property
        $SafeIdentity = if ($mbx.ExchangeGuid -is [string]) { $mbx.ExchangeGuid } else { $mbx.ExchangeGuid.Guid }
    }
    
    # Fallback to Entra ID Object ID, then finally PrimarySmtpAddress if GUID is completely missing
    if ([string]::IsNullOrWhiteSpace($SafeIdentity)) { $SafeIdentity = $mbx.ExternalDirectoryObjectId }
    if ([string]::IsNullOrWhiteSpace($SafeIdentity)) { $SafeIdentity = $mbx.PrimarySmtpAddress }

    # If it's STILL empty (highly unlikely), skip it safely
    if ([string]::IsNullOrWhiteSpace($SafeIdentity)) {
        Write-Warning "Skipping mailbox with missing Identifier: $($mbx.DisplayName)"
        return 
    }

    # Fetch stats
    $PrimaryStats = Get-EXOMailboxStatistics -Identity $SafeIdentity -Archive:$false
    
    $ArchiveStats = $null
    if ($mbx.ArchiveStatus -eq 'Active') {
        $ArchiveStats = try { Get-EXOMailboxStatistics -Identity $SafeIdentity -Archive } catch { $null }
    }

    $Perms = Get-EXOMailboxPermission -Identity $SafeIdentity | 
        Where-Object { $_.User -notmatch 'NT AUTHORITY|S-1-5' -and $_.IsInherited -eq $false -and $_.User -ne $mbx.PrimarySmtpAddress }

    # Build the record
    $Record = [ordered]@{
        ExchangeGuid       = $SafeIdentity
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

    # WRITE TO A UNIQUE TEMP FILE NAMED AFTER THE GUID OR SMTP
    $SafeFileName = ($SafeIdentity -replace '[\\/:*?"<>|]', '_') + ".json"
    $TempFilePath = Join-Path -Path $OutDir -ChildPath $SafeFileName
    $Record | ConvertTo-Json -Depth 10 | Set-Content -Path $TempFilePath -Encoding utf8

} -ThrottleLimit $MaxThreads

Write-Host "Threaded collection complete. Check $TempDir for files." -ForegroundColor Green