---
goal: Deliver dashboard operations visibility, collection monitoring, and transition-based email alerts
version: 1.0
date_created: 2026-10-03
last_updated: 2026-10-03
status: 'In progress'
tags: [feature, dashboard, operations, monitoring, alerting]
---

# Introduction

![Status: In progress](https://img.shields.io/badge/status-In%20progress-yellow)

This plan covers all three next milestones in `.copilot/prompt.json`: dashboard enhancements, operational monitoring, and alerting. It adds a durable collection-status artifact, exposes run health in the existing dashboard, and sends Microsoft Graph email only when monitored conditions appear, change, or recover.

## 1. Requirements & Constraints

- **REQ-001**: Implement the three roadmap milestones together: dashboard enhancements, operational monitoring, and alerting.
- **REQ-002**: After configuration loads successfully, record each orchestrated collection run's UTC start/end, final outcome, test-data flag, configured stale threshold, and pipeline-step names, outcomes, and durations in a versioned JSON status artifact.
- **REQ-003**: Display the latest run outcome, run age, duration, and stale-data state on the existing dashboard overview without hiding or changing existing mailbox workflows.
- **REQ-004**: Detect threshold-condition transitions using `ExchangeGuid` as the durable mailbox key; notify on new conditions, severity changes, and resolutions, but do not repeat unchanged conditions each run.
- **REQ-005**: Detect collection pipeline failure and recovery transitions and include them in notification processing.
- **REQ-006**: Deliver configured alerts through Microsoft Graph `sendMail`; batch all transitions from one collection into one email.
- **REQ-007**: Disable email notifications by default. Enabling notifications requires a configured sender mailbox and one or more recipients.
- **REQ-008**: While notifications are disabled, do not send mail or advance alert deduplication state; the first enabled run must report currently active conditions.
- **REQ-009**: Provide a separate interactive PowerShell operator menu for the collector and dashboard data workflows; present only actions whose required configuration, scripts, or input files are currently available.
- **REQ-010**: Include setup, live collection, isolated demo-data generation, explicit live demo-data replacement, snapshot regeneration, report-only validation, repair/cull, local dashboard hosting, and shareable-URL generation when their prerequisites are met.
- **REQ-011**: Require an explicit confirmation before any menu action that changes live history/snapshot data or repairs/culls stored records; never pass `-Force` or `-NoBackup` implicitly.
- **SEC-001**: Use app-only Graph authentication suitable for scheduled collection. Require the Microsoft Graph `Mail.Send` application permission and tenant admin consent; do not grant permissions automatically during setup.
- **SEC-002**: Never write access tokens, client secrets, or full email message bodies to status, alert-state, or failure-log files. Keep collection-status output aggregate-only.
- **CON-001**: Preserve Windows PowerShell 5.1 compatibility and existing configuration defaults, legacy path compatibility, and sequential collection behavior.
- **CON-002**: The dashboard remains a static site reading JSON files; do not add a server-side API or change the `history.json` / `data.json` mailbox formats.
- **CON-003**: Use the existing 30-minute schedule as the baseline when evaluating collection freshness.
- **GUD-001**: Resolve new filesystem paths through `MailboxDashboard.Config.psm1`; write status and alert-state JSON atomically.
- **GUD-002**: Surface status-file and notification-delivery errors explicitly; a notification failure must not erase a recorded collection outcome or silently advance deduplication state.
- **PAT-001**: Use `ExchangeGuid` for per-mailbox alert-state keys and retain the dashboard's existing mailbox query-string, search, scope, sorting, and navigation behavior.
- **ASSUMPTION-001**: “Dashboard enhancements” means adding operational run-health visibility to the current overview; no additional user-facing feature list is present in the roadmap input.
- **ASSUMPTION-002**: The default stale threshold is 60 minutes (twice the roadmap's 30-minute collection interval) and remains configurable.

## 2. Implementation Steps

### Implementation Phase 1 — Operational monitoring

- **GOAL-001**: Produce a schema-versioned status file for every orchestrated run. Completion is verified when successful and failed `-TestData` runs both leave valid, accurate status JSON, including step durations and final status.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | In `Collector/Modules/MailboxDashboard.Config.psm1`, add backward-compatible defaults for `Paths.CollectionStatusJson` (`..\Web\collection-status.json`) and `Monitoring.StaleAfterMinutes` (60), resolve the new path through the existing path resolver, and reject non-positive stale thresholds. Add matching safe defaults to `Collector/Config/dashboardConfig.example.json` and ignore the generated status file in `.gitignore`. | [x] | 2026-10-03 |
| TASK-002 | Add `Collector/Modules/MailboxDashboard.Operations.psm1` with `Write-MailboxDashboardCollectionStatus`. Update `Collector/Invoke-MailboxDashboardCollection.ps1` to track success/failure across the try/catch/finally path, retain each `Invoke-PipelineStep` result, and atomically write `collection-status.json` from `finally`, including when an earlier pipeline step throws. Include schema version, run ID, UTC timestamps, mode, test-data flag, `Monitoring.StaleAfterMinutes`, aggregate step outcomes/durations, and a sanitized failure summary; do not include mailbox identifiers or secrets. | [x] | 2026-10-03 |
| TASK-003 | Create `Collector/Tests/Operations.Tests.ps1` with Pester tests for default/legacy configuration loading, status schema and UTC fields, successful and failed run outcomes, atomic replacement, and absence of secrets or mailbox-level data. | [x] | 2026-10-03 |

### Implementation Phase 2 — Dashboard enhancements

- **GOAL-002**: Show collection health and freshness in the current overview. Completion is verified when current status renders, stale status is visibly distinct, and missing status does not prevent mailbox data from loading.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-004 | In `Web/index.html` and `Web/dashboard.js`, add an operational status panel and load `collection-status.json` alongside the existing dashboard data. Display last run outcome, localized finish time, elapsed time, and freshness against the stale threshold embedded in that status artifact; render missing or invalid status as an explicit unavailable/error state without treating the mailbox dataset as failed. Preserve existing refresh, search, scope, and navigation behavior. | [x] | 2026-10-03 |
| TASK-005 | In `Web/styles.css`, style healthy, failed, stale, and unavailable states with responsive layout, sufficient contrast, and status text that remains understandable without color. | [x] | 2026-10-03 |
| TASK-006 | Add `Web/collection-status.schema.json`; validate the artifact against it in the Pester suite. Update `Readme.md` with status fields, freshness semantics, generated-file handling, and operator troubleshooting. Verify the dashboard in a browser using `Invoke-MailboxDashboardCollection.ps1 -TestData` and confirm existing overview interactions still work. | [x] | 2026-10-03 |

### Implementation Phase 3 — Transition-based email alerting

- **GOAL-003**: Send secure, deduplicated Graph email for new/changed threshold conditions and collection failure/recovery. Completion is verified by mocked tests covering each transition and by a separately authorized Graph send-mail smoke test.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-007 | Extend configuration defaults and validation in `Collector/Modules/MailboxDashboard.Config.psm1` with `Notifications.Enabled` (false), `Notifications.SenderMailbox`, `Notifications.Recipients`, and `Paths.AlertStateJson` (under `Collector/Logs`). Add matching non-secret example values to `dashboardConfig.example.json`; require a sender and at least one valid recipient only when notifications are enabled. | [x] | 2026-10-03 |
| TASK-008 | In `MailboxDashboard.Operations.psm1`, implement app-only Microsoft Graph authentication using the configured tenant/application and existing certificate or client-secret credentials, then submit messages to `POST /users/{sender}/sendMail`. Load Graph authentication support only when notifications are enabled, require the documented `Mail.Send` application permission, honor `-WhatIf`, and log delivery failures without logging tokens or message bodies. | [x] | 2026-10-03 |
| TASK-009 | Add transition detection and durable alert-state handling to `MailboxDashboard.Operations.psm1`. After a valid snapshot is generated, compare current warning/critical mailbox states with persisted states keyed by `ExchangeGuid`; create one batched email for new conditions, severity changes, and resolutions. Evaluate pipeline failure/recovery from run status in `finally`, even when a snapshot was not produced. Do not send or advance alert state while notifications are disabled. Persist the new alert state only after Graph confirms delivery; unchanged active conditions must not send another email. Record notification delivery outcome separately from collection outcome in the status artifact. | [x] | 2026-10-03 |
| TASK-010 | Extend `Collector/Tests/Operations.Tests.ps1` to mock Graph calls and verify disabled-by-default behavior, missing-setting validation, first alert, no repeat, severity change, resolution, collection failure/recovery, `-WhatIf`, Graph rejection, and retry behavior when delivery fails. Tests must not make network calls or overwrite the operator's live dashboard data. | [x] | 2026-10-03 |
| TASK-011 | Update `Readme.md` with Graph app-only setup, `Mail.Send` admin consent, sender/recipient configuration, transition and retry semantics, `-WhatIf` usage, and troubleshooting for permission and delivery failures. Run the JSON validator and the documented test-data/browser smoke checks before marking the plan complete. | [x] | 2026-10-03 |

### Implementation Phase 4 — Contextual operator menu

- **GOAL-004**: Let operators drive supported collector, data, validation, and local dashboard workflows from one safe interactive PowerShell entry point. Completion is verified when each option is availability-gated and every live-data mutation requires explicit confirmation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-012 | Create `Collector/Start-MailboxDashboardMenu.ps1`. Build a fresh option list on every menu redraw using the configured config, CSV, history, and snapshot paths plus required scripts. Include setup, live collection, isolated demo generation, confirmed demo-data replacement, snapshot regeneration, report-only validation, confirmed repair/cull, local hosting, and shareable URL generation. Require a typed `YES` confirmation for live-data replacement and repair/cull; create timestamped backups before replacement; invoke existing scripts with argument arrays and preserve their exit/errors. | [x] | 2026-10-03 |
| TASK-013 | Extend `Collector/Tests/Operations.Tests.ps1` or add `Collector/Tests/Menu.Tests.ps1` to test contextual option availability, confirmation cancellation, backup creation before live replacement, and safe non-mutating menu actions without invoking Exchange or starting a persistent server. Update `Readme.md` quick start and script reference with the menu entry point and its safety behavior. | [x] | 2026-10-03 |

## 3. Alternatives

- **ALT-001**: Dashboard-only alerts were not selected because they cannot notify operators when the dashboard is not open.
- **ALT-002**: SMTP relay was not selected; Microsoft Graph `sendMail` is the user-selected delivery method.
- **ALT-003**: Re-sending all active conditions on every collection run was not selected because the user requested notifications only for new or changed conditions.
- **ALT-004**: Automatically granting Graph application permissions from `Register-EntraApp.ps1` was rejected to keep tenant-wide mail-sending authorization explicit and administrator-controlled.
- **ALT-005**: Putting operator controls in the browser dashboard was not selected; the user requested a PowerShell operator menu for collector and data tasks.

## 4. Dependencies

- **DEP-001**: `TASK-002` must produce the collection-status JSON contract before `TASK-004` consumes it.
- **DEP-002**: `TASK-009` uses the status from `TASK-002` for pipeline failure/recovery notifications; threshold notifications require a successfully generated snapshot from the existing `Generate-MailboxSnapshot.ps1` stage.
- **DEP-003**: An administrator must grant `Mail.Send` application permission and admin consent, and configure an authorized sender mailbox before live Graph delivery can be tested.
- **DEP-004**: Pester must be available to run `Collector/Tests/Operations.Tests.ps1`; the test suite must mock Graph transport and use temporary data paths.
- **DEP-005**: `TASK-012` delegates work to existing scripts and requires a configuration or the setup script; options that consume data require the corresponding configured input files.

## 5. Files

- **FILE-001**: `Collector/Modules/MailboxDashboard.Config.psm1` — new monitoring/notification defaults, path resolution, and conditional validation.
- **FILE-002**: `Collector/Config/dashboardConfig.example.json` — safe monitoring and notification configuration examples.
- **FILE-003**: `Collector/Modules/MailboxDashboard.Operations.psm1` — status persistence, transition detection, Graph mail delivery, and alert-state persistence.
- **FILE-004**: `Collector/Invoke-MailboxDashboardCollection.ps1` — per-run outcome capture and status/notification orchestration.
- **FILE-005**: `Collector/Tests/Operations.Tests.ps1` — focused configuration, status, transition, and mocked-delivery tests.
- **FILE-006**: `Web/collection-status.schema.json` — schema for the generated collection-status artifact.
- **FILE-007**: `Web/index.html` — overview operational status panel.
- **FILE-008**: `Web/dashboard.js` — status loading, freshness calculation, and rendering.
- **FILE-009**: `Web/styles.css` — accessible operational status states.
- **FILE-010**: `.gitignore` — exclude generated status output.
- **FILE-011**: `Readme.md` — configuration, permissions, operational semantics, and validation documentation.
- **FILE-012**: `Collector/Start-MailboxDashboardMenu.ps1` — contextual, confirmation-gated PowerShell operations menu.
- **FILE-013**: `Collector/Tests/Menu.Tests.ps1` — menu option, confirmation, backup, and safety tests.

## 6. Testing

- **TEST-001**: Run Pester tests for legacy configuration compatibility, default monitoring values, notification validation, status schema, and atomic status writes.
- **TEST-002**: Simulate successful and failed collection runs with temporary paths; verify the final status and per-step timings reflect the actual run outcome.
- **TEST-003**: Mock Graph transport and verify every alert transition, stable-state deduplication, retry after delivery failure, `-WhatIf`, and disabled-notification behavior without network access.
- **TEST-004**: Generate synthetic dashboard data, run `Test-MailboxDashboardJSON.ps1`, and browse `http://localhost:8888/`; verify healthy, stale, failed, and unavailable status cases plus existing search/scope/navigation behavior.
- **TEST-005**: After explicit tenant consent, run one controlled Graph send-mail smoke test to a designated test recipient and verify no credentials or message body appear in logs or generated JSON.
- **TEST-006**: Use non-interactive menu tests with temporary config/data to verify unavailable operations are omitted, cancellation performs no write, and confirmed live-data replacement creates recoverable backups first.

Implementation checks completed: 13 focused Pester tests passed; the synthetic-data collection and JSON validation succeeded; PowerShell parsing and JavaScript syntax checks passed; browser checks confirmed the healthy status panel, mailbox search, scope selection, and theme selection. The live Graph send-mail smoke test remains pending tenant admin consent and an authorized test recipient; browser rendering of stale, failed, and unavailable status variants was not exercised.

## 7. Risks & Assumptions

- **RISK-001**: `Mail.Send` application permission can authorize broad mailbox access. Use a dedicated sender mailbox and have the tenant administrator review and constrain the app's mailbox access according to the tenant's Exchange application-access controls.
- **RISK-002**: A lost Graph response after server-side acceptance can cause a duplicate on retry; delivery is therefore at-least-once, while persisted state prevents repeats after confirmed delivery.
- **RISK-003**: A missing or unwritable status artifact can make dashboard health unavailable; status-write failures must be visible in the pipeline result and failure log.
- **ASSUMPTION-003**: Existing certificate/client-secret app credentials are available for unattended runs; interactive-only authentication is not sufficient for scheduled Graph notification delivery.
- **ASSUMPTION-004**: Mailbox threshold alert states use the configured `Thresholds.WarningPercent` and `Thresholds.CriticalPercent`; no new threshold values are introduced by this plan.
- **ASSUMPTION-005**: The operator menu is a separate script entry point; scheduled automation continues to call the existing non-interactive scripts directly.

## 8. Related Specifications / Further Reading

- [Roadmap input](../.copilot/prompt.json)
- [Project operator guide](../Readme.md)
- [Microsoft Graph `sendMail` API](https://learn.microsoft.com/graph/api/user-sendmail?view=graph-rest-1.0)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
- [Microsoft Graph PowerShell authentication](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands?view=graph-powershell-1.0)
