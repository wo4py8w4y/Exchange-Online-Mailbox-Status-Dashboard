[CmdletBinding()]
param(
    [string]$RootPath = $PSScriptRoot,
    [string]$Prefix = "http://localhost:8888/",
    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath "logs\httpserver.log"),
    [ValidateRange(1, 2048)]
    [int]$LogMaxSizeMB = 8,
    [ValidateRange(1, 100)]
    [int]$LogRetentionCount = 10,
    [ValidateSet("Dots", "Line", "Star", "Bounce", "Arrow", "Classic")]
    [string]$SpinnerType = "Dots",
    [switch]$NoSpinner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath $Path))
}

function Get-NowUtcString {
    return (Get-Date).ToUniversalTime().ToString("o")
}

function Rotate-LogFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int64]$MaxBytes,

        [Parameter(Mandatory)]
        [int]$RetentionCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $logFile = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($logFile.Length -lt $MaxBytes) {
        return
    }

    $oldestArchivedPath = "$Path.$RetentionCount"
    if (Test-Path -LiteralPath $oldestArchivedPath) {
        Remove-Item -LiteralPath $oldestArchivedPath -Force
    }

    for ($index = $RetentionCount - 1; $index -ge 1; $index--) {
        $currentArchivedPath = "$Path.$index"
        if (-not (Test-Path -LiteralPath $currentArchivedPath)) {
            continue
        }

        Move-Item -LiteralPath $currentArchivedPath -Destination "$Path.$($index + 1)" -Force
    }

    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
}

function Write-ServerLog {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int64]$MaxBytes,

        [Parameter(Mandatory)]
        [int]$RetentionCount,

        [Parameter(Mandatory)]
        [string]$Message
    )

    Rotate-LogFile -Path $Path -MaxBytes $MaxBytes -RetentionCount $RetentionCount
    Add-Content -LiteralPath $Path -Value $Message -Encoding utf8
}

function Write-ServerEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [int64]$LogMaxBytes,

        [Parameter(Mandatory)]
        [int]$LogRetentionCount,

        [string]$ClientIp = "",
        [string]$Method = "",
        [string]$Path = "",
        [int]$StatusCode = 0,
        [long]$DurationMs = 0,
        [long]$Bytes = 0
    )

    $timestamp = Get-NowUtcString
    $statusCodeText = if ($StatusCode -gt 0) { $StatusCode } else { "-" }
    $durationText = if ($DurationMs -gt 0) { "$DurationMs ms" } else { "-" }
    $bytesText = if ($Bytes -gt 0) { "$Bytes B" } else { "-" }
    $clientText = if ([string]::IsNullOrWhiteSpace($ClientIp)) { "-" } else { $ClientIp }
    $methodText = if ([string]::IsNullOrWhiteSpace($Method)) { "-" } else { $Method }
    $pathText = if ([string]::IsNullOrWhiteSpace($Path)) { "-" } else { $Path }

    $line = "{0} [{1}] ip={2} method={3} path={4} status={5} duration={6} bytes={7} msg={8}" -f `
        $timestamp, $Level.ToUpperInvariant(), $clientText, $methodText, $pathText, $statusCodeText, $durationText, $bytesText, $Message

    $color = switch ($Level.ToUpperInvariant()) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "OK" { "Green" }
        "REQ" { "Cyan" }
        default { "Gray" }
    }

    Write-Host $line -ForegroundColor $color
    Write-ServerLog -Path $LogPath -MaxBytes $LogMaxBytes -RetentionCount $LogRetentionCount -Message $line
}

function Get-ContentType {
    param(
        [Parameter(Mandatory)]
        [string]$Extension
    )

    switch ($Extension.ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".svg"  { "image/svg+xml" }
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".gif"  { "image/gif" }
        ".ico"  { "image/x-icon" }
        default { "application/octet-stream" }
    }
}

function Send-Response {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,

        [Parameter(Mandatory)]
        [byte[]]$Body,

        [Parameter(Mandatory)]
        [string]$ContentType,

        [int]$StatusCode = 200
    )

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Body.Length
    $Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    $Response.OutputStream.Write($Body, 0, $Body.Length)
    $Response.OutputStream.Close()
}

function Send-TextResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,

        [Parameter(Mandatory)]
        [string]$Text,

        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Send-Response -Response $Response -Body $bytes -ContentType "text/plain; charset=utf-8" -StatusCode $StatusCode
}

$resolvedRootPath = [System.IO.Path]::GetFullPath($RootPath)
if (-not (Test-Path -LiteralPath $resolvedRootPath)) {
    throw "Web root '$resolvedRootPath' does not exist."
}

$resolvedLogPath = Resolve-AbsolutePath -Path $LogPath
$logDirectory = Split-Path -Path $resolvedLogPath -Parent
if (-not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

$maxLogBytes = [int64]$LogMaxSizeMB * 1MB
$spinnerAvailable = $false

if (-not $NoSpinner) {
    try {
        Import-Module PSSpinner -ErrorAction Stop
        $spinnerAvailable = $null -ne (Get-Command -Name Start-Spinner -ErrorAction SilentlyContinue)
    }
    catch {
        $spinnerAvailable = $false
    }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
$startupSpinner = $null

if ($spinnerAvailable) {
    $startupSpinner = Start-Spinner -Message "Starting HTTP listener at $Prefix " -SpinnerType $SpinnerType -Color Cyan
}

try {
    $listener.Start()
    if ($startupSpinner) {
        Stop-Spinner -Spinner $startupSpinner -Message "HTTP listener started at $Prefix" -Success
    }
}
catch {
    if ($startupSpinner) {
        Stop-Spinner -Spinner $startupSpinner -Message "Failed to start listener: $($_.Exception.Message)" -Failure
    }
    throw
}

Write-Host "Serving '$resolvedRootPath' at $Prefix" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop the server." -ForegroundColor Cyan
Write-Host "Rolling log: '$resolvedLogPath' (max ${LogMaxSizeMB}MB, retain $LogRetentionCount archives)" -ForegroundColor DarkCyan

Write-ServerEvent -Level "OK" -Message "Server startup complete." -LogPath $resolvedLogPath -LogMaxBytes $maxLogBytes -LogRetentionCount $LogRetentionCount

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $requestStart = Get-Date
        $requestStatusCode = 500
        $responseBytes = 0L
        $requestPath = if ($request.Url) { $request.Url.PathAndQuery } else { "/" }
        $clientIp = if ($request.RemoteEndPoint) { $request.RemoteEndPoint.Address.ToString() } else { "" }

        Write-ServerEvent `
            -Level "REQ" `
            -Message "Incoming request." `
            -LogPath $resolvedLogPath `
            -LogMaxBytes $maxLogBytes `
            -LogRetentionCount $LogRetentionCount `
            -ClientIp $clientIp `
            -Method $request.HttpMethod `
            -Path $requestPath

        try {
            if ($request.HttpMethod -ne "GET") {
                $requestStatusCode = 405
                $body = [System.Text.Encoding]::UTF8.GetBytes("Only GET is supported.")
                $responseBytes = $body.Length
                Send-Response -Response $response -Body $body -ContentType "text/plain; charset=utf-8" -StatusCode $requestStatusCode
                continue
            }

            $relativePath = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart("/"))
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $relativePath = "index.html"
            }

            if ($relativePath -eq "quit") {
                $requestStatusCode = 200
                $body = [System.Text.Encoding]::UTF8.GetBytes("Server shutting down.")
                $responseBytes = $body.Length
                Send-Response -Response $response -Body $body -ContentType "text/plain; charset=utf-8" -StatusCode $requestStatusCode
                break
            }

            $requestedPath = Join-Path -Path $resolvedRootPath -ChildPath $relativePath
            $fullPath = [System.IO.Path]::GetFullPath($requestedPath)

            if (-not $fullPath.StartsWith($resolvedRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $requestStatusCode = 403
                $body = [System.Text.Encoding]::UTF8.GetBytes("Forbidden.")
                $responseBytes = $body.Length
                Send-Response -Response $response -Body $body -ContentType "text/plain; charset=utf-8" -StatusCode $requestStatusCode
                continue
            }

            if (-not (Test-Path -LiteralPath $fullPath)) {
                $requestStatusCode = 404
                $body = [System.Text.Encoding]::UTF8.GetBytes("Not found.")
                $responseBytes = $body.Length
                Send-Response -Response $response -Body $body -ContentType "text/plain; charset=utf-8" -StatusCode $requestStatusCode
                continue
            }

            if ((Get-Item -LiteralPath $fullPath).PSIsContainer) {
                $fullPath = Join-Path -Path $fullPath -ChildPath "index.html"
            }

            if (-not (Test-Path -LiteralPath $fullPath)) {
                $requestStatusCode = 404
                $body = [System.Text.Encoding]::UTF8.GetBytes("Not found.")
                $responseBytes = $body.Length
                Send-Response -Response $response -Body $body -ContentType "text/plain; charset=utf-8" -StatusCode $requestStatusCode
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $contentType = Get-ContentType -Extension ([System.IO.Path]::GetExtension($fullPath))
            $requestStatusCode = 200
            $responseBytes = $bytes.Length
            Send-Response -Response $response -Body $bytes -ContentType $contentType -StatusCode $requestStatusCode
        }
        catch {
            if ($response.OutputStream.CanWrite) {
                $requestStatusCode = 500
                $body = [System.Text.Encoding]::UTF8.GetBytes("Server error: $($_.Exception.Message)")
                $responseBytes = $body.Length
                Send-Response -Response $response -Body $body -ContentType "text/plain; charset=utf-8" -StatusCode $requestStatusCode
            }

            Write-ServerEvent `
                -Level "ERROR" `
                -Message ("Request failed: {0}" -f $_.Exception.Message) `
                -LogPath $resolvedLogPath `
                -LogMaxBytes $maxLogBytes `
                -LogRetentionCount $LogRetentionCount `
                -ClientIp $clientIp `
                -Method $request.HttpMethod `
                -Path $requestPath `
                -StatusCode $requestStatusCode
        }
        finally {
            $durationMs = [Math]::Round(((Get-Date) - $requestStart).TotalMilliseconds, 0)
            $resultLevel = if ($requestStatusCode -ge 500) { "ERROR" } elseif ($requestStatusCode -ge 400) { "WARN" } else { "OK" }
            Write-ServerEvent `
                -Level $resultLevel `
                -Message "Request complete." `
                -LogPath $resolvedLogPath `
                -LogMaxBytes $maxLogBytes `
                -LogRetentionCount $LogRetentionCount `
                -ClientIp $clientIp `
                -Method $request.HttpMethod `
                -Path $requestPath `
                -StatusCode $requestStatusCode `
                -DurationMs $durationMs `
                -Bytes $responseBytes
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }

    $listener.Close()
    Write-ServerEvent -Level "OK" -Message "HTTP server stopped." -LogPath $resolvedLogPath -LogMaxBytes $maxLogBytes -LogRetentionCount $LogRetentionCount
    Write-Host "HTTP server stopped." -ForegroundColor Yellow
}
