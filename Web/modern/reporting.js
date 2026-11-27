(function (root, factory) {
    "use strict";
    const api = factory();
    if (typeof module === "object" && module.exports) module.exports = api;
    root.MailboxReporting = api;
})(typeof window === "undefined" ? globalThis : window, function () {
    "use strict";

    const DAY_MS = 86400000;

    function finiteNumber(value) {
        if (value === null || value === undefined || value === "") return null;
        const number = Number(value);
        return Number.isFinite(number) ? number : null;
    }

    function daysSince(value, now = Date.now()) {
        const date = value instanceof Date ? value : new Date(value);
        if (!value || Number.isNaN(date.getTime())) return null;
        return Math.max(0, Math.floor((now - date.getTime()) / DAY_MS));
    }

    function statusOf(mailbox, warningThreshold = 85, criticalThreshold = 94) {
        const quota = finiteNumber(mailbox.quotaGB);
        const usage = finiteNumber(mailbox.usagePercent);
        if (quota === null || quota <= 0) return "unlimited";
        if ((usage ?? 0) >= 100) return "over";
        if ((usage ?? 0) >= criticalThreshold) return "critical";
        if ((usage ?? 0) >= warningThreshold) return "warning";
        return "healthy";
    }

    function aggregate(mailboxes, now = Date.now()) {
        const summary = {
            mailboxCount: mailboxes.length,
            primaryGB: 0,
            archiveGB: 0,
            archiveCount: 0,
            warningCount: 0,
            criticalCount: 0,
            overQuotaCount: 0,
            inactive90Count: 0,
            licenseGapCount: 0,
            noRetentionPolicyCount: 0,
            delegationCount: 0
        };

        for (const mailbox of mailboxes) {
            const status = mailbox.status || statusOf(mailbox);
            summary.primaryGB += finiteNumber(mailbox.totalGB) ?? 0;
            summary.archiveGB += finiteNumber(mailbox.archiveGB) ?? 0;
            summary.archiveCount += mailbox.archiveEnabled ? 1 : 0;
            summary.warningCount += status === "warning" ? 1 : 0;
            summary.criticalCount += status === "critical" ? 1 : 0;
            summary.overQuotaCount += status === "over" ? 1 : 0;
            const inactiveDays = daysSince(mailbox.lastLogon, now);
            summary.inactive90Count += inactiveDays === null || inactiveDays >= 90 ? 1 : 0;
            summary.licenseGapCount += mailbox.licenseRequired === true && mailbox.hasLicense === false ? 1 : 0;
            summary.noRetentionPolicyCount += !mailbox.retentionPolicy ? 1 : 0;
            summary.delegationCount += Array.isArray(mailbox.permissions) ? mailbox.permissions.length : 0;
        }

        return summary;
    }

    function buildReport(type, mailboxes, now = Date.now()) {
        if (!Array.isArray(mailboxes)) throw new TypeError("Mailboxes must be an array.");

        if (type === "capacity") {
            return {
                title: "Mailbox capacity",
                headers: ["Mailbox", "SMTP address", "Type", "Primary GB", "Archive GB", "Quota GB", "Usage percent", "Status"],
                rows: mailboxes
                    .slice()
                    .sort((a, b) => (finiteNumber(b.usagePercent) ?? -1) - (finiteNumber(a.usagePercent) ?? -1))
                    .map(mailbox => [
                        mailbox.name, mailbox.smtp, mailbox.type, mailbox.totalGB, mailbox.archiveGB,
                        mailbox.quotaGB ?? "", mailbox.usagePercent ?? "", mailbox.status || statusOf(mailbox)
                    ])
            };
        }

        if (type === "activity") {
            return {
                title: "Mailbox activity",
                headers: ["Mailbox", "SMTP address", "Last logon UTC", "Days inactive", "Status"],
                rows: mailboxes
                    .slice()
                    .sort((a, b) => (daysSince(b.lastLogon, now) ?? Infinity) - (daysSince(a.lastLogon, now) ?? Infinity))
                    .map(mailbox => [
                        mailbox.name, mailbox.smtp, mailbox.lastLogon ? new Date(mailbox.lastLogon).toISOString() : "",
                        daysSince(mailbox.lastLogon, now) ?? "", mailbox.status || statusOf(mailbox)
                    ])
            };
        }

        if (type === "licensing") {
            return {
                title: "Mailbox licensing",
                headers: ["Mailbox", "SMTP address", "Mailbox type", "License required", "License assigned", "License type", "Compliance"],
                rows: mailboxes.map(mailbox => [
                    mailbox.name, mailbox.smtp, mailbox.type, mailbox.licenseRequired,
                    mailbox.hasLicense, mailbox.licenseType,
                    mailbox.licenseRequired === true && mailbox.hasLicense === false ? "Gap" :
                        mailbox.licenseRequired === false || mailbox.hasLicense === true ? "Compliant" : "Unknown"
                ])
            };
        }

        if (type === "permissions") {
            const rows = [];
            for (const mailbox of mailboxes) {
                for (const permission of Array.isArray(mailbox.permissions) ? mailbox.permissions : []) {
                    rows.push([
                        mailbox.name, mailbox.smtp, permission.User ?? permission.user ?? "",
                        [].concat(permission.AccessRights ?? permission.accessRights ?? []).join("; "),
                        permission.IsInherited ?? permission.isInherited ?? false
                    ]);
                }
            }
            return {
                title: "Mailbox permissions",
                headers: ["Mailbox", "SMTP address", "Delegate", "Access rights", "Inherited"],
                rows
            };
        }

        if (type === "retention") {
            return {
                title: "Retention and holds",
                headers: ["Mailbox", "SMTP address", "Retention policy", "Litigation hold"],
                rows: mailboxes.map(mailbox => [
                    mailbox.name, mailbox.smtp, mailbox.retentionPolicy, mailbox.litigationHold
                ])
            };
        }

        throw new RangeError(`Unknown report type '${type}'.`);
    }

    function toCsv(report) {
        const quote = value => {
            const text = value === null || value === undefined ? "" : String(value);
            return `"${text.replace(/"/g, "\"\"")}"`;
        };
        return [report.headers, ...report.rows]
            .map(row => row.map(quote).join(","))
            .join("\r\n");
    }

    return {
        aggregate,
        buildReport,
        daysSince,
        finiteNumber,
        statusOf,
        toCsv
    };
});
