Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "MailboxDashboard.Common.psm1") -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "MailboxDashboard.Config.psm1") -DisableNameChecking

function Write-OperationsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string]$Path
    )

    Confirm-ParentDirectory -Path $Path
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).writing"

    try {
        $json = $InputObject | ConvertTo-Json -Depth 12
        Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop
        }
    }
}

function Write-MailboxDashboardCollectionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Status,
        [Parameter(Mandatory)] [string]$Path
    )

    if ($Status.schemaVersion -ne 1) {
        throw "Collection status schemaVersion must be 1."
    }

    Write-OperationsJson -InputObject $Status -Path $Path
}

function Get-MailboxDashboardAlertState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            schemaVersion   = 1
            collectionState = "Healthy"
            conditions      = @()
        }
    }

    $state = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($state.schemaVersion -ne 1 -or
        $state.PSObject.Properties.Name -notcontains 'collectionState' -or
        $state.PSObject.Properties.Name -notcontains 'conditions') {
        throw "Alert state file '$Path' has an unsupported or invalid schema."
    }

    return $state
}

function Get-MailboxDashboardThresholdConditions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)] $Thresholds
    )

    if ($Snapshot.PSObject.Properties.Name -notcontains 'Mailboxes') {
        throw "Dashboard snapshot does not contain a Mailboxes collection."
    }

    $conditions = @{}
    foreach ($mailbox in @($Snapshot.Mailboxes)) {
        if ($null -eq $mailbox -or [string]::IsNullOrWhiteSpace([string]$mailbox.ExchangeGuid)) {
            continue
        }

        $usage = 0.0
        if ($null -ne $mailbox.current.usagePercent) {
            $parsedUsage = 0.0
            if ([double]::TryParse([string]$mailbox.current.usagePercent, [ref]$parsedUsage)) {
                $usage = $parsedUsage
            }
        }

        $severity = if ($usage -ge [double]$Thresholds.CriticalPercent) {
            "Critical"
        }
        elseif ($usage -ge [double]$Thresholds.WarningPercent) {
            "Warning"
        }
        else {
            $null
        }

        if ($null -eq $severity) {
            continue
        }

        $key = ([string]$mailbox.ExchangeGuid).ToLowerInvariant()
        $conditions[$key] = [pscustomobject]@{
            ExchangeGuid       = [string]$mailbox.ExchangeGuid
            Severity           = $severity
            UsagePercent       = $usage
            DisplayName        = [string]$mailbox.DisplayName
            PrimarySmtpAddress = [string]$mailbox.PrimarySmtpAddress
        }
    }

    return $conditions
}

function Connect-MailboxDashboardGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    if (-not (Get-Command -Name Connect-MgGraph -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
            throw "Graph collection and email notifications require Microsoft.Graph.Authentication. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        }
        Import-Module -Name Microsoft.Graph.Authentication -ErrorAction Stop
    }

    if (-not (Get-Command -Name Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw "Microsoft.Graph.Authentication does not expose Invoke-MgGraphRequest."
    }

    if (-not (Test-ConfigPlaceholder -Value $Config.Thumbprint)) {
        Connect-MgGraph -ClientId $Config.AppID -TenantId $Config.Organization `
            -CertificateThumbprint $Config.Thumbprint -ContextScope Process -NoWelcome -ErrorAction Stop
        return
    }

    $secureSecret = ConvertTo-SecureString -String ([string]$Config.ClientSecret) -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new([string]$Config.AppID, $secureSecret)
    Connect-MgGraph -TenantId $Config.Organization -ClientSecretCredential $credential `
        -ContextScope Process -NoWelcome -ErrorAction Stop
}

function Send-MailboxDashboardGraphEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$Subject,
        [Parameter(Mandatory)] [string]$Body
    )

    Connect-MailboxDashboardGraph -Config $Config

    $message = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = "HTML"; content = $Body }
            toRecipients = @(
                foreach ($recipient in @($Config.Notifications.Recipients)) {
                    @{ emailAddress = @{ address = [string]$recipient } }
                }
            )
        }
        saveToSentItems = $true
    }

    $sender = [uri]::EscapeDataString([string]$Config.Notifications.SenderMailbox)
    $null = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/users/$sender/sendMail" `
        -Body ($message | ConvertTo-Json -Depth 8) -ContentType "application/json" -ErrorAction Stop
}

function New-MailboxDashboardAlertMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Transitions)

    $rows = foreach ($transition in $Transitions) {
        $name = [System.Net.WebUtility]::HtmlEncode([string]$transition.DisplayName)
        $address = [System.Net.WebUtility]::HtmlEncode([string]$transition.PrimarySmtpAddress)
        $description = [System.Net.WebUtility]::HtmlEncode([string]$transition.Description)
        if (-not [string]::IsNullOrWhiteSpace($address)) {
            "<li><strong>$name</strong> ($address): $description</li>"
        }
        else {
            "<li><strong>$name</strong>: $description</li>"
        }
    }

    return @"
<p>MailboxDashboard detected the following new or changed conditions:</p>
<ul>
$($rows -join [Environment]::NewLine)
</ul>
"@
}

function Write-MailboxDashboardAlertFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord]$ErrorRecord)

    $safeException = [System.Exception]::new(
        "Alert processing failed with $($ErrorRecord.Exception.GetType().FullName). Message and request details were omitted."
    )
    $safeErrorRecord = [System.Management.Automation.ErrorRecord]::new(
        $safeException,
        "MailboxDashboardAlertFailure",
        [System.Management.Automation.ErrorCategory]::OperationStopped,
        $null
    )
    Write-FailureDiagnostic -ErrorRecord $safeErrorRecord -Context "MailboxDashboard alert processing"
}

function Invoke-MailboxDashboardAlerting {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $CollectionStatus,
        [Parameter(Mandatory)] [string]$DataPath,
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter()] [scriptblock]$GraphSendAction
    )

    $result = [ordered]@{
        Enabled         = [bool]$Config.Notifications.Enabled
        DeliveryStatus  = "Disabled"
        TransitionCount = 0
        ErrorSummary    = $null
    }

    if (-not $Config.Notifications.Enabled) {
        return [pscustomobject]$result
    }

    if ($CollectionStatus.testData) {
        $result.DeliveryStatus = "SkippedTestData"
        return [pscustomobject]$result
    }

    try {
        $previous = Get-MailboxDashboardAlertState -Path $StatePath
        $previousConditions = @{}
        foreach ($condition in @($previous.conditions)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$condition.ExchangeGuid)) {
                $previousConditions[([string]$condition.ExchangeGuid).ToLowerInvariant()] = $condition
            }
        }

        $currentConditions = @{}
        $mailboxDetails = @{}
        if ($CollectionStatus.status -in @("Succeeded", "Partial") -and (Test-Path -LiteralPath $DataPath)) {
            $snapshot = Get-Content -LiteralPath $DataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $currentConditions = Get-MailboxDashboardThresholdConditions -Snapshot $snapshot -Thresholds $Config.Thresholds
            foreach ($key in $currentConditions.Keys) {
                $mailboxDetails[$key] = $currentConditions[$key]
            }
        }
        elseif ($CollectionStatus.status -in @("Succeeded", "Partial") -and -not $CollectionStatus.partialCollection) {
            throw "Dashboard snapshot '$DataPath' is missing; threshold transitions were not evaluated."
        }

        $transitions = [System.Collections.Generic.List[object]]::new()
        foreach ($key in $currentConditions.Keys) {
            $condition = $currentConditions[$key]
            if (-not $previousConditions.ContainsKey($key)) {
                $description = "New $($condition.Severity) threshold condition at $($condition.UsagePercent)% usage."
                $transitions.Add([pscustomobject]@{
                    Type = "New"; DisplayName = $condition.DisplayName
                    PrimarySmtpAddress = $condition.PrimarySmtpAddress; Description = $description
                })
            }
            elseif ($previousConditions[$key].Severity -ne $condition.Severity) {
                $description = "Threshold severity changed from $($previousConditions[$key].Severity) to $($condition.Severity) at $($condition.UsagePercent)% usage."
                $transitions.Add([pscustomobject]@{
                    Type = "SeverityChanged"; DisplayName = $condition.DisplayName
                    PrimarySmtpAddress = $condition.PrimarySmtpAddress; Description = $description
                })
            }
        }

        if ($CollectionStatus.status -eq "Succeeded" -and -not $CollectionStatus.partialCollection) {
            foreach ($key in $previousConditions.Keys) {
                if (-not $currentConditions.ContainsKey($key)) {
                    $oldCondition = $previousConditions[$key]
                    $detail = $mailboxDetails[$key]
                    $transitions.Add([pscustomobject]@{
                        Type = "Resolved"
                        DisplayName = if ($null -ne $detail) { $detail.DisplayName } else { [string]$oldCondition.DisplayName }
                        PrimarySmtpAddress = if ($null -ne $detail) { $detail.PrimarySmtpAddress } else { [string]$oldCondition.PrimarySmtpAddress }
                        Description = "Previously active $($oldCondition.Severity) threshold condition has resolved."
                    })
                }
            }
        }

        $currentCollectionState = if ($CollectionStatus.status -eq "Succeeded") { "Healthy" } else { "Failed" }
        if ($previous.collectionState -ne $currentCollectionState) {
            $isFailure = $currentCollectionState -eq "Failed"
            $transitions.Add([pscustomobject]@{
                Type = if ($isFailure) { "CollectionFailed" } else { "CollectionRecovered" }
                DisplayName = "Collection pipeline"
                PrimarySmtpAddress = ""
                Description = if ($isFailure) { "The latest collection run did not complete successfully." } else { "The collection pipeline has recovered." }
            })
        }

        if ($transitions.Count -eq 0) {
            $result.DeliveryStatus = "NoChanges"
            return [pscustomobject]$result
        }

        $result.TransitionCount = $transitions.Count
        $subject = "MailboxDashboard: $($transitions.Count) condition change(s)"
        $body = New-MailboxDashboardAlertMessage -Transitions $transitions.ToArray()
        $target = $Config.Notifications.Recipients -join ", "
        if (-not $PSCmdlet.ShouldProcess($target, "Send MailboxDashboard alert email")) {
            $result.DeliveryStatus = "WhatIf"
            return [pscustomobject]$result
        }

        if ($null -ne $GraphSendAction) {
            & $GraphSendAction $Config $subject $body
        }
        else {
            Send-MailboxDashboardGraphEmail -Config $Config -Subject $subject -Body $body
        }

        $nextConditions = @{}
        foreach ($key in $previousConditions.Keys) {
            if (($CollectionStatus.status -ne "Succeeded" -or $CollectionStatus.partialCollection) -and
                -not $currentConditions.ContainsKey($key)) {
                $nextConditions[$key] = $previousConditions[$key]
            }
        }
        foreach ($key in $currentConditions.Keys) {
            $condition = $currentConditions[$key]
            $nextConditions[$key] = [pscustomobject]@{
                ExchangeGuid       = $condition.ExchangeGuid
                Severity           = $condition.Severity
                DisplayName        = $condition.DisplayName
                PrimarySmtpAddress = $condition.PrimarySmtpAddress
            }
        }

        Write-OperationsJson -InputObject ([pscustomobject]@{
            schemaVersion   = 1
            collectionState = $currentCollectionState
            conditions      = @($nextConditions.Values)
        }) -Path $StatePath
        $result.DeliveryStatus = "Sent"
    }
    catch {
        Write-MailboxDashboardAlertFailure -ErrorRecord $_
        Write-Notice "Email alert processing failed; collection status was still recorded."
        $result.DeliveryStatus = "Failed"
        $result.ErrorSummary = "Alert processing failed. See Collector/Logs/failures.log."
    }

    return [pscustomobject]$result
}

Export-ModuleMember -Function @(
    'Write-MailboxDashboardCollectionStatus'
    'Invoke-MailboxDashboardAlerting'
)
