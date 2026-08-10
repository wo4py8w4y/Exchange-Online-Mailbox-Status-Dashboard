---
layout: Reference
monikers:
- powershell-7.6
defaultMoniker: powershell-7.6
versioningType: Ranged
title: Start-ThreadJob (Microsoft.PowerShell.ThreadJob) - PowerShell | Microsoft Learn
canonicalUrl: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.threadjob/start-threadjob?view=powershell-7.6
config_moniker_range: powershell-7.6
uid: Microsoft.PowerShell.ThreadJob.Start-ThreadJob
module: Microsoft.PowerShell.ThreadJob
description: 'Start-ThreadJob creates background jobs similar to the Start-Job cmdlet. The main difference is that the jobs which are created run in separate threads within the local process. By default, the jobs use the current working directory of the caller that started the job. The cmdlet also supports a ThrottleLimit parameter to limit the number of jobs running at one time. As more jobs are started, they are queued and wait until the current number of jobs drops below the throttle limit. '
ROBOTS: INDEX, FOLLOW
apiPlatform: powershell
archive_url: https://learn.microsoft.com/previous-versions/powershell/scripting/overview
breadcrumb_path: /powershell/scripting/bread/toc.json
feedback_product_url: https://github.com/PowerShell/PowerShell/issues/new/choose
feedback_help_link_url: https://learn.microsoft.com/powershell/scripting/community/community-support
feedback_help_link_type: ask-the-community
feedback_system: OpenSource
hideScope: false
author: sdwheeler
ms.author: sewhee
manager: jasongroce
ms.devlang: powershell
ms.service: powershell
ms.tgt_pltfr: windows, macos, linux
ms.update-cycle: 365-days
toc_preview: true
uhfHeaderId: MSDocsHeader-Powershell
ms.topic: reference
products:
- https://authoring-docs-microsoft.poolparty.biz/devrel/2bdae855-045f-4535-b365-7b2e23824328
- https://authoring-docs-microsoft.poolparty.biz/devrel/8bce367e-2e90-4b56-9ed5-5e4e9f3a2dc3
document type: cmdlet
external help file: Microsoft.PowerShell.ThreadJob.dll-Help.xml
HelpUri: https://learn.microsoft.com/powershell/module/microsoft.powershell.threadjob/start-threadjob?view=powershell-7.6&WT.mc_id=ps-gethelp
Locale: en-us
Module Name: Microsoft.PowerShell.ThreadJob
ms.date: 2026-01-18T00:00:00.0000000Z
PlatyPS schema version: 2024-05-01T00:00:00.0000000Z
document_id: ee7123f2-704b-08f8-8880-e2715910c2e8
document_version_independent_id: 98d0bd71-29af-a0db-c211-9882d4145adf
updated_at: 2026-06-16T22:10:00.0000000Z
original_content_git_url: https://github.com/MicrosoftDocs/PowerShell-Docs/blob/live/reference/7.6/Microsoft.PowerShell.ThreadJob/Start-ThreadJob.md
gitcommit: https://github.com/MicrosoftDocs/PowerShell-Docs/blob/5b129a73fbe761fc12516c5f9776700daa0aa8a4/reference/7.6/Microsoft.PowerShell.ThreadJob/Start-ThreadJob.md
git_commit_id: 5b129a73fbe761fc12516c5f9776700daa0aa8a4
default_moniker: powershell-7.6
site_name: Docs
depot_name: PowerShell.PowerShell_PowerShell-docs_reference
in_right_rail: h2h3
page_type: powershell
page_kind: command
toc_rel: ../psdocs/toc.json
asset_id: module/microsoft.powershell.threadjob/start-threadjob
moniker_range_name: 9b5469a01154ce5be5ffa44dbe12b832
monikers:
- powershell-7.6
item_type: Content
source_path: reference/7.6/Microsoft.PowerShell.ThreadJob/Start-ThreadJob.md
cmProducts: []
platformId: d5430b5c-152c-6a3d-e33d-90e1fbb0c2cc
---

# Start-ThreadJob

- Module:
    - [Microsoft.PowerShell.ThreadJob Module](./)

Creates background jobs similar to the `Start-Job` cmdlet.

## Syntax

### ScriptBlock

```Syntax
Start-ThreadJob
    [-ScriptBlock] <ScriptBlock>
    [-Name <String>]
    [-InitializationScript <ScriptBlock>]
    [-InputObject <PSObject>]
    [-ArgumentList <Object[]>]
    [-ThrottleLimit <Int32>]
    [-StreamingHost <PSHost>]
    [<CommonParameters>]
```

### FilePath

```Syntax
Start-ThreadJob
    [-FilePath] <String>
    [-Name <String>]
    [-InitializationScript <ScriptBlock>]
    [-InputObject <PSObject>]
    [-ArgumentList <Object[]>]
    [-ThrottleLimit <Int32>]
    [-StreamingHost <PSHost>]
    [<CommonParameters>]
```

## Description

`Start-ThreadJob` creates background jobs similar to the `Start-Job` cmdlet. The main difference is that the jobs which are created run in separate threads within the local process. By default, the jobs use the current working directory of the caller that started the job.

The cmdlet also supports a **ThrottleLimit** parameter to limit the number of jobs running at one time. As more jobs are started, they are queued and wait until the current number of jobs drops below the throttle limit.

## Examples

### Example 1 - Create background jobs with a thread limit of 2

```powershell
Start-ThreadJob -ScriptBlock { 1..100 | % { sleep 1; "Output $_" } } -ThrottleLimit 2
Start-ThreadJob -ScriptBlock { 1..100 | % { sleep 1; "Output $_" } }
Start-ThreadJob -ScriptBlock { 1..100 | % { sleep 1; "Output $_" } }
Get-Job
```

```Output
Id   Name   PSJobTypeName   State        HasMoreData   Location     Command
--   ----   -------------   -----        -----------   --------     -------
1    Job1   ThreadJob       Running      True          PowerShell   1..100 | % { sleep 1;...
2    Job2   ThreadJob       Running      True          PowerShell   1..100 | % { sleep 1;...
3    Job3   ThreadJob       NotStarted   False         PowerShell   1..100 | % { sleep 1;...
```

### Example 2 - Compare the performance of Start-Job and Start-ThreadJob

This example shows the difference between `Start-Job` and `Start-ThreadJob`. The jobs run the `Start-Sleep` cmdlet for 1 second. Since the jobs run in parallel, the total execution time is about 1 second, plus any time required to create the jobs.

```powershell
# start five background jobs each running 1 second
Measure-Command {1..5 | % {Start-Job {Start-Sleep 1}} | Wait-Job} | Select-Object TotalSeconds
Measure-Command {1..5 | % {Start-ThreadJob {Start-Sleep 1}} | Wait-Job} | Select-Object TotalSeconds
```

```Output
TotalSeconds
------------
   5.7665849
   1.5735008
```

After subtracting 1 second for execution time, you can see that `Start-Job` takes about 4.8 seconds to create five jobs. `Start-ThreadJob` is 8 times faster, taking about 0.6 seconds to create five jobs. The results may vary in your environment but the relative improvement should be the same.

### Example 3 - Create jobs using InputObject

In this example, the scriptblock uses the `$input` variable to receive input from the **InputObject** parameter. This can also be done by piping objects to `Start-ThreadJob`.

```powershell
$j = Start-ThreadJob -InputObject (Get-Process pwsh) -ScriptBlock { $input | Out-String }
$j | Wait-Job | Receive-Job
```

```Output
 NPM(K)    PM(M)      WS(M)     CPU(s)      Id  SI ProcessName
 ------    -----      -----     ------      --  -- -----------
     94   145.80     159.02      18.31   18276   1 pwsh
    101   163.30     222.05      29.00   35928   1 pwsh
```

```powershell
$j = Get-Process pwsh | Start-ThreadJob -ScriptBlock { $input | Out-String }
$j | Wait-Job | Receive-Job
```

```Output
 NPM(K)    PM(M)      WS(M)     CPU(s)      Id  SI ProcessName
 ------    -----      -----     ------      --  -- -----------
     94   145.80     159.02      18.31   18276   1 pwsh
    101   163.30     222.05      29.00   35928   1 pwsh
```

### Example 4 - Stream job output to parent host

Using the **StreamingHost** parameter you can tell a job to direct all host output to a specific host. Without this parameter the output goes to the job data stream collection and doesn't appear in a host console until you receive the output from the job.

For this example, the current host is passed to `Start-ThreadJob` using the `$Host` automatic variable.

```powershell
PS> Start-ThreadJob -ScriptBlock { Read-Host 'Say hello'; Write-Warning 'Warning output' } -StreamingHost $Host

Id   Name   PSJobTypeName   State         HasMoreData     Location      Command
--   ----   -------------   -----         -----------     --------      -------
7    Job7   ThreadJob       NotStarted    False           PowerShell    Read-Host 'Say hello'; ...

PS> Say hello: Hello
WARNING: Warning output
PS> Receive-Job -Id 7
Hello
WARNING: Warning output
PS>
```

Notice that the prompt from `Read-Host` is displayed and you are able to type input. Then, the message from `Write-Warning` is displayed. The `Receive-Job` cmdlet returns all the output from the job.

### Example 5 - Download multiple files at the same time

The `Invoke-WebRequest` cmdlet can only download one file at a time. The following example uses `Start-ThreadJob` to create multiple thread jobs to download multiple files at the same time.

```powershell
$baseUri = 'https://github.com/PowerShell/PowerShell/releases/download'
$files = @(
    @{
        Uri = "$baseUri/v7.3.0-preview.5/PowerShell-7.3.0-preview.5-win-x64.msi"
        OutFile = 'PowerShell-7.3.0-preview.5-win-x64.msi'
    },
    @{
        Uri = "$baseUri/v7.3.0-preview.5/PowerShell-7.3.0-preview.5-win-x64.zip"
        OutFile = 'PowerShell-7.3.0-preview.5-win-x64.zip'
    },
    @{
        Uri = "$baseUri/v7.2.5/PowerShell-7.2.5-win-x64.msi"
        OutFile = 'PowerShell-7.2.5-win-x64.msi'
    },
    @{
        Uri = "$baseUri/v7.2.5/PowerShell-7.2.5-win-x64.zip"
        OutFile = 'PowerShell-7.2.5-win-x64.zip'
    }
)

$jobs = @()

foreach ($file in $files) {
    $jobs += Start-ThreadJob -Name $file.OutFile -ScriptBlock {
        $params = $Using:file
        Invoke-WebRequest @params
    }
}

Write-Host "Downloads started..."
Wait-Job -Job $jobs

foreach ($job in $jobs) {
    Receive-Job -Job $job
}
```

## Parameters

### -ArgumentList

Specifies an array of arguments, or parameter values, for the script that is specified by the **FilePath** or **ScriptBlock** parameters.

**ArgumentList** must be the last parameter on the command line. All the values that follow the parameter name are interpreted values in the argument list.

#### Parameter properties

| Type: | [Object](/en-us/dotnet/api/system.object)[] |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 (All) 

| Position: | Named |
| --- | --- |
| Mandatory: | False |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -FilePath

Specifies a script file to run as a background job. Enter the path and filename of the script. The script must be on the local computer or in a folder that the local computer can access.

When you use this parameter, PowerShell converts the contents of the specified script file to a scriptblock and runs the scriptblock as a background job.

#### Parameter properties

| Type: | [String](/en-us/dotnet/api/system.string) |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 FilePath 

| Position: | 0 |
| --- | --- |
| Mandatory: | True |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -InitializationScript

Specifies commands that run before the job starts. Enclose the commands in braces (`{}`) to create a scriptblock.

Use this parameter to prepare the session in which the job runs. For example, you can use it to add functions and modules to the session.

#### Parameter properties

| Type: | [ScriptBlock](/en-us/dotnet/api/system.management.automation.scriptblock) |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 (All) 

| Position: | Named |
| --- | --- |
| Mandatory: | False |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -InputObject

Specifies the objects used as input to the scriptblock. It also allows for pipeline input. Use the `$input` automatic variable in the scriptblock to access the input objects.

#### Parameter properties

| Type: | [PSObject](/en-us/dotnet/api/system.management.automation.psobject) |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 (All) 

| Position: | Named |
| --- | --- |
| Mandatory: | False |
| Value from pipeline: | True |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -Name

Specifies a friendly name for the new job. You can use the name to identify the job to other job cmdlets, such as the `Stop-Job` cmdlet.

The default friendly name is "Job#", where "#" is an ordinal number that is incremented for each job.

#### Parameter properties

| Type: | [String](/en-us/dotnet/api/system.string) |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 (All) 

| Position: | Named |
| --- | --- |
| Mandatory: | False |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -ScriptBlock

Specifies the commands to run in the background job. Enclose the commands in braces (`{}`) to create a scriptblock. Use the `$input` automatic variable to access the value of the **InputObject** parameter. This parameter is required.

#### Parameter properties

| Type: | [ScriptBlock](/en-us/dotnet/api/system.management.automation.scriptblock) |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 ScriptBlock 

| Position: | 0 |
| --- | --- |
| Mandatory: | True |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -StreamingHost

This parameter provides a thread safe way to allow `Write-Host` output to go directly to the passed in **PSHost** object. Without it, `Write-Host` output goes to the job information data stream collection and doesn't appear in a host console until after the jobs finish running.

#### Parameter properties

| Type: | [PSHost](/en-us/dotnet/api/system.management.automation.host.pshost) |
| --- | --- |
| Default value: | None |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 (All) 

| Position: | Named |
| --- | --- |
| Mandatory: | False |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### -ThrottleLimit

This parameter limits the number of jobs running at one time. As jobs are started, they are queued and wait until a thread is available in the thread pool to run the job. The default limit is 5 threads.

The thread pool size is global to the PowerShell session. Specifying a **ThrottleLimit** in one call sets the limit for subsequent calls in the same session.

#### Parameter properties

| Type: | [Int32](/en-us/dotnet/api/system.int32) |
| --- | --- |
| Default value: | 5 |
| Supports wildcards: | False |
| DontShow: | False |

#### Parameter sets

 (All) 

| Position: | Named |
| --- | --- |
| Mandatory: | False |
| Value from pipeline: | False |
| Value from pipeline by property name: | False |
| Value from remaining arguments: | False |

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable, -ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## Inputs

### [PSObject](/en-us/dotnet/api/system.management.automation.psobject)

## Outputs

### ThreadJob.ThreadJob

## Related Links

- [Start-Job](../microsoft.powershell.core/start-job)
- [Stop-Job](../microsoft.powershell.core/stop-job)
- [Receive-Job](../microsoft.powershell.core/receive-job)

---

## Other Supported Versions

- [powershell-7.7](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.threadjob/start-threadjob?view=powershell-7.7&accept=text/markdown)
