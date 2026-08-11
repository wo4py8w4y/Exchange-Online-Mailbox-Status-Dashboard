[CmdletBinding()]
param(
    [string]$RootPath = $PSScriptRoot,
    [string]$Prefix = "http://localhost:8080/"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Write-Response {
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

function Write-TextResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerResponse]$Response,

        [Parameter(Mandatory)]
        [string]$Text,

        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Write-Response -Response $Response -Body $bytes -ContentType "text/plain; charset=utf-8" -StatusCode $StatusCode
}

$resolvedRootPath = [System.IO.Path]::GetFullPath($RootPath)
if (-not (Test-Path -LiteralPath $resolvedRootPath)) {
    throw "Web root '$resolvedRootPath' does not exist."
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
$listener.Start()

Write-Host "Serving '$resolvedRootPath' at $Prefix" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop the server." -ForegroundColor Cyan

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            if ($request.HttpMethod -ne "GET") {
                Write-TextResponse -Response $response -Text "Only GET is supported." -StatusCode 405
                continue
            }

            $relativePath = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart("/"))
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $relativePath = "index.html"
            }

            if ($relativePath -eq "quit") {
                Write-TextResponse -Response $response -Text "Server shutting down."
                break
            }

            $requestedPath = Join-Path -Path $resolvedRootPath -ChildPath $relativePath
            $fullPath = [System.IO.Path]::GetFullPath($requestedPath)

            if (-not $fullPath.StartsWith($resolvedRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-TextResponse -Response $response -Text "Forbidden." -StatusCode 403
                continue
            }

            if (-not (Test-Path -LiteralPath $fullPath)) {
                Write-TextResponse -Response $response -Text "Not found." -StatusCode 404
                continue
            }

            if ((Get-Item -LiteralPath $fullPath).PSIsContainer) {
                $fullPath = Join-Path -Path $fullPath -ChildPath "index.html"
            }

            if (-not (Test-Path -LiteralPath $fullPath)) {
                Write-TextResponse -Response $response -Text "Not found." -StatusCode 404
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $contentType = Get-ContentType -Extension ([System.IO.Path]::GetExtension($fullPath))
            Write-Response -Response $response -Body $bytes -ContentType $contentType
        }
        catch {
            if ($response.OutputStream.CanWrite) {
                Write-TextResponse -Response $response -Text "Server error: $($_.Exception.Message)" -StatusCode 500
            }
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }

    $listener.Close()
    Write-Host "HTTP server stopped." -ForegroundColor Yellow
}
