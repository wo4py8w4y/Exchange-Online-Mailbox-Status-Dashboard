<#
.SYNOPSIS
    Creates shareable MailboxDashboard URLs.
.DESCRIPTION
    Builds dashboard links using the same query-string contract as Web/dashboard.js.
    Domain filters become wildcard mailbox filters such as *@smartservice.qld.gov.au.
.PARAMETER BaseUrl
    Dashboard base URL, for example https://dashboard.dpwservices.dpw.qld.gov.au.
.PARAMETER Domain
    One or more SMTP domains. Each domain produces a q=*%40domain URL filter.
.PARAMETER Query
    A dashboard table filter to use instead of -Domain.
.PARAMETER Page
    Dashboard page to open.
.PARAMETER Scope
    Optional dashboard scope identifier.
.PARAMETER Sort
    Optional table sort key.
.PARAMETER Direction
    Optional sort direction.
.PARAMETER Mailbox
    Optional mailbox or ExchangeGuid to open directly.
.PARAMETER OutputPath
    Optional text file to receive the generated URLs, one per line.
.PARAMETER NoMenu
    Skip the interactive menu and use the supplied parameters. The menu is the default.
.EXAMPLE
    .\New-MailboxDashboardUrl.ps1 -Domain smartservice.qld.gov.au
.EXAMPLE
    .\New-MailboxDashboardUrl.ps1 -Domain smartservice.qld.gov.au,contoso.com -Page index.html
.EXAMPLE
    .\New-MailboxDashboardUrl.ps1 -Query '*@smartservice.qld.gov.au' -Scope all -Sort usagePercent -Direction desc
.EXAMPLE
    .\New-MailboxDashboardUrl.ps1 -NoMenu -Domain smartservice.qld.gov.au
.NOTES
    Domain and Query are mutually exclusive. Domain values may include a leading @.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [uri]$BaseUrl = 'https://dashboard.dpwservices.dpw.qld.gov.au/',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Domain,

    [Parameter()]
    [string]$Query,

    [Parameter()]
    [ValidateSet('index.html', 'scope.html', 'history.html', 'permissions.html', 'thresholds.html', 'licensing.html', 'mailbox.html')]
    [string]$Page = 'index.html',

    [Parameter()]
    [string]$Scope,

    [Parameter()]
    [string]$Sort,

    [Parameter()]
    [ValidateSet('asc', 'desc')]
    [string]$Direction,

    [Parameter()]
    [string]$Mailbox,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$NoMenu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-UrlValue {
    param([Parameter(Mandatory)][string]$Value)

    return [Uri]::EscapeDataString($Value)
}

function New-DashboardUrl {
    param([Parameter(Mandatory)][string]$Filter)

    $baseText = $BaseUrl.AbsoluteUri.TrimEnd('/')
    $pageUrl = if ($baseText.EndsWith('.html', [System.StringComparison]::OrdinalIgnoreCase)) {
        $baseText
    }
    else {
        "$baseText/$Page"
    }

    $parameters = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Filter)) { $parameters.Add("q=$(ConvertTo-UrlValue -Value $Filter)") }
    if (-not [string]::IsNullOrWhiteSpace($Scope) -and $Scope -ne 'all') { $parameters.Add("scope=$(ConvertTo-UrlValue -Value $Scope)") }
    if (-not [string]::IsNullOrWhiteSpace($Sort)) { $parameters.Add("sort=$(ConvertTo-UrlValue -Value $Sort)") }
    if (-not [string]::IsNullOrWhiteSpace($Direction)) { $parameters.Add("dir=$(ConvertTo-UrlValue -Value $Direction)") }
    if (-not [string]::IsNullOrWhiteSpace($Mailbox)) { $parameters.Add("mailbox=$(ConvertTo-UrlValue -Value $Mailbox)") }

    if ($parameters.Count -eq 0) { return $pageUrl }
    return "${pageUrl}?$($parameters -join '&')"
}

function Test-DashboardBaseUrl {
    param([Parameter(Mandatory)][string]$Value)

    $parsed = $null
    if (-not [uri]::TryCreate($Value.Trim(), [System.UriKind]::Absolute, [ref]$parsed)) { return $false }
    return $parsed.Scheme -in @('http', 'https') -and -not [string]::IsNullOrWhiteSpace($parsed.Host)
}

function Test-MailboxDomain {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Trim().TrimStart('@') -match '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Options,
        [int]$Selected = 0
    )

    while ($true) {
        Clear-Host
        Write-Host $Title -ForegroundColor Cyan
        Write-Host ('-' * $Title.Length) -ForegroundColor DarkCyan
        for ($index = 0; $index -lt $Options.Count; $index++) {
            $marker = if ($index -eq $Selected) { '>' } else { ' ' }
            $colour = if ($index -eq $Selected) { 'Black' } else { 'Gray' }
            $background = if ($index -eq $Selected) { 'Cyan' } else { 'Black' }
            Write-Host "$marker $($Options[$index])" -ForegroundColor $colour -BackgroundColor $background
        }
        Write-Host ''
        Write-Host 'Use Up/Down and Enter. Press Q to cancel.' -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow' { $Selected = ($Selected - 1 + $Options.Count) % $Options.Count }
            'DownArrow' { $Selected = ($Selected + 1) % $Options.Count }
            'Enter' { return $Selected }
            'Q' { return -1 }
        }
    }
}

function Read-ValidatedInput {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$Default,
        [Parameter(Mandatory)][scriptblock]$Validator,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if (-not [string]::IsNullOrWhiteSpace($value) -and (& $Validator $value)) { return $value.Trim() }
        Write-Host $ErrorMessage -ForegroundColor Yellow
    }
}

function Read-LinkSettings {
    $script:BaseUrl = [uri](Read-ValidatedInput -Prompt 'Dashboard base URL' -Default $BaseUrl.AbsoluteUri -Validator { param($value) Test-DashboardBaseUrl $value } -ErrorMessage 'Enter an absolute http or https URL.')

    $pageOptions = @('index.html', 'scope.html', 'history.html', 'permissions.html', 'thresholds.html', 'licensing.html', 'mailbox.html')
    $pageIndex = [array]::IndexOf($pageOptions, $Page)
    if ($pageIndex -lt 0) { $pageIndex = 0 }
    $pageChoice = Read-MenuChoice -Title 'Choose dashboard page' -Options $pageOptions -Selected $pageIndex
    if ($pageChoice -lt 0) { return $false }
    $script:Page = $pageOptions[$pageChoice]
    $script:Scope = Read-Host "Scope (optional, current: $Scope)"
    if ([string]::IsNullOrWhiteSpace($script:Scope)) { $script:Scope = $Scope }
    $script:Sort = Read-Host "Sort key (optional, current: $Sort)"
    if ([string]::IsNullOrWhiteSpace($script:Sort)) { $script:Sort = $Sort }
    if (-not [string]::IsNullOrWhiteSpace($script:Sort)) {
        $directionChoice = Read-MenuChoice -Title 'Choose sort direction' -Options @('asc', 'desc') -Selected ([math]::Max(0, [array]::IndexOf(@('asc', 'desc'), $Direction)))
        if ($directionChoice -lt 0) { return $false }
        $script:Direction = @('asc', 'desc')[$directionChoice]
    }
    return $true
}

function Invoke-UrlMenu {
    $mode = Read-MenuChoice -Title 'MailboxDashboard URL builder' -Options @(
        'Filter by SMTP domain',
        'Use a custom mailbox filter',
        'Open one mailbox or ExchangeGuid',
        'Configure page and link options',
        'Exit'
    )

    switch ($mode) {
        0 {
            $rawDomains = Read-ValidatedInput -Prompt 'SMTP domain(s), comma separated' -Default (($Domain -join ', ')) -Validator {
                param($value)
                $parts = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $parts.Count -gt 0 -and @($parts | Where-Object { Test-MailboxDomain $_ }).Count -eq $parts.Count
            } -ErrorMessage 'Enter domains such as smartservice.qld.gov.au.'
            $script:Domain = @($rawDomains -split ',' | ForEach-Object { $_.Trim() })
            $script:Query = $null
            $script:Mailbox = $null
        }
        1 {
            $script:Query = Read-ValidatedInput -Prompt 'Mailbox filter' -Default $Query -Validator { param($value) -not [string]::IsNullOrWhiteSpace($value) } -ErrorMessage 'Enter a mailbox filter.'
            $script:Domain = @()
            $script:Mailbox = $null
        }
        2 {
            $script:Mailbox = Read-ValidatedInput -Prompt 'Mailbox address or ExchangeGuid' -Default $Mailbox -Validator { param($value) -not [string]::IsNullOrWhiteSpace($value) } -ErrorMessage 'Enter a mailbox address or ExchangeGuid.'
            $script:Domain = @()
            $script:Query = $null
        }
        3 {
            if (-not (Read-LinkSettings)) { return $false }
            return Invoke-UrlMenu
        }
        default { return $false }
    }

    $outputChoice = Read-MenuChoice -Title 'Output' -Options @('Display URL', 'Display URL and save to a text file')
    if ($outputChoice -lt 0) { return $false }
    if ($outputChoice -eq 1) { $script:OutputPath = Read-Host 'Output file path' }
    return $true
}

if (-not $NoMenu) {
    if (-not (Invoke-UrlMenu)) { return }
}

$domains = @($Domain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($domains.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Query)) { throw 'Use either -Domain or -Query, not both.' }
if ($domains.Count -eq 0 -and [string]::IsNullOrWhiteSpace($Query) -and [string]::IsNullOrWhiteSpace($Mailbox)) { throw 'Provide -Domain, -Query, or -Mailbox.' }
if (-not (Test-DashboardBaseUrl -Value $BaseUrl.AbsoluteUri)) { throw 'BaseUrl must be an absolute http or https URL.' }
foreach ($domainValue in $domains) {
    if (-not (Test-MailboxDomain -Value $domainValue)) {
        throw "Invalid SMTP domain '$domainValue'. Use a value such as smartservice.qld.gov.au."
    }
}

$requests = [System.Collections.Generic.List[object]]::new()

if ($domains.Count -gt 0) {
    foreach ($domainValue in $domains) {
        $cleanDomain = $domainValue.Trim().TrimStart('@')
        if ([string]::IsNullOrWhiteSpace($cleanDomain)) { continue }
        $requests.Add([pscustomobject]@{
            Name  = "*@${cleanDomain}"
            Url   = New-DashboardUrl -Filter "*@${cleanDomain}"
        })
    }
}
else {
    $requests.Add([pscustomobject]@{
        Name = if (-not [string]::IsNullOrWhiteSpace($Mailbox)) { $Mailbox } else { $Query }
        Url  = New-DashboardUrl -Filter $Query
    })
}

if ($requests.Count -eq 0) {
    throw 'No usable domain or query was provided.'
}

$urls = @($requests | ForEach-Object { $_.Url })
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }
    $urls | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
    Write-Verbose "Wrote $($urls.Count) URL(s) to '$resolvedOutputPath'."
}

$requests
