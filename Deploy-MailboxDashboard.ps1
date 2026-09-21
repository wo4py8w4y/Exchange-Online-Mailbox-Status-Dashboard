[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$DestinationRoot,

    [Parameter()]
    [string]$SourceRoot = $PSScriptRoot,

    [Parameter()]
    [switch]$OpenDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-DeploymentPath {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path.Trim())
}

function Read-DeploymentRoot {
    param(
        [string]$InitialValue
    )

    if (-not [string]::IsNullOrWhiteSpace($InitialValue)) {
        return Resolve-DeploymentPath -Path $InitialValue
    }

    while ($true) {
        $enteredPath = Read-Host "Enter the deployment root path (example: F:\Website\Qbuild-Mon)"
        if ([string]::IsNullOrWhiteSpace($enteredPath)) {
            Write-Warning "A deployment root path is required."
            continue
        }

        return Resolve-DeploymentPath -Path $enteredPath
    }
}

function Test-ExcludedDeploymentPath {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace("/", "\")

    foreach ($excludedPrefix in @(
        ".git\",
        ".github\",
        ".vs\",
        "Collector\Temp\",
        "Collector\Logs\"
    )) {
        if ($normalizedPath.StartsWith($excludedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    foreach ($excludedPattern in @(
        "Web\*.old.*",
        "Web\*Copy*",
        "Web\*.orig*",
        "Web\*.tmp",
        "Web\*.log"
    )) {
        if ($normalizedPath -like $excludedPattern) {
            return $true
        }
    }

    return $false
}

function Copy-DeploymentFile {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Read-DeploymentJsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $rawJson = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        return $null
    }

    return $rawJson | ConvertFrom-Json
}

function ConvertTo-DeploymentJson {
    param(
        [Parameter(Mandatory)]
        $InputObject,

        [int]$Depth = 100
    )

    return ConvertTo-Json -InputObject $InputObject -Depth $Depth
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($propertyName in $PropertyNames) {
        if ($Object.PSObject.Properties.Name -contains $propertyName) {
            $value = $Object.$propertyName
            if ($null -ne $value) {
                return $value
            }
        }
    }

    return $null
}

function Get-MailboxMergeKey {
    param(
        [Parameter(Mandatory)]
        $Record
    )

    $exchangeGuid = [string](Get-FirstPropertyValue -Object $Record -PropertyNames @("ExchangeGuid", "exchangeGuid"))
    if (-not [string]::IsNullOrWhiteSpace($exchangeGuid)) {
        return "guid::$exchangeGuid"
    }

    $smtpAddress = [string](Get-FirstPropertyValue -Object $Record -PropertyNames @("PrimarySmtpAddress", "primarySmtpAddress"))
    if (-not [string]::IsNullOrWhiteSpace($smtpAddress)) {
        return "smtp::$($smtpAddress.ToLowerInvariant())"
    }

    $displayName = [string](Get-FirstPropertyValue -Object $Record -PropertyNames @("DisplayName", "displayName"))
    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        return "name::$displayName"
    }

    return $null
}

function Get-SampleMergeKey {
    param(
        [Parameter(Mandatory)]
        $Sample
    )

    $timestampUtc = [string](Get-FirstPropertyValue -Object $Sample -PropertyNames @("TimestampUtc", "timestampUtc", "Timestamp", "timestamp"))
    if (-not [string]::IsNullOrWhiteSpace($timestampUtc)) {
        return "timestamp::$timestampUtc"
    }

    $signature = @(
        [string](Get-FirstPropertyValue -Object $Sample -PropertyNames @("SizeGB", "TotalGB", "totalGB"))
        [string](Get-FirstPropertyValue -Object $Sample -PropertyNames @("ItemCount", "itemCount"))
        [string](Get-FirstPropertyValue -Object $Sample -PropertyNames @("UsagePercent", "usagePercent"))
    ) -join "|"

    if (-not [string]::IsNullOrWhiteSpace($signature.Replace("|", ""))) {
        return "sample::$signature"
    }

    return $null
}

function Get-GeneratedUtcValue {
    param($Payload)

    foreach ($propertyName in @("GeneratedUtc", "generatedUtc")) {
        $value = $Payload.$propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return $null
}

function Get-DateTimeOffsetOrNull {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [datetimeoffset]::Parse($Value)
    }
    catch {
        return $null
    }
}

function Get-PreferredObject {
    param(
        $SourceObject,
        $DestinationObject,
        [Nullable[datetimeoffset]]$SourceGeneratedUtc,
        [Nullable[datetimeoffset]]$DestinationGeneratedUtc
    )

    if ($null -eq $DestinationObject) { return $SourceObject }
    if ($null -eq $SourceObject) { return $DestinationObject }

    if ($null -ne $SourceGeneratedUtc -and $null -ne $DestinationGeneratedUtc) {
        if ($SourceGeneratedUtc -ge $DestinationGeneratedUtc) {
            return $SourceObject
        }

        return $DestinationObject
    }

    if ($null -ne $SourceGeneratedUtc) { return $SourceObject }
    if ($null -ne $DestinationGeneratedUtc) { return $DestinationObject }

    return $SourceObject
}

function Merge-GenericValue {
    param(
        $PrimaryValue,
        $FallbackValue
    )

    if ($null -eq $PrimaryValue) { return $FallbackValue }
    if ($null -eq $FallbackValue) { return $PrimaryValue }

    if ($PrimaryValue -is [System.Management.Automation.PSCustomObject] -or $PrimaryValue -is [hashtable]) {
        return Merge-GenericObject -PrimaryObject $PrimaryValue -FallbackObject $FallbackValue
    }

    if ($PrimaryValue -is [System.Collections.IEnumerable] -and
        $PrimaryValue -isnot [string] -and
        $FallbackValue -is [System.Collections.IEnumerable] -and
        $FallbackValue -isnot [string]) {
        $primaryItems = @($PrimaryValue)
        $fallbackItems = @($FallbackValue)
        if ($primaryItems.Count -ge $fallbackItems.Count) {
            return $primaryItems
        }

        return $fallbackItems
    }

    if ($PrimaryValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($PrimaryValue)) {
            return $FallbackValue
        }

        $trimmedPrimary = $PrimaryValue.Trim()
        $trimmedFallback = if ($FallbackValue -is [string]) { $FallbackValue.Trim() } else { $FallbackValue }

        $primaryNumeric = 0.0
        if ([double]::TryParse($trimmedPrimary, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$primaryNumeric)) {
            $fallbackNumeric = 0.0
            if ($null -ne $trimmedFallback -and -not ([string]::IsNullOrWhiteSpace([string]$trimmedFallback))) {
                if ([double]::TryParse([string]$trimmedFallback, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$fallbackNumeric)) {
                    if ($primaryNumeric -eq 0 -and $fallbackNumeric -ne 0) {
                        return $FallbackValue
                    }

                    if ($fallbackNumeric -eq 0 -and $primaryNumeric -ne 0) {
                        return $PrimaryValue
                    }
                }
            }
        }

        return $PrimaryValue
    }

    if ($PrimaryValue -is [double] -or $PrimaryValue -is [float] -or $PrimaryValue -is [decimal] -or $PrimaryValue -is [int] -or $PrimaryValue -is [long] -or $PrimaryValue -is [byte]) {
        $primaryNumeric = [double]$PrimaryValue
        $fallbackNumeric = [double]$FallbackValue

        if ($primaryNumeric -eq 0 -and $fallbackNumeric -ne 0) {
            return $FallbackValue
        }

        if ($fallbackNumeric -eq 0 -and $primaryNumeric -ne 0) {
            return $PrimaryValue
        }
    }

    return $PrimaryValue
}

function Merge-GenericObject {
    param(
        $PrimaryObject,
        $FallbackObject
    )

    if ($null -eq $PrimaryObject) { return $FallbackObject }
    if ($null -eq $FallbackObject) { return $PrimaryObject }

    $propertyNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $PrimaryObject.PSObject.Properties) { [void]$propertyNames.Add($property.Name) }
    foreach ($property in $FallbackObject.PSObject.Properties) { [void]$propertyNames.Add($property.Name) }

    $mergedObject = [ordered]@{}
    foreach ($propertyName in $propertyNames) {
        $mergedObject[$propertyName] = Merge-GenericValue -PrimaryValue $PrimaryObject.$propertyName -FallbackValue $FallbackObject.$propertyName
    }

    return [pscustomobject]$mergedObject
}

function Merge-PermissionArrays {
    param(
        $PrimaryPermissions,
        $FallbackPermissions
    )

    $primaryItems = @($PrimaryPermissions)
    $fallbackItems = @($FallbackPermissions)

    if ($primaryItems.Count -eq 0) { return $fallbackItems }
    if ($fallbackItems.Count -eq 0) { return $primaryItems }

    if ($primaryItems.Count -ge $fallbackItems.Count) {
        return $primaryItems
    }

    return $fallbackItems
}

function Merge-MailboxCurrentRecord {
    param(
        $PrimaryRecord,
        $FallbackRecord
    )

    $mergedRecord = Merge-GenericObject -PrimaryObject $PrimaryRecord -FallbackObject $FallbackRecord

    if ($mergedRecord.PSObject.Properties.Name -contains "Permissions" -or $mergedRecord.PSObject.Properties.Name -contains "permissions") {
        $mergedPermissions = Merge-PermissionArrays `
            -PrimaryPermissions (Get-FirstPropertyValue -Object $PrimaryRecord -PropertyNames @("Permissions", "permissions")) `
            -FallbackPermissions (Get-FirstPropertyValue -Object $FallbackRecord -PropertyNames @("Permissions", "permissions"))
        if ($mergedRecord.PSObject.Properties.Name -contains "Permissions") {
            $mergedRecord.Permissions = $mergedPermissions
        }
        else {
            $mergedRecord | Add-Member -NotePropertyName "permissions" -NotePropertyValue $mergedPermissions -Force
        }
    }

    return $mergedRecord
}

function Merge-HistorySamples {
    param(
        $PrimarySamples,
        $FallbackSamples
    )

    $samplesByKey = @{}
    $orderedSamples = [System.Collections.Generic.List[object]]::new()

    foreach ($sample in @($FallbackSamples) + @($PrimarySamples)) {
        if ($null -eq $sample) {
            continue
        }

        $sampleKey = Get-SampleMergeKey -Sample $sample
        if ([string]::IsNullOrWhiteSpace($sampleKey)) {
            $orderedSamples.Add($sample)
            continue
        }

        if ($samplesByKey.ContainsKey($sampleKey)) {
            $samplesByKey[$sampleKey] = Merge-GenericObject -PrimaryObject $sample -FallbackObject $samplesByKey[$sampleKey]
        }
        else {
            $samplesByKey[$sampleKey] = $sample
        }
    }

    foreach ($sample in $samplesByKey.Values) {
        $orderedSamples.Add($sample)
    }

    return @(
        $orderedSamples |
            Sort-Object -Property @{
                Expression = {
                    $timestamp = Get-DateTimeOffsetOrNull -Value ([string](Get-FirstPropertyValue -Object $_ -PropertyNames @("TimestampUtc", "timestampUtc", "Timestamp", "timestamp")))
                    if ($null -ne $timestamp) { $timestamp.UtcDateTime.Ticks } else { [int64]::MaxValue }
                }
            }, @{
                Expression = {
                    [string](Get-FirstPropertyValue -Object $_ -PropertyNames @("TimestampUtc", "timestampUtc", "Timestamp", "timestamp"))
                }
            }
    )
}

function Merge-MailboxHistoryRecord {
    param(
        $PrimaryRecord,
        $FallbackRecord
    )

    $mergedRecord = Merge-GenericObject -PrimaryObject $PrimaryRecord -FallbackObject $FallbackRecord
    $mergedRecord.Samples = Merge-HistorySamples -PrimarySamples $PrimaryRecord.Samples -FallbackSamples $FallbackRecord.Samples

    if ($PrimaryRecord.PSObject.Properties.Name -contains "Permissions" -or $FallbackRecord.PSObject.Properties.Name -contains "Permissions") {
        $mergedRecord.Permissions = Merge-PermissionArrays -PrimaryPermissions $PrimaryRecord.Permissions -FallbackPermissions $FallbackRecord.Permissions
    }

    return $mergedRecord
}

function Merge-DataJsonPayload {
    param(
        $SourcePayload,
        $DestinationPayload
    )

    if ($null -eq $SourcePayload) { return $DestinationPayload }
    if ($null -eq $DestinationPayload) { return $SourcePayload }

    $sourceGeneratedUtc = Get-DateTimeOffsetOrNull -Value (Get-GeneratedUtcValue -Payload $SourcePayload)
    $destinationGeneratedUtc = Get-DateTimeOffsetOrNull -Value (Get-GeneratedUtcValue -Payload $DestinationPayload)

    $preferredPayload = Get-PreferredObject -SourceObject $SourcePayload -DestinationObject $DestinationPayload -SourceGeneratedUtc $sourceGeneratedUtc -DestinationGeneratedUtc $destinationGeneratedUtc
    $sourceMailboxes = @(
        $mailboxes = Get-FirstPropertyValue -Object $SourcePayload -PropertyNames @("Mailboxes", "mailboxes")
        if ($null -ne $mailboxes) { $mailboxes }
    )
    $destinationMailboxes = @(
        $mailboxes = Get-FirstPropertyValue -Object $DestinationPayload -PropertyNames @("Mailboxes", "mailboxes")
        if ($null -ne $mailboxes) { $mailboxes }
    )
    $mailboxesByKey = @{}
    $mergedMailboxes = [System.Collections.Generic.List[object]]::new()

    foreach ($mailbox in $destinationMailboxes) {
        if ($null -eq $mailbox) { continue }
        $mailboxKey = Get-MailboxMergeKey -Record $mailbox
        if ([string]::IsNullOrWhiteSpace($mailboxKey)) {
            $mergedMailboxes.Add($mailbox)
            continue
        }

        $mailboxesByKey[$mailboxKey] = $mailbox
    }

    foreach ($mailbox in $sourceMailboxes) {
        if ($null -eq $mailbox) { continue }
        $mailboxKey = Get-MailboxMergeKey -Record $mailbox
        if ([string]::IsNullOrWhiteSpace($mailboxKey)) {
            $mergedMailboxes.Add($mailbox)
            continue
        }

        if ($mailboxesByKey.ContainsKey($mailboxKey)) {
            $preferredRecord = Get-PreferredObject -SourceObject $mailbox -DestinationObject $mailboxesByKey[$mailboxKey] -SourceGeneratedUtc $sourceGeneratedUtc -DestinationGeneratedUtc $destinationGeneratedUtc
            if ($preferredRecord -eq $mailbox) {
                $fallbackRecord = $mailboxesByKey[$mailboxKey]
            }
            else {
                $fallbackRecord = $mailbox
            }
            $mailboxesByKey[$mailboxKey] = Merge-MailboxCurrentRecord -PrimaryRecord $preferredRecord -FallbackRecord $fallbackRecord
        }
        else {
            $mailboxesByKey[$mailboxKey] = $mailbox
        }
    }

    foreach ($mailbox in $mailboxesByKey.Values) {
        $mergedMailboxes.Add($mailbox)
    }

    $preferredPayload.Mailboxes = @(
        $mergedMailboxes |
            Sort-Object -Property @{
                Expression = { [string](Get-FirstPropertyValue -Object $_ -PropertyNames @("DisplayName", "displayName", "PrimarySmtpAddress", "primarySmtpAddress")) }
            }, @{
                Expression = { [string](Get-FirstPropertyValue -Object $_ -PropertyNames @("PrimarySmtpAddress", "primarySmtpAddress")) }
            }
    )

    return $preferredPayload
}

function Merge-HistoryJsonPayload {
    param(
        $SourcePayload,
        $DestinationPayload
    )

    if ($null -eq $SourcePayload) { return $DestinationPayload }
    if ($null -eq $DestinationPayload) { return $SourcePayload }

    $sourceGeneratedUtc = Get-DateTimeOffsetOrNull -Value (Get-GeneratedUtcValue -Payload $SourcePayload)
    $destinationGeneratedUtc = Get-DateTimeOffsetOrNull -Value (Get-GeneratedUtcValue -Payload $DestinationPayload)

    $preferredPayload = Get-PreferredObject -SourceObject $SourcePayload -DestinationObject $DestinationPayload -SourceGeneratedUtc $sourceGeneratedUtc -DestinationGeneratedUtc $destinationGeneratedUtc
    $sourceHistory = @(
        $mailboxHistory = Get-FirstPropertyValue -Object $SourcePayload -PropertyNames @("MailboxHistory", "mailboxHistory")
        if ($null -ne $mailboxHistory) { $mailboxHistory }
    )
    $destinationHistory = @(
        $mailboxHistory = Get-FirstPropertyValue -Object $DestinationPayload -PropertyNames @("MailboxHistory", "mailboxHistory")
        if ($null -ne $mailboxHistory) { $mailboxHistory }
    )
    $historyByKey = @{}
    $mergedHistory = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $destinationHistory) {
        if ($null -eq $entry) { continue }
        $entryKey = Get-MailboxMergeKey -Record $entry
        if ([string]::IsNullOrWhiteSpace($entryKey)) {
            $mergedHistory.Add($entry)
            continue
        }

        $historyByKey[$entryKey] = $entry
    }

    foreach ($entry in $sourceHistory) {
        if ($null -eq $entry) { continue }
        $entryKey = Get-MailboxMergeKey -Record $entry
        if ([string]::IsNullOrWhiteSpace($entryKey)) {
            $mergedHistory.Add($entry)
            continue
        }

        if ($historyByKey.ContainsKey($entryKey)) {
            $preferredRecord = Get-PreferredObject -SourceObject $entry -DestinationObject $historyByKey[$entryKey] -SourceGeneratedUtc $sourceGeneratedUtc -DestinationGeneratedUtc $destinationGeneratedUtc
            if ($preferredRecord -eq $entry) {
                $fallbackRecord = $historyByKey[$entryKey]
            }
            else {
                $fallbackRecord = $entry
            }
            $historyByKey[$entryKey] = Merge-MailboxHistoryRecord -PrimaryRecord $preferredRecord -FallbackRecord $fallbackRecord
        }
        else {
            $historyByKey[$entryKey] = $entry
        }
    }

    foreach ($entry in $historyByKey.Values) {
        $mergedHistory.Add($entry)
    }

    $preferredPayload.MailboxHistory = @(
        $mergedHistory |
            Sort-Object -Property @{
                Expression = { [string](Get-FirstPropertyValue -Object $_ -PropertyNames @("DisplayName", "displayName", "PrimarySmtpAddress", "primarySmtpAddress")) }
            }, @{
                Expression = { [string](Get-FirstPropertyValue -Object $_ -PropertyNames @("PrimarySmtpAddress", "primarySmtpAddress")) }
            }
    )

    return $preferredPayload
}

function Merge-DeploymentJsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $sourcePayload = Read-DeploymentJsonFile -Path $SourcePath
    $destinationPayload = Read-DeploymentJsonFile -Path $DestinationPath

    switch ($RelativePath.Replace("/", "\")) {
        "Web\data.json" {
            return ConvertTo-DeploymentJson -InputObject (Merge-DataJsonPayload -SourcePayload $sourcePayload -DestinationPayload $destinationPayload) -Depth 100
        }
        "Web\history.json" {
            return ConvertTo-DeploymentJson -InputObject (Merge-HistoryJsonPayload -SourcePayload $sourcePayload -DestinationPayload $destinationPayload) -Depth 100
        }
        default {
            throw "JSON merge is not defined for '$RelativePath'."
        }
    }
}

function Set-DeploymentFileContent {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    Set-Content -LiteralPath $DestinationPath -Value $Content -Encoding utf8
}

$resolvedSourceRoot = Resolve-DeploymentPath -Path $SourceRoot
if (-not (Test-Path -LiteralPath $resolvedSourceRoot)) {
    throw "Source root '$resolvedSourceRoot' does not exist."
}

$resolvedDestinationRoot = Read-DeploymentRoot -InitialValue $DestinationRoot
if ($resolvedDestinationRoot.StartsWith($resolvedSourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Destination root '$resolvedDestinationRoot' cannot be the same as or inside the source repository root '$resolvedSourceRoot'."
}

if (-not (Test-Path -LiteralPath $resolvedDestinationRoot)) {
    if ($PSCmdlet.ShouldProcess($resolvedDestinationRoot, "Create deployment root")) {
        New-Item -Path $resolvedDestinationRoot -ItemType Directory -Force | Out-Null
    }
}

$allSourceFiles = @(Get-ChildItem -LiteralPath $resolvedSourceRoot -Recurse -File)
$deploymentFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$excludedFiles = 0

foreach ($file in $allSourceFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedSourceRoot, $file.FullName)
    if (Test-ExcludedDeploymentPath -RelativePath $relativePath) {
        $excludedFiles++
        continue
    }

    $deploymentFiles.Add($file)
}

$copiedFiles = 0
$skippedFiles = 0
$wouldCopyFiles = 0

foreach ($file in $deploymentFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedSourceRoot, $file.FullName)
    $destinationPath = Join-Path -Path $resolvedDestinationRoot -ChildPath $relativePath
    $normalizedRelativePath = $relativePath.Replace("/", "\")

    if (($normalizedRelativePath -ieq "Web\data.json" -or $normalizedRelativePath -ieq "Web\history.json") -and (Test-Path -LiteralPath $destinationPath)) {
        try {
            $mergedJson = Merge-DeploymentJsonFile -RelativePath $normalizedRelativePath -SourcePath $file.FullName -DestinationPath $destinationPath
            $existingJson = Get-Content -LiteralPath $destinationPath -Raw

            if ($mergedJson -eq $existingJson) {
                $skippedFiles++
                continue
            }

            if ($PSCmdlet.ShouldProcess($destinationPath, "Merge and write '$relativePath'")) {
                Set-DeploymentFileContent -DestinationPath $destinationPath -Content $mergedJson
                $copiedFiles++
            }
            else {
                $wouldCopyFiles++
            }

            continue
        }
        catch {
            Write-Warning "Could not merge '$relativePath' with the destination copy. Falling back to normal copy. $($_.Exception.Message)"
        }
    }

    $copyRequired = $true
    if (Test-Path -LiteralPath $destinationPath) {
        $destinationFile = Get-Item -LiteralPath $destinationPath
        $copyRequired = ($file.Length -ne $destinationFile.Length) -or ($file.LastWriteTimeUtc -ne $destinationFile.LastWriteTimeUtc)
    }

    if (-not $copyRequired) {
        $skippedFiles++
        continue
    }

    if ($PSCmdlet.ShouldProcess($destinationPath, "Copy '$relativePath'")) {
        Copy-DeploymentFile -SourcePath $file.FullName -DestinationPath $destinationPath
        $copiedFiles++
    }
    else {
        $wouldCopyFiles++
    }
}

$deploymentSummary = [pscustomobject]@{
    SourceRoot       = $resolvedSourceRoot
    DestinationRoot  = $resolvedDestinationRoot
    TotalSourceFiles = $allSourceFiles.Count
    IncludedFiles    = $deploymentFiles.Count
    ExcludedFiles    = $excludedFiles
    CopiedFiles      = $copiedFiles
    WouldCopyFiles   = $wouldCopyFiles
    SkippedFiles     = $skippedFiles
}

if ($OpenDestination -and (Test-Path -LiteralPath $resolvedDestinationRoot)) {
    Invoke-Item -LiteralPath $resolvedDestinationRoot
}

$deploymentSummary
