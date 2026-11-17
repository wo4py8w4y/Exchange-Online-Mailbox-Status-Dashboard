<#
.SYNOPSIS
    Collects delayed Microsoft Graph mailbox usage reports without Exchange Online.
.DESCRIPTION
    Requires Reports.Read.All, User.Read.All, and MailboxSettings.Read application permissions and a CSV
    with GraphUserId and ExchangeGuid columns. ExchangeGuid must be independently
    verified; a Graph user ID is never used as a mailbox GUID.
    Report identities must be unconcealed. Unsupported metrics remain null.
    Uses an existing Graph context, or configured app-only credentials with -Connect.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$HistoryJsonPath,
    [string]$MappingCsvPath,
    [string[]]$Identity,
    [switch]$Connect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules\MailboxDashboard.Config.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Modules\MailboxDashboard.Graph.psm1') -DisableNameChecking

$configArguments = @{ SkipValidation = $true }
if ($PSBoundParameters.ContainsKey('ConfigPath')) { $configArguments.ConfigPath = $ConfigPath }
$config = Import-MailboxDashboardConfig @configArguments
$arguments = @{ Config = $config; Connect = $Connect; Identity = $Identity }
foreach ($name in @('HistoryJsonPath', 'MappingCsvPath', 'WhatIf', 'Confirm')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}
Invoke-MailboxDashboardGraphCollection @arguments
