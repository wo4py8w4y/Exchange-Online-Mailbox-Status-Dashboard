

# Merge multiple JSON files into one
# Supports both array-based and object-based JSON structures

param (
    [Parameter(Mandatory = $true)]
    [string]$InputFolder,   # Folder containing JSON files
    [Parameter(Mandatory = $true)]
    [string]$OutputFile     # Path for merged JSON output
)

try {
    if (-not (Test-Path $InputFolder)) {
        throw "Input folder '$InputFolder' does not exist."
    }

    $jsonFiles = Get-ChildItem -Path $InputFolder -Filter *.json -File
    if ($jsonFiles.Count -eq 0) {
        throw "No JSON files found in '$InputFolder'."
    }

    $mergedData = @()

    foreach ($file in $jsonFiles) {
        try {
            $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($content -is [System.Collections.IEnumerable] -and -not ($content -is [string])) {
                # If JSON is an array, append items
                $mergedData += $content
            } else {
                # If JSON is an object, wrap it in an array
                $mergedData += ,$content
            }
        }
        catch {
            Write-Warning "Skipping '$($file.Name)' - invalid JSON format."
        }
    }

    # Save merged JSON
    $mergedData | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputFile -Encoding UTF8

    Write-Host "✅ Merged $($mergedData.Count) JSON entries into '$OutputFile'"
}
catch {
    Write-Error $_.Exception.Message
}
