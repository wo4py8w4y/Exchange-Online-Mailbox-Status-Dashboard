const DATA_URL = "data.json";
const HISTORY_URL = "history.json";
let refreshTimer = null;
let refreshMs = 60000;
let historyData = createEmptyHistoryData();

// Global array holding normalized mailbox records
window.allMailboxes = [];

document.addEventListener("DOMContentLoaded", () => {
    // Universal Header Controls
    const refreshButton = document.getElementById("refreshButton");
    if (refreshButton) {
        refreshButton.addEventListener("click", () => loadDashboard().catch(showError));
    }

    const themeBtn = document.getElementById('themeToggle');
    if (themeBtn) {
        themeBtn.textContent = document.documentElement.getAttribute('data-theme') === 'light' ? 'Switch to Dark Mode' : 'Switch to Light Mode';
        themeBtn.addEventListener('click', () => {
            let currentTheme = document.documentElement.getAttribute('data-theme');
            let newTheme = currentTheme === 'light' ? 'dark' : 'light';
            document.documentElement.setAttribute('data-theme', newTheme);
            localStorage.setItem('dashboardTheme', newTheme);
            themeBtn.textContent = newTheme === 'light' ? 'Switch to Dark Mode' : 'Switch to Light Mode';
        });
    }

    // Search Controls
    const searchInput = document.getElementById("mailboxSearch");
    if (searchInput) searchInput.addEventListener("input", applyFilter);

    const clearBtn = document.getElementById("clearSearchBtn");
    if (clearBtn) {
        clearBtn.addEventListener("click", () => {
            if (searchInput) searchInput.value = "";
            applyFilter();
        });
    }

    loadDashboard().catch(showError);
    resetAutoRefreshTimer();
});

async function loadDashboard() {
    const dataUrl = `${DATA_URL}?cacheBust=${Date.now()}`;
    const historyUrl = `${HISTORY_URL}?cacheBust=${Date.now()}`;

    const [dataResponse, historyResponse] = await Promise.all([
        fetch(dataUrl, { cache: "no-store" }),
        fetch(historyUrl, { cache: "no-store" })
    ]);

    if (!dataResponse.ok) throw new Error(`Could not load ${DATA_URL}`);

    const rawDashboardData = await dataResponse.json();
    
    if (historyResponse.ok) {
        historyData = normaliseHistoryData(await historyResponse.json());
    } else {
        historyData = createEmptyHistoryData();
    }

    // 1. Extract array safely (handles top-level arrays or wrapped properties)
    const rawArray = extractMailboxArray(rawDashboardData);

    // 2. Normalize every record into a consistent schema
    window.allMailboxes = rawArray.map(normaliseMailbox);

    // 3. Targeted Diagnostic Logging for QFleet
    const targetSmtp = "QFleet.AccountsReceivable@hpw.qld.gov.au".toLowerCase();
    const targetMailbox = window.allMailboxes.find(m => m.primarySmtpAddress.toLowerCase() === targetSmtp);

    if (!targetMailbox) {
        console.error("Target mailbox missing from payload:", targetSmtp);
        console.table(window.allMailboxes.map(m => ({
            DisplayName: m.displayName,
            PrimarySmtpAddress: m.primarySmtpAddress,
            StorageGB: m.current.totalGB,
            ItemCount: m.current.itemCount
        })));
    } else {
        console.info("Target mailbox successfully bound:", targetMailbox);
    }

    populateSearchDropdown(getSearchMailboxSource());
    updateLastUpdated(
        rawDashboardData?.GeneratedUtc ||
        rawDashboardData?.generatedUtc ||
        historyData.generatedUtc
    );
    highlightNav();

    // 4. Render active page
    applyFilter();
}

// --- Search & Filter Methods ---

function populateSearchDropdown(mailboxes) {
    const dataList = document.getElementById('mailboxList');
    if (!dataList) return;
    dataList.innerHTML = ''; 
    mailboxes.forEach(m => {
        const option = document.createElement('option');
        option.value = m.primarySmtpAddress;
        option.textContent = m.displayName;
        dataList.appendChild(option);
    });
}

function getMailboxes() {
    const searchInput = document.getElementById("mailboxSearch");
    const searchText = searchInput ? searchInput.value : "";
    return filterMailboxes(getSearchMailboxSource(), searchText);
}

function getSearchMailboxSource() {
    const page = document.body.getAttribute("data-page");
    if (page === "history" && historyData.mailboxes.length > 0) {
        return historyData.mailboxes;
    }
    return window.allMailboxes;
}

function applyFilter() {
    const page = document.body.getAttribute("data-page");
    const count = getMailboxes().length;
    const tableTitle = document.getElementById("tableTitle");
    const searchInput = document.getElementById("mailboxSearch");

    if (page === "overview") {
        updateTopCards();
        drawDonutChart();
        drawBarChart();
        renderUsageTable();
        if (tableTitle && searchInput) {
            tableTitle.textContent = searchInput.value ? `Current usage (Filtered: ${count})` : "Current usage";
        }
    } else if (page === "history") {
        renderHistoryPage();
    } else if (page === "permissions") {
        renderPermissionsTable();
    } else if (page === "thresholds") {
        renderThresholdsTable();
    }
}

// --- Page Renderers ---

function renderUsageTable() {
    const tbody = document.querySelector("#usageTable tbody");
    if (!tbody) return;
    tbody.innerHTML = "";
    
    const mailboxes = getMailboxes();
    if (mailboxes.length === 0) {
        tbody.innerHTML = `<tr><td colspan="8" style="text-align:center; padding: 20px;">No mailboxes found matching that search.</td></tr>`;
        return;
    }

    mailboxes.sort((a, b) => (b.current.totalGB || 0) - (a.current.totalGB || 0)).forEach(m => {
        const tr = document.createElement("tr");
        tr.innerHTML = `
            <td>${escapeHtml(m.displayName)}</td>
            <td>${escapeHtml(m.primarySmtpAddress)}</td>
            <td>${formatGB(m.current.totalGB)}</td>
            <td>${formatNumber(m.current.itemCount)}</td>
            <td>${formatGB(m.current.quotaGB)}</td>
            <td>${usageBadge(m.current.usagePercent)}</td>
            <td>${formatNumber(m.permissions.length)}</td>
            <td>${formatDate(m.current.lastLogonTime)}</td>
        `;
        tbody.appendChild(tr);
    });
}

function renderPermissionsTable() {
    const tbody = document.querySelector("#permsTable tbody");
    if (!tbody) return;
    tbody.innerHTML = "";

    const searchInput = document.getElementById("mailboxSearch");
    const filterTerm = searchInput ? searchInput.value.toLowerCase() : "";

    const mailboxes = window.allMailboxes || [];
    let hasAny = false;

    mailboxes.forEach(m => {
        const perms = m.permissions || [];
        if (!Array.isArray(perms)) return;

        perms.forEach(p => {
            const mailboxName = (m.displayName || m.primarySmtpAddress || "").toLowerCase();
            const delegateName = (p.User || p.user || p.Delegate || "").toLowerCase();

            // Apply search filter if one exists
            if (filterTerm && !mailboxName.includes(filterTerm) && !delegateName.includes(filterTerm)) {
                return; // Skip if it doesn't match the search
            }

            hasAny = true;
            const tr = document.createElement("tr");

            // Handle rights array or string safely
            let rights = p.AccessRights || p.accessRights || p.Rights || [];
            let rightsStr = Array.isArray(rights) ? rights.join(", ") : String(rights);

            tr.innerHTML = `
                <td>${escapeHtml(m.displayName || m.primarySmtpAddress)}</td>
                <td>${escapeHtml(p.User || p.user || p.Delegate || "")}</td>
                <td>${escapeHtml(rightsStr)}</td>
                <td>${(p.IsInherited || p.isInherited) ? "Yes" : "No"}</td>
            `;
            tbody.appendChild(tr);
        });
    });

    if (!hasAny) {
        tbody.innerHTML = `<tr><td colspan="4" style="text-align:center; padding: 20px;">No explicit permissions found matching search criteria.</td></tr>`;
    }
}

function renderThresholdsTable() {
    const tbody = document.querySelector("#thresholdTable tbody");
    if (!tbody) return;
    tbody.innerHTML = "";

    const mailboxes = getMailboxes();
    let count = 0;

    mailboxes.forEach(m => {
        const pct = m.current.usagePercent || 0;
        if (pct >= 85) {
            count++;
            const state = pct >= 94 ? "Critical" : "Warning";
            const tr = document.createElement("tr");
            tr.innerHTML = `
                <td>${escapeHtml(m.displayName)}</td>
                <td>${formatGB(m.current.totalGB)}</td>
                <td>${formatGB(m.current.quotaGB)}</td>
                <td>${usageBadge(pct)}</td>
                <td><span class="badge ${state === 'Critical' ? 'danger' : 'warning'}">${state}</span></td>
            `;
            tbody.appendChild(tr);
        }
    });

    if (count === 0) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;">No mailboxes currently over warning/critical thresholds.</td></tr>`;
    }
}

function renderHistoryPage() {
    const mailboxes = getMailboxes();
    const tbody = document.querySelector("#historyTable tbody");

    if (mailboxes.length === 0) {
        if (tbody) tbody.innerHTML = `<tr><td colspan="4">No mailbox selected or found.</td></tr>`;
        drawHistoryChart([]);
        return;
    }

    const histPoints = getHistoryPointsForMailbox(mailboxes[0]);

    if (tbody) {
        tbody.innerHTML = "";
        if (histPoints.length === 0) {
            tbody.innerHTML = `<tr><td colspan="4">No history data available for this mailbox.</td></tr>`;
        } else {
            const sortedDesc = [...histPoints].sort((a, b) => new Date(b.TimestampUtc || b.Timestamp) - new Date(a.TimestampUtc || a.Timestamp));
            for (const pt of sortedDesc) {
                const tr = document.createElement("tr");
                const size = pt.SizeGB ?? pt.TotalGB ?? 0;
                tr.innerHTML = `
                    <td>${formatDate(pt.TimestampUtc || pt.Timestamp)}</td>
                    <td>${formatGB(size)}</td>
                    <td>${formatNumber(pt.ItemCount)}</td>
                    <td>${(pt.UsagePercent || 0).toFixed(1) + "%"}</td>
                `;
                tbody.appendChild(tr);
            }
        }
    }
    drawHistoryChart(histPoints);
}

// --- Cards & Canvas Charts ---

function updateTopCards() {
    const mailboxes = getMailboxes();
    const countEl = document.getElementById("mailboxCount");
    const totalStorageEl = document.getElementById("totalStorage");
    const thresholdEl = document.getElementById("thresholdCount");
    const largestEl = document.getElementById("largestMailbox");

    if (countEl) countEl.textContent = formatNumber(mailboxes.length);
    if (totalStorageEl) totalStorageEl.textContent = `${formatGB(mailboxes.reduce((acc, m) => acc + (m.current.totalGB || 0), 0))} GB`;
    if (thresholdEl) thresholdEl.textContent = formatNumber(mailboxes.filter(m => (m.current.usagePercent || 0) >= 85).length);
    if (largestEl) {
        if (mailboxes.length === 0) largestEl.textContent = "N/A";
        else {
            const largest = mailboxes.reduce((prev, curr) => ((prev.current.totalGB || 0) > (curr.current.totalGB || 0)) ? prev : curr);
            largestEl.textContent = `${largest.displayName} (${formatGB(largest.current.totalGB)} GB)`;
        }
    }
}

function drawDonutChart() {
    const canvas = document.getElementById("usageDonutChart");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const mailboxes = getMailboxes();
    let totalUsed = mailboxes.reduce((acc, m) => acc + (m.current.totalGB || 0), 0);
    let totalQuota = mailboxes.reduce((acc, m) => acc + (m.current.quotaGB || 50), 0);
    if (totalQuota === 0) totalQuota = 1;

    const cx = canvas.width / 2, cy = canvas.height / 2, radius = Math.min(cx, cy) * 0.7;
    ctx.lineWidth = 40;

    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, 2 * Math.PI);
    ctx.strokeStyle = getCssVariable("--border-color") || "#eee";
    ctx.stroke();

    if (totalUsed > 0) {
        ctx.beginPath();
        ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + (totalUsed / totalQuota) * 2 * Math.PI);
        ctx.strokeStyle = "#0078d4";
        ctx.stroke();
    }

    ctx.fillStyle = getCssVariable("--text-primary") || "#333";
    ctx.font = "bold 24px sans-serif";
    ctx.textAlign = "center";
    ctx.fillText(((totalUsed / totalQuota) * 100).toFixed(1) + "%", cx, cy);
}

function drawBarChart() {
    const canvas = document.getElementById("topStorageChart");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const top = getMailboxes().sort((a, b) => (b.current.totalGB || 0) - (a.current.totalGB || 0)).slice(0, 10);
    if (top.length === 0) return;

    const maxVal = top[0].current.totalGB || 1, chartHeight = canvas.height - 60;
    const barSpacing = (canvas.width - 40) / top.length, barWidth = barSpacing * 0.6;

    top.forEach((m, idx) => {
        const val = m.current.totalGB || 0;
        const barH = (val / maxVal) * chartHeight;
        const x = 20 + idx * barSpacing + (barSpacing - barWidth) / 2, y = canvas.height - 30 - barH;

        ctx.fillStyle = "#0078d4";
        ctx.fillRect(x, y, barWidth, barH);

        ctx.fillStyle = getCssVariable("--text-primary") || "#333";
        ctx.textAlign = "center";
        ctx.fillText(val.toFixed(1), x + barWidth / 2, y - 5);

        ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
        ctx.fillText((m.displayName || m.primarySmtpAddress).substring(0, 8) + "..", x + barWidth / 2, canvas.height - 10);
    });
}

function drawHistoryChart(histPoints) {
    const canvas = document.getElementById("historyStorageChart");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (!histPoints || histPoints.length < 2) {
        ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
        ctx.font = "14px sans-serif";
        ctx.textAlign = "center";
        ctx.fillText("Not enough history points to chart.", canvas.width / 2, canvas.height / 2);
        return;
    }

    const sorted = [...histPoints].sort((a, b) => new Date(a.TimestampUtc || a.Timestamp) - new Date(b.TimestampUtc || b.Timestamp));
    let minVal = 0;
    let maxVal = Math.max(...sorted.map(p => p.SizeGB ?? p.TotalGB ?? 0)) * 1.2 || 10;

    const padX = 40, padY = 40;
    const chartW = canvas.width - padX * 2, chartH = canvas.height - padY * 2;
    const getX = (index) => padX + (index / (sorted.length - 1)) * chartW;
    const getY = (val) => (canvas.height - padY) - ((val - minVal) / (maxVal - minVal)) * chartH;

    ctx.beginPath();
    ctx.strokeStyle = "#0078d4";
    ctx.lineWidth = 3;
    sorted.forEach((pt, i) => {
        const x = getX(i), y = getY(pt.SizeGB ?? pt.TotalGB ?? 0);
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    });
    ctx.stroke();

    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.textAlign = "right";
    ctx.fillText(maxVal.toFixed(1) + " GB", padX - 10, padY);
}

// --- Extraction & Schema Normalisation Utility Helpers ---

function getNumber(record, propertyNames) {
    for (const propertyName of propertyNames) {
        const value = record?.[propertyName];
        if (value !== undefined && value !== null && value !== "") {
            const number = Number(value);
            if (Number.isFinite(number)) return number;
        }
    }
    return null;
}

function createEmptyHistoryData() {
    return {
        generatedUtc: null,
        mailboxes: [],
        byGuid: {},
        bySmtp: {}
    };
}

function extractMailboxArray(payload) {
    if (Array.isArray(payload)) {
        // Strip string timestamp at index 0 if present
        return (payload.length > 0 && typeof payload[0] === "string") ? payload.slice(1) : payload;
    }
    if (Array.isArray(payload.mailboxes)) return payload.mailboxes;
    if (Array.isArray(payload.Mailboxes)) return payload.Mailboxes;
    if (Array.isArray(payload.data)) return payload.data;
    if (Array.isArray(payload.value)) return payload.value;
    return [];
}

function normaliseHistoryData(payload) {
    const normalised = createEmptyHistoryData();
    if (!payload || typeof payload !== "object") return normalised;

    normalised.generatedUtc =
        payload.GeneratedUtc ??
        payload.generatedUtc ??
        null;

    const mailboxHistory = Array.isArray(payload.MailboxHistory)
        ? payload.MailboxHistory
        : Array.isArray(payload.mailboxHistory)
            ? payload.mailboxHistory
            : null;

    if (mailboxHistory) {
        mailboxHistory.forEach(record => {
            addHistoryMailboxRecord(normalised, record);
        });
        return normalised;
    }

    if (Array.isArray(payload)) {
        payload.forEach(record => {
            addHistoryMailboxRecord(normalised, record);
        });
        return normalised;
    }

    Object.entries(payload).forEach(([key, value]) => {
        if (key === "GeneratedUtc" || key === "generatedUtc" || !Array.isArray(value)) return;

        const samples = normaliseHistorySamples(value);
        if (samples.length === 0) return;

        normalised.byGuid[key] = samples;
    });

    return normalised;
}

function addHistoryMailboxRecord(target, record) {
    const mailbox = normaliseMailbox(record);
    const samples = normaliseHistorySamples(record?.Samples ?? record?.samples);
    if (samples.length === 0) return;

    target.mailboxes.push(mailbox);

    if (mailbox.exchangeGuid) {
        target.byGuid[mailbox.exchangeGuid] = samples;
    }

    if (mailbox.primarySmtpAddress) {
        target.bySmtp[mailbox.primarySmtpAddress.toLowerCase()] = samples;
    }
}

function normaliseHistorySamples(samples) {
    if (!Array.isArray(samples)) return [];

    return samples
        .filter(sample => sample && typeof sample === "object")
        .map(sample => ({
            TimestampUtc: sample.TimestampUtc ?? sample.timestampUtc ?? sample.Timestamp ?? sample.timestamp ?? null,
            SizeGB: getNumber(sample, ["SizeGB", "sizeGB", "TotalGB", "totalGB", "StorageGB", "MailboxSizeGB"]) ?? 0,
            ItemCount: getNumber(sample, ["ItemCount", "itemCount", "Items"]) ?? 0,
            UsagePercent: getNumber(sample, ["UsagePercent", "usagePercent"]) ?? 0
        }));
}

function normaliseMailbox(source) {
    const smtpAddress =
        source.PrimarySmtpAddress ??
        source.primarySmtpAddress ??
        source.SmtpAddress ??
        source.UserPrincipalName ??
        source.Mailbox?.PrimarySmtpAddress ??
        "";

    const displayName =
        source.DisplayName ??
        source.displayName ??
        source.MailboxName ??
        source.Mailbox?.DisplayName ??
        smtpAddress;

    // Check nested Samples array
    let sample = {};
    if (Array.isArray(source.Samples) && source.Samples.length > 0) {
        sample = source.Samples[source.Samples.length - 1];
    } else if (source.current) {
        sample = source.current;
    }

    const storageGB = getNumber(sample, ["SizeGB", "totalGB", "StorageGB", "TotalItemSizeGB", "MailboxSizeGB"]) 
        ?? getNumber(source, ["SizeGB", "totalGB", "StorageGB", "TotalItemSizeGB", "MailboxSizeGB"]) 
        ?? 0;

    const quotaGB = getNumber(sample, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]) 
        ?? getNumber(source, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]) 
        ?? 50;

    const itemCount = getNumber(sample, ["ItemCount", "itemCount", "Items"]) 
        ?? getNumber(source, ["ItemCount", "itemCount", "Items"]) 
        ?? 0;

    const usagePercent = getNumber(sample, ["UsagePercent", "usagePercent"]) 
        ?? (quotaGB > 0 ? (storageGB / quotaGB) * 100 : 0);

    const permCount = getNumber(sample, ["PermissionCount"]) 
        ?? (Array.isArray(source.permissions) ? source.permissions.length : 0);

    return {
        exchangeGuid: source.ExchangeGuid || source.exchangeGuid || "",
        displayName: String(displayName),
        primarySmtpAddress: String(smtpAddress),
        current: {
            totalGB: storageGB,
            itemCount: itemCount,
            quotaGB: quotaGB,
            usagePercent: usagePercent,
            lastLogonTime: sample.LastLogonTime ?? sample.lastLogonTime ?? source.LastLogonTime ?? null
        },
        permissions: source.permissions || new Array(permCount)
    };
}

function getHistoryPointsForMailbox(mailbox) {
    if (!mailbox) return [];

    if (mailbox.exchangeGuid && Array.isArray(historyData.byGuid[mailbox.exchangeGuid])) {
        return historyData.byGuid[mailbox.exchangeGuid];
    }

    const smtpAddress = String(mailbox.primarySmtpAddress || "").toLowerCase();
    if (smtpAddress && Array.isArray(historyData.bySmtp[smtpAddress])) {
        return historyData.bySmtp[smtpAddress];
    }

    return [];
}

function extractPermissions(payload) {
    if (!Array.isArray(payload)) return [];
    
    return payload.flatMap(mailbox => {
        const smtpAddress = mailbox.primarySmtpAddress || mailbox.displayName || "";
        const permissions = mailbox.permissions || [];
        
        if (!Array.isArray(permissions)) return [];

        return permissions.map(permission => ({
            mailbox: smtpAddress,
            delegate: permission.Delegate ?? permission.user ?? permission.User ?? "",
            rights: permission.AccessRights ?? permission.accessRights ?? permission.Rights ?? [],
            inherited: permission.IsInherited ?? permission.isInherited ?? false
        }));
    });
}

function filterMailboxes(mailboxes, searchText) {
    const search = String(searchText || "").trim().toLowerCase();
    if (!search) return mailboxes;

    return mailboxes.filter(m => {
        const displayName = String(m.displayName || "").toLowerCase();
        const smtpAddress = String(m.primarySmtpAddress || "").toLowerCase();
        return displayName.includes(search) || smtpAddress.includes(search);
    });
}

// --- System Utility Helpers ---
function resetAutoRefreshTimer() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(() => loadDashboard().catch(showError), refreshMs);
}

function updateLastUpdated(utcString) {
    const el = document.getElementById("lastUpdated");
    if (el) el.textContent = (utcString && typeof utcString === "string") ? `Last updated: ${new Date(utcString).toLocaleString()}` : "Data loaded";
}

function highlightNav() {
    const page = document.body.getAttribute("data-page");
    document.querySelectorAll("nav.view-nav a").forEach(link => {
        link.classList.remove("active");
        if ((page === "overview" && link.getAttribute("href").includes("index.html")) || link.getAttribute("href").includes(`${page}.html`)) {
            link.classList.add("active");
        }
    });
}

function showError(error) { console.error(error); }
function escapeHtml(str) { return String(str || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
function formatGB(val) { return (val || 0).toFixed(2); }
function formatNumber(val) { return (val || 0).toLocaleString(); }
function formatDate(isoString) { return isoString ? new Date(isoString).toLocaleString() : "N/A"; }
function usageBadge(percent) {
    const pStr = (percent || 0).toFixed(1) + "%";
    if (percent >= 94) return `<span class="badge danger">${pStr}</span>`;
    if (percent >= 85) return `<span class="badge warning">${pStr}</span>`;
    return pStr;
}
function getCssVariable(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }