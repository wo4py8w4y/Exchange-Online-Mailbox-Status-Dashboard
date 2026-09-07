<#
.SYNOPSIS
    Shared utilities for the MailboxDashboard collector pipeline.
.DESCRIPTION
    Path resolution, JSON I/O, size conversion, colour-coded console output,
    export auditing, and failure diagnostics. Imported by every collector script
    so that behaviour and output styling stay identical across the pipeline.
#>

Set-StrictMode -Version Latest

# Nested imports create separate module instances, so settings live in one global
# store that every instance points at.
if (-not (Get-Variable -Name 'MailboxDashboardState' -Scope Global -ErrorAction SilentlyContinue)) {
    $global:MailboxDashboardState = @{
        Console = @{
            ShowProgress = $true
            UseColour    = $true
            ShowPerItem  = $true
            ItemInterval = 1
        }
        Log = @{
            Enabled          = $true
            FailureLogPath   = $null
            ExportAuditPath  = $null
            IncludeVariables = $true
        }
    }
}

$script:ConsoleSettings = $global:MailboxDashboardState.Console
$script:LogSettings = $global:MailboxDashboardState.Log

$script:SecretNamePattern = 'secret|password|token|thumbprint|credential|apikey'

$script:AutomaticVariableNames = @(
    'args', 'ConsoleFileName', 'ErrorView', 'ExecutionContext', 'false', 'HOME', 'Host',
    'input', 'MaximumAliasCount', 'MaximumDriveCount', 'MaximumErrorCount',
    'MaximumFunctionCount', 'MaximumHistoryCount', 'MaximumVariableCount', 'MyInvocation',
    'NestedPromptLevel', 'null', 'PID', 'PROFILE', 'PSBoundParameters', 'PSCmdlet',
    'PSCommandPath', 'PSCulture', 'PSDefaultParameterValues', 'PSEmailServer',
    'PSHOME', 'PSScriptRoot', 'PSSessionApplicationName', 'PSSessionConfigurationName',
    'PSSessionOption', 'PSUICulture', 'PSVersionTable', 'PWD', 'ShellId', 'StackTrace',
    'true', 'VerbosePreference', 'WarningPreference', 'WhatIfPreference', 'ErrorActionPreference',
    'DebugPreference', 'ConfirmPreference', 'ProgressPreference', 'InformationPreference',
    'OutputEncoding', 'Error', 'Matches', 'LASTEXITCODE', '?', '^', '$', '_',
    'PSEdition', 'PSItem', 'PSStyle', 'PSCulture', 'IsCoreCLR', 'IsLinux', 'IsMacOS',
    'IsWindows', 'EnabledExperimentalFeatures', 'FormatEnumerationLimit',
    'PSNativeCommandArgumentPassing', 'PSNativeCommandUseErrorActionPreference',
    'ErrorActionPreference', 'MailboxDashboardState', 'foreach', 'switch', 'this',
    'PSLogUserData', 'PSModuleAutoLoadingPreference'
)

#region Console

function Initialize-MailboxDashboardConsole {
<#
.SYNOPSIS
    Applies console and logging preferences from the loaded configuration.
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        $ConsoleConfig,

        [Parameter()]
        $LoggingConfig
    )

    if ($null -ne $ConsoleConfig) {
        foreach ($key in @('ShowProgress', 'UseColour', 'ShowPerItem', 'ItemInterval')) {
            if ($ConsoleConfig.PSObject.Properties.Name -contains $key) {
                $script:ConsoleSettings[$key] = $ConsoleConfig.$key
            }
        }
    }

    if ($null -ne $LoggingConfig) {
        if ($LoggingConfig.PSObject.Properties.Name -contains 'Enabled') {
            $script:LogSettings.Enabled = [bool]$LoggingConfig.Enabled
        }

        if ($LoggingConfig.PSObject.Properties.Name -contains 'IncludeVariables') {
            $script:LogSettings.IncludeVariables = [bool]$LoggingConfig.IncludeVariables
        }

        if ($LoggingConfig.PSObject.Properties.Name -contains 'ResolvedFailureLogPath') {
            $script:LogSettings.FailureLogPath = $LoggingConfig.ResolvedFailureLogPath
        }

        if ($LoggingConfig.PSObject.Properties.Name -contains 'ResolvedExportAuditPath') {
            $script:LogSettings.ExportAuditPath = $LoggingConfig.ResolvedExportAuditPath
        }
    }
}

function Write-ConsoleLine {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Message = "",

        [Parameter()]
        [System.ConsoleColor]$Colour = [System.ConsoleColor]::Gray
    )

    if ($script:ConsoleSettings.UseColour) {
        Write-Host $Message -ForegroundColor $Colour
    }
    else {
        Write-Host $Message
    }
}

function Write-Stage {
<#
.SYNOPSIS
    Prints a cyan stage banner announcing the operation now starting.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $script:ConsoleSettings.ShowProgress) {
        return
    }

    $banner = "=== $Name "
    if ($banner.Length -lt 60) {
        $banner = $banner.PadRight(60, "=")
    }

    Write-ConsoleLine ""
    Write-ConsoleLine -Message $banner -Colour Cyan
}

function Write-Item {
<#
.SYNOPSIS
    Prints the record currently being processed, with an optional position counter.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [int]$Index,

        [Parameter()]
        [int]$Total,

        [Parameter()]
        [string]$Status
    )

    if (-not $script:ConsoleSettings.ShowProgress) {
        return
    }

    $isLastItem = ($Total -gt 0 -and $Index -eq $Total)

    if (-not $script:ConsoleSettings.ShowPerItem) {
        $interval = [int]$script:ConsoleSettings.ItemInterval
        if ($interval -lt 1) { $interval = 25 }
        if (-not $isLastItem -and ($Index % $interval) -ne 0) {
            return
        }
    }

    $prefix = ""
    if ($Total -gt 0) {
        $width = ([string]$Total).Length
        $prefix = "  [{0}/{1}] " -f ([string]$Index).PadLeft($width), $Total
    }
    else {
        $prefix = "  "
    }

    if ([string]::IsNullOrWhiteSpace($Status)) {
        Write-ConsoleLine -Message "$prefix$Name" -Colour Gray
    }
    else {
        Write-ConsoleLine -Message "$prefix$Name  $Status" -Colour Yellow
    }
}

function Write-Detail {
<#
.SYNOPSIS
    Prints counts, totals, and timings in dark grey.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $script:ConsoleSettings.ShowProgress) {
        return
    }

    Write-ConsoleLine -Message "  $Message" -Colour DarkGray
}

function Write-Success {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-ConsoleLine -Message "  $Message" -Colour Green
}

function Write-Attention {
<#
.SYNOPSIS
    Prints a magenta prompt for something needing the operator's attention.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-ConsoleLine -Message "  $Message" -Colour Magenta
}

function Write-Notice {
<#
.SYNOPSIS
    Prints a yellow non-fatal notice - skipped, repaired, culled, or retried.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-ConsoleLine -Message "  $Message" -Colour Yellow
}

#endregion

#region Paths

function Resolve-MailboxPath {
<#
.SYNOPSIS
    Resolves a configured path, which may be relative, to a full path.
.DESCRIPTION
    Relative paths are resolved against BaseDirectory rather than the caller's
    current location, so scripts behave identically regardless of where they are run from.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Cannot resolve an empty path."
    }

    $trimmedPath = $Path.Trim()

    if ([System.IO.Path]::IsPathRooted($trimmedPath)) {
        return [System.IO.Path]::GetFullPath($trimmedPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $trimmedPath))
}

function Confirm-ParentDirectory {
<#
.SYNOPSIS
    Creates the parent directory of a file path if it does not already exist.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent

    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }
}

function Get-PropertyValueOrNull {
<#
.SYNOPSIS
    Reads a property that may not exist, without tripping StrictMode.
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }

    return $Object.$Name
}

function ConvertTo-IsoUtcString {
<#
.SYNOPSIS
    Normalises a timestamp to a round-trip ISO 8601 UTC string.
.DESCRIPTION
    ConvertFrom-Json turns ISO timestamps into [datetime] objects, and casting one of
    those to [string] produces a locale-specific value such as '2/09/2026 12:00:00 AM'.
    Writing that back to JSON corrupts the timestamp for any reader on another locale,
    so every timestamp is pushed through here before it is stored or compared.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime().ToString("o")
    }

    if ($Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).ToUniversalTime().ToString("o")
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    $isoFormats = @('o', "yyyy-MM-ddTHH:mm:ss.fffffffZ", "yyyy-MM-ddTHH:mm:ssZ", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-dd HH:mm:ss")
    if ([datetime]::TryParseExact($text, $isoFormats, $invariant, $styles, [ref]$parsed)) {
        return $parsed.ToString("o")
    }

    # Local culture before invariant: on en-AU '11/08/2026' means 11 August, not 8 November.
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$parsed)) {
        return $parsed.ToString("o")
    }

    if ([datetime]::TryParse($text, $invariant, $styles, [ref]$parsed)) {
        return $parsed.ToString("o")
    }

    return $null
}

function ConvertTo-DateTimeOrNull {
<#
.SYNOPSIS
    Parses a timestamp for comparison, returning $null when it cannot be read.
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Value
    )

    $iso = ConvertTo-IsoUtcString -Value $Value
    if ($null -eq $iso) { return $null }

    return [datetime]::Parse($iso, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

#endregion

#region Size conversion

function Convert-ExoSizeToBytes {
<#
.SYNOPSIS
    Converts an Exchange Online size value to bytes.
.DESCRIPTION
    Handles the "1.5 GB (1,610,612,736 bytes)" display form, bare unit strings such as
    "4.993 GB", raw numeric values, and ByteQuantifiedSize objects. Returns [int64]0
    when no value can be determined.
#>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) {
        return [int64]0
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [int64]$Value
    }

    # ByteQuantifiedSize exposes ToBytes(); prefer it over string parsing.
    $toBytesMethod = $Value.PSObject.Methods | Where-Object { $_.Name -eq 'ToBytes' }
    if ($null -ne $toBytesMethod) {
        try {
            return [int64]$Value.ToBytes()
        }
        catch {
            # Fall through to string parsing.
        }
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [int64]0
    }

    if ($text -match '\(([\d,]+)\s*bytes\)') {
        return [int64]($matches[1] -replace ',', '')
    }

    if ($text -match '^\s*([\d,]+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)\s*$') {
        $number = [double]($matches[1] -replace ',', '')
        switch ($matches[2].ToUpperInvariant()) {
            'B'  { return [int64]$number }
            'KB' { return [int64]($number * 1KB) }
            'MB' { return [int64]($number * 1MB) }
            'GB' { return [int64]($number * 1GB) }
            'TB' { return [int64]($number * 1TB) }
        }
    }

    if ($text -match '^\s*([\d,]+(?:\.\d+)?)\s*$') {
        return [int64]([double]($matches[1] -replace ',', ''))
    }

    return [int64]0
}

function Convert-BytesToGigabytes {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter()]
        [int64]$Bytes = 0,

        [Parameter()]
        [int]$Precision = 3
    )

    if ($Bytes -le 0) {
        return [double]0.0
    }

    return [math]::Round(($Bytes / 1GB), $Precision)
}

#endregion

#region JSON I/O

function Read-MailboxJson {
<#
.SYNOPSIS
    Reads a JSON file, returning $null when the file is missing or empty.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Write-MailboxJson {
<#
.SYNOPSIS
    Writes an object to a JSON file and records an export audit entry.
.DESCRIPTION
    Writes to a temporary file and then moves it into place, so a failure part-way
    through never leaves a truncated JSON file for the dashboard to read.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter()]
        [int]$RecordCount = -1,

        [Parameter()]
        [string]$RecordDetail,

        [Parameter()]
        [int]$Depth = 12
    )

    if (-not $PSCmdlet.ShouldProcess($Path, "Write JSON")) {
        return
    }

    Confirm-ParentDirectory -Path $Path

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $tempPath = "$Path.writing"

    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -Force
    Move-Item -LiteralPath $tempPath -Destination $Path -Force

    Write-ExportAudit -Path $Path -Source $Source -RecordCount $RecordCount -RecordDetail $RecordDetail
}

#endregion

#region Export audit

function Write-ExportAudit {
<#
.SYNOPSIS
    Records how many records were written, to which file, and where they came from.
.DESCRIPTION
    Emitted on every JSON export, including exports of zero records - a silent empty
    export is the failure this audit exists to catch.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter()]
        [int]$RecordCount = -1,

        [Parameter()]
        [string]$RecordDetail
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ssZ")
    $caller = Get-CallingScriptName

    $records = if ($RecordCount -ge 0) { "$RecordCount" } else { "unknown" }
    if (-not [string]::IsNullOrWhiteSpace($RecordDetail)) {
        $records = "$records ($RecordDetail)"
    }

    Write-ConsoleLine -Message "[EXPORT] $records records -> $Path" -Colour Green
    Write-ConsoleLine -Message "         Source: $Source" -Colour DarkGray

    if ($RecordCount -eq 0) {
        Write-Notice "Export wrote 0 records - verify the source produced data."
    }

    if (-not $script:LogSettings.Enabled -or [string]::IsNullOrWhiteSpace($script:LogSettings.ExportAuditPath)) {
        return
    }

    $entry = @(
        "[EXPORT] $timestamp  $caller"
        "  Records : $records"
        "  Target  : $Path"
        "  Source  : $Source"
        ""
    ) -join [Environment]::NewLine

    Add-LogFileEntry -Path $script:LogSettings.ExportAuditPath -Content $entry
}

#endregion

#region Failure diagnostics

function Write-FailureDiagnostic {
<#
.SYNOPSIS
    Prints and logs a single diagnostic block describing a failure.
.DESCRIPTION
    Reports the script and line number that threw, the failing command, the caller's
    local variables with secrets redacted, and the full error record. Call from a catch
    block, passing the caller's variables:

        catch {
            Write-FailureDiagnostic -ErrorRecord $_ -Variables (Get-Variable -Scope 0)
            throw
        }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter()]
        [System.Management.Automation.PSVariable[]]$Variables,

        [Parameter()]
        [string]$Context
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ssZ")
    $invocation = $ErrorRecord.InvocationInfo

    $scriptName = "unknown"
    $lineNumber = 0
    $commandText = ""

    if ($null -ne $invocation) {
        if (-not [string]::IsNullOrWhiteSpace($invocation.ScriptName)) {
            $scriptName = Split-Path -Path $invocation.ScriptName -Leaf
        }
        $lineNumber = $invocation.ScriptLineNumber
        if (-not [string]::IsNullOrWhiteSpace($invocation.Line)) {
            $commandText = $invocation.Line.Trim()
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("[FAILURE] $timestamp")
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
        $lines.Add("Context: $Context")
    }
    $lines.Add("Script : $scriptName")
    $lines.Add("Line   : $lineNumber")
    if (-not [string]::IsNullOrWhiteSpace($commandText)) {
        $lines.Add("Command: $commandText")
    }
    $lines.Add("Error  : $($ErrorRecord.Exception.Message)")
    $lines.Add("Type   : $($ErrorRecord.Exception.GetType().FullName)")

    if ($script:LogSettings.IncludeVariables -and $null -ne $Variables -and $Variables.Count -gt 0) {
        $lines.Add("Variables:")
        foreach ($variable in (Get-DiagnosticVariableLine -Variables $Variables)) {
            $lines.Add($variable)
        }
    }

    $stackTraceText = $ErrorRecord.ScriptStackTrace
    if (-not [string]::IsNullOrWhiteSpace($stackTraceText)) {
        $lines.Add("StackTrace:")
        foreach ($stackLine in ($stackTraceText -split "`r?`n")) {
            $lines.Add("  $stackLine")
        }
    }

    $block = $lines -join [Environment]::NewLine

    Write-ConsoleLine ""
    Write-ConsoleLine -Message $block -Colour Red

    if ($script:LogSettings.Enabled -and -not [string]::IsNullOrWhiteSpace($script:LogSettings.FailureLogPath)) {
        Add-LogFileEntry -Path $script:LogSettings.FailureLogPath -Content ($block + [Environment]::NewLine)
    }
}

function Get-DiagnosticVariableLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSVariable[]]$Variables
    )

    $interesting = $Variables |
        Where-Object { $script:AutomaticVariableNames -notcontains $_.Name } |
        Sort-Object -Property Name

    $nameWidth = 0
    foreach ($variable in $interesting) {
        if ($variable.Name.Length -gt $nameWidth) {
            $nameWidth = $variable.Name.Length
        }
    }
    if ($nameWidth -gt 24) { $nameWidth = 24 }

    return @(
        foreach ($variable in $interesting) {
            $name = $variable.Name

            if ($name -match $script:SecretNamePattern) {
                $value = "***REDACTED***"
            }
            else {
                $value = Format-DiagnosticValue -Value $variable.Value
            }

            "  `$$($name.PadRight($nameWidth)) = $value"
        }
    )
}

function Format-DiagnosticValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) {
        return "<null>"
    }

    $text = ""

    try {
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            $items = @($Value)
            $text = "[$($items.Count) items]"
            if ($items.Count -gt 0 -and $items.Count -le 3) {
                $text = "[" + (($items | ForEach-Object { [string]$_ }) -join "; ") + "]"
            }
        }
        else {
            $text = [string]$Value
        }
    }
    catch {
        $text = "<unreadable: $($Value.GetType().Name)>"
    }

    $text = $text -replace "`r?`n", " "

    if ($text.Length -gt 200) {
        $text = $text.Substring(0, 197) + "..."
    }

    return $text
}

function Get-CallingScriptName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $callStack = Get-PSCallStack

    foreach ($frame in $callStack) {
        if ([string]::IsNullOrWhiteSpace($frame.ScriptName)) {
            continue
        }

        $leaf = Split-Path -Path $frame.ScriptName -Leaf
        if ($leaf -like "MailboxDashboard.*.psm1") {
            continue
        }

        return $leaf
    }

    return "console"
}

function Add-LogFileEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    try {
        Confirm-ParentDirectory -Path $Path
        Add-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    }
    catch {
        Write-ConsoleLine -Message "  Unable to write log file '$Path': $($_.Exception.Message)" -Colour Yellow
    }
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-MailboxDashboardConsole'
    'Write-Stage'
    'Write-Item'
    'Write-Detail'
    'Write-Success'
    'Write-Notice'
    'Write-Attention'
    'Write-ConsoleLine'
    'Resolve-MailboxPath'
    'Confirm-ParentDirectory'
    'Get-PropertyValueOrNull'
    'ConvertTo-IsoUtcString'
    'ConvertTo-DateTimeOrNull'
    'Convert-ExoSizeToBytes'
    'Convert-BytesToGigabytes'
    'Read-MailboxJson'
    'Write-MailboxJson'
    'Write-ExportAudit'
    'Write-FailureDiagnostic'
)
