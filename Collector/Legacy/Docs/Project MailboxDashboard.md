Exchange Online Mailbox Dashboard Project Summary

Current Project Status

Phase: Historical Data Service Build

The project is focused on building a production-ready Exchange Online mailbox monitoring and analytics platform hosted in IIS. The current effort is concentrating on collecting and storing historical mailbox data before building the dashboard and reporting layers.

The design philosophy is:

1     Exchange Online

2             ↓

3     Historical Collector

4             ↓

5     history.json

6             ↓

7     Dashboard / Reporting

8             ↓

9     Alerts & Analytics

The historical data layer is considered the foundation of the entire solution.

Project Milestones

✅ Milestone 1 - Solution Architecture

Completed:

* Overall architecture defined
* IIS hosting model selected
* Historical collection strategy defined
* Exchange Online module selected as primary data source
* Authentication approach identified

Deliverables:

1     Architecture design

2     Folder structure

3     Configuration model

4     JSON schemas

✅ Milestone 2 - Historical Data Model

Completed:

Historical data structure defined using:

1     ExchangeGuid

as the primary key.

Reason:

1     SMTP addresses may change.

2     ExchangeGuid remains constant.

Historical records survive:

* Mailbox renames
* Alias changes
* SMTP address updates

✅ Milestone 3 - Configuration Framework

Completed:

1     dashboardConfig.json

contains:

* Tenant
* AppID
* Certificate Thumbprint
* Paths
* Thresholds
* Refresh settings

✅ Milestone 4 - Historical Collector Development

Currently Under Test

Collector now supports:

1     Mailbox Size

2     Quota

3     Usage %

4     Item Count

5     Permission Count

6     Archive Enabled

7     Archive Size

8     Archive Item Count

9     Last Logon Time

Data Sources:

1     Get-EXOMailbox

2     Get-EXOMailboxStatistics

3     Get-EXOMailboxStatistics -Archive

4     Get-EXOMailboxPermission

✅ Milestone 5 - Historical JSON Storage

Completed

Target File:

1     history.json

Contains:

1     Mailbox Identity

2     Historical Samples

3     Quota Information

4     Archive Information

5     Usage Statistics

Current Testing Status

Current approach:

1     Register-EntraApp.ps1

2     Start-HistoryCollectorThreaded.ps1

Current auth:

1     App-only Exchange Online

2     Client secret stored in dashboardConfig.json

3     Threaded collector connects automatically

Setup walkthrough:

1     [Collector/Setup-Walkthrough.md](C:/TEMP/MailboxDashboard/Collector/Setup-Walkthrough.md)

Remaining Milestones

🔄 Milestone 6 - Logging Framework

To Build:

1     Logging.psm1

Capabilities:

1     Timestamped log files

2     Tagged log entries

3     Error tracking

4     Runtime tracking

Tags:

1     START

2     CONFIG

3     INPUT

4     EXO

5     QUERY

6     JSON

7     HISTORY

8     THRESHOLD

9     ALERT

10     REPORT

11     ERROR

12     END

🔄 Milestone 7 - Current Snapshot Service

To Build:

1     data.json

Purpose:

Store latest mailbox state.

Example:

1     Current mailbox size

2     Current quota

3     Current permissions

4     Current utilization

🔄 Milestone 8 - Dashboard UI

Pages:

Overview

1     Mailbox Count

2     Storage Consumption

3     Health Status

Thresholds

1     Mailboxes > Critical Threshold

History

1     Mailbox Growth Trends

Permissions

1     Mailbox Permissions

🔄 Milestone 9 - Scheduling

Task Scheduler Integration

Collector runs:

1     Every 30 minutes

🔄 Milestone 10 - Alerting

Planned:

Email Alerts

1     Mailbox > 94%

Teams Alerts

1     Adaptive Card / Webhook Notification

Key Scripts and Their Purpose

HistoryCollector.ps1

Purpose

Collect historical mailbox statistics.

Inputs

1     mailboxes.csv

2     dashboardConfig.json

Outputs

1     history.json

Collects

1     ExchangeGuid

2     PrimarySmtpAddress

3     DisplayName

4     Mailbox Size

5     Quota

6     Usage%

7     Item Count

8     Permission Count

9     Last Logon

10     Archive Size

11     Archive Item Count

Start-HistoryCollectorThreaded.ps1

Purpose

Run parallel historical collection using PowerShell thread jobs.

Responsibilities

1     Split dashboard.csv into worker batches

2     Create a delegated Exchange Online access token

3     Connect each worker to Exchange Online using the access token

4     Run HistoryCollector.ps1 for each batch

5     Merge worker output back into history.json

Get-ExchangeOnlineAccessToken.ps1

Purpose

Create a delegated Exchange Online access token using browser sign-in.

Update-MailboxDashboard.ps1

Purpose

Main orchestrator.

Responsibilities

1     Load Configuration

2     Load Modules

3     Connect Exchange Online

4     Collect Data

5     Generate Reports

6     Update Dashboard

7     Send Alerts

Outputs

1     data.json

2     history.json

3     reports

Logging.psm1

Purpose

Central logging system.

Functions

1     Initialize-Logging

2     Write-Log

3     Close-Logging

Output

1     Timestamped Log Files

ExchangeCollector.psm1

Purpose

Exchange Online data collection module.

Functions

1     Connect-ExOCollector

2

3     Get-MailboxStatistics

4

5     Get-MailboxQuota

6

7     Get-MailboxPermissions

8

9     Get-MailboxArchiveStatistics

JsonStorage.psm1

Purpose

JSON file management.

Functions

1     Load-History

2

3     Save-History

4

5     Save-CurrentSnapshot

6

7     Validate-Json

Thresholds.psm1

Purpose

Threshold calculations.

Outputs

1     OK

2     WARNING

3     CRITICAL

Default Values

1     Warning  = 85%

2     Critical = 94%

Alerts.psm1

Purpose

Notification engine.

Methods

1     Email

2     Teams

Trigger

1     Usage >= Critical Threshold

Scheduler.psm1

Purpose

Manage Windows Scheduled Task.

Responsibilities

1     Create Task

2     Update Task

3     Validate Schedule

JSON Summary For Another LLM

1     {

2       "project": {

3         "name": "Exchange Online Mailbox Dashboard",

4         "status": "In Development",

5         "phase": "Historical Data Collection"

6       },

7       "completedMilestones": [

8         "Solution Architecture",

9         "Historical Data Model",

10         "Configuration Framework",

11         "Historical JSON Storage"

12       ],

13       "activeMilestone": {

14         "name": "Historical Collector Development",

15         "status": "Testing",

16         "script": "HistoryCollector.ps1"

17       },

18       "nextMilestones": [

19         "Logging Framework",

20         "Current Snapshot Service",

21         "Dashboard UI",

22         "Scheduling",

23         "Alerting"

24       ],

25       "historyTracking": {

26         "primaryKey": "ExchangeGuid",

27         "reason": "Mailbox renames and SMTP changes do not affect ExchangeGuid"

28       },

29       "dataSources": [

30         "Get-EXOMailbox",

31         "Get-EXOMailboxStatistics",

32         "Get-EXOMailboxStatistics -Archive",

33         "Get-EXOMailboxPermission"

34       ],

35       "collectedMetrics": [

36         "ExchangeGuid",

37         "PrimarySmtpAddress",

38         "DisplayName",

39         "MailboxSizeGB",

40         "QuotaGB",

41         "UsagePercent",

42         "ItemCount",

43         "PermissionCount",

44         "LastLogonTime",

45         "ArchiveEnabled",

46         "ArchiveSizeGB",

47         "ArchiveItemCount"

48       ],

49       "scripts": [

50         {

51           "name": "HistoryCollector.ps1",

52           "purpose": "Collect historical mailbox data and store history.json"

53         },

54         {

55           "name": "Start-HistoryCollectorThreaded.ps1",

56           "purpose": "Run HistoryCollector.ps1 in parallel thread jobs and merge the results"

57         },

58         {

59           "name": "Update-MailboxDashboard.ps1",

60           "purpose": "Master orchestration script"

61         },

62         {

63           "name": "Logging.psm1",

64           "purpose": "Logging framework"

65         },

66         {

67           "name": "ExchangeCollector.psm1",

68           "purpose": "Exchange Online data collection"

69         },

70         {

71           "name": "JsonStorage.psm1",

72           "purpose": "History and snapshot JSON management"

73         },

70         {

71           "name": "Thresholds.psm1",

72           "purpose": "Capacity threshold calculations"

73         },

74         {

75           "name": "Alerts.psm1",

76           "purpose": "Teams and email notifications"

77         },

78         {

79           "name": "Scheduler.psm1",

80           "purpose": "Scheduled task management"

81         }

82       ],

83       "thresholds": {

84         "warning": 85,

85         "critical": 94

86       },

87       "schedule": {

88         "intervalMinutes": 30

89       },

90       "outputs": [

91         "history.json",

92         "data.json",

93         "reports",

94         "logs"

95       ]

96     }
