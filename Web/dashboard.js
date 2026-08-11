const DATA_URL = "data.json";
const HISTORY_URL = "history.json";
let refreshTimer = null;
let refreshMs = 60000;
let historyData = null;

// The bulletproof global data array
window.allMailboxes = [];

document.addEventListener("DOMContentLoaded", () => {
    // Universal Header Buttons
    const refreshButton = document.getElementById("refreshButton");
    if (refreshButton) {
        refreshButton.addEventListener("click", () => loadDashboard().catch(showError));
    }

    // Universal Theme Toggle
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

    // Universal Search Bar
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
        historyData = await historyResponse.json();
    }

    // BULLETPROOF DATA PARSING
    // Automatically figures out if the JSON is an array, an object, or has a timestamp at index 0
    let rawArray = Array.isArray(rawDashboardData) ? rawDashboardData : (rawDashboardData.mailboxes || []);
    let startIndex = (rawArray.length > 0 && typeof rawArray[0] === "string") ? 1 : 0;
    
    window.allMailboxes = [];
    
    for (let i = startIndex; i < rawArray.length; i++) {
        let m = rawArray[i];
        if (!m) continue;

        let normalized = {
            exchangeGuid: m.ExchangeGuid || m.exchangeGuid,
            primarySmtpAddress: m.PrimarySmtpAddress || m.primarySmtpAddress,
            displayName: m.DisplayName || m.displayName || m.PrimarySmtpAddress,
            current: m.current || {},
            permissions: m.permissions || []
        };

        // Handle nested "Samples" format
        if (m.Samples && m.Samples.length > 0) {
            let latest = m.Samples[m.Samples.length - 1];
            normalized.current = {
                totalGB: latest.SizeGB || 0,
                itemCount: latest.ItemCount || 0,
                quotaGB: latest.QuotaGB || 50,
                usagePercent: latest.UsagePercent || 0,
                lastLogonTime: latest.LastLogonTime
            };
            normalized.permissions = new Array(latest.PermissionCount || 0);
        } 
        // Handle Flat format
        else if (m.MailboxSizeGB !== undefined) {
            normalized.current = {
                totalGB: m.MailboxSizeGB || 0,
                itemCount: m.ItemCount || 0,
                quotaGB: m.QuotaGB || 50,
                usagePercent: m.UsagePercent || 0,
                lastLogonTime: m.LastLogonTime
            };
            normalized.permissions = new Array(m.PermissionCount || 0);
        }

        window.allMailboxes.push(normalized);
    }

    populateSearchDropdown(window.allMailboxes);
    highlightNav();
    updateLastUpdated(rawArray[0]); // Pushes timestamp if it exists

    applyFilter(); // Trigger page rendering
}

// --- Search / Filter Logic ---
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
    if (!searchInput || !searchInput.value) return window.allMailboxes;

    const term = searchInput.value.toLowerCase();
    return window.allMailboxes.filter(m => 
        (m.displayName && m.displayName.toLowerCase().includes(term)) ||
        (m.primarySmtpAddress && m.primarySmtpAddress.toLowerCase().includes(term))
    );
}

function applyFilter() {
    const page = document.body.getAttribute("data-page");
    const count = getMailboxes().length;
    const tableTitle = document.getElementById("tableTitle");
    const searchInput = document.getElementById("mailboxSearch");

    // Route logic based on active HTML page
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
        if (tableTitle && searchInput) {
            tableTitle.textContent = searchInput.value ? `Historical storage (Viewing match 1 of ${count})` : "Historical storage (Viewing first mailbox)";
        }
    } else if (page === "permissions") {
        renderPermissionsTable();
    } else if (page === "thresholds") {
        renderThresholdsTable();
    }
}

// --- Specific Page Renderers ---
function renderUsageTable() {
    const tbody = document.querySelector("#usageTable tbody");
    if (!tbody) return;
    tbody.innerHTML = "";
    
    const mailboxes = getMailboxes();
    if (mailboxes.length === 0) {
        tbody.innerHTML = `<tr><td colspan="8" style="text-align:center;">No mailboxes found matching that search.</td></tr>`;
        return;
    }

    mailboxes.sort((a, b) => b.current.totalGB - a.current.totalGB).forEach(m => {
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

function renderHistoryPage() {
    const mailboxes = getMailboxes();
    const tbody = document.querySelector("#historyTable tbody");
    
    if (mailboxes.length === 0) {
        if(tbody) tbody.innerHTML = `<tr><td colspan="4">No mailbox selected or found.</td></tr>`;
        drawHistoryChart([]); 
        return;
    }

    // Always chart the FIRST mailbox in the filtered list
    const guid = mailboxes[0].exchangeGuid;
    const histPoints = historyData?.[guid] || [];

    if (tbody) {
        tbody.innerHTML = "";
        if (histPoints.length === 0) {
            tbody.innerHTML = `<tr><td colspan="4">No history data available in history.json for this mailbox.</td></tr>`;
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

function renderPermissionsTable() {
    const tbody = document.querySelector("#permsTable tbody");
    if (!tbody) return;
    tbody.innerHTML = `<tr><td colspan="4">Permission export disabled or unsupported in current payload schema.</td></tr>`;
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

    if (count === 0) tbody.innerHTML = `<tr><td colspan="5">No mailboxes currently over warning/critical thresholds.</td></tr>`;
}

// --- Charting & Helpers ---
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

function updateTopCards() {
    const mailboxes = getMailboxes();
    const countEl = document.getElementById("mailboxCount");
    const totalStorageEl = document.getElementById("totalStorage");
    const thresholdEl = document.getElementById("thresholdCount");
    const largestEl = document.getElementById("largestMailbox");

    if (countEl) countEl.textContent = formatNumber(mailboxes.length);
    if (totalStorageEl) totalStorageEl.textContent = `${formatGB(mailboxes.reduce((acc, m) => acc + m.current.totalGB, 0))} GB`;
    if (thresholdEl) thresholdEl.textContent = formatNumber(mailboxes.filter(m => m.current.usagePercent >= 85).length);
    if (largestEl) {
        if (mailboxes.length === 0) largestEl.textContent = "N/A";
        else {
            const largest = mailboxes.reduce((prev, curr) => (prev.current.totalGB > curr.current.totalGB) ? prev : curr);
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
    let totalUsed = mailboxes.reduce((acc, m) => acc + m.current.totalGB, 0);
    let totalQuota = mailboxes.reduce((acc, m) => acc + m.current.quotaGB, 0);
    if(totalQuota === 0) totalQuota = 1;
    
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

    const top = getMailboxes().sort((a, b) => b.current.totalGB - a.current.totalGB).slice(0, 10);
    if (top.length === 0) return;

    const maxVal = top[0].current.totalGB || 1, chartHeight = canvas.height - 60;
    const barSpacing = (canvas.width - 40) / top.length, barWidth = barSpacing * 0.6;

    top.forEach((m, idx) => {
        const barH = (m.current.totalGB / maxVal) * chartHeight;
        const x = 20 + idx * barSpacing + (barSpacing - barWidth) / 2, y = canvas.height - 30 - barH;

        ctx.fillStyle = "#0078d4";
        ctx.fillRect(x, y, barWidth, barH);
        
        ctx.fillStyle = getCssVariable("--text-primary") || "#333";
        ctx.textAlign = "center";
        ctx.fillText(m.current.totalGB.toFixed(1), x + barWidth / 2, y - 5);
        
        ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
        ctx.fillText(m.displayName.substring(0, 8) + "..", x + barWidth / 2, canvas.height - 10);
    });
}

function resetAutoRefreshTimer() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(() => loadDashboard().catch(showError), refreshMs);
}

function updateLastUpdated(utcString) {
    const el = document.getElementById("lastUpdated");
    if (el) el.textContent = utcString ? `Last updated: ${new Date(utcString).toLocaleString()}` : "Data unavailable";
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