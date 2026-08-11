const DATA_URL = "data.json";
const HISTORY_URL = "history.json";
let refreshTimer = null;
let refreshMs = 60000;
let dashboardData = null;
let historyData = null;

document.addEventListener("DOMContentLoaded", () => {
    const refreshButton = document.getElementById("refreshButton");
    if (refreshButton) {
        refreshButton.addEventListener("click", () => loadDashboard().catch(showError));
    }

    const mailboxSelect = document.getElementById("mailboxSelect");
    if (mailboxSelect) {
        mailboxSelect.addEventListener("change", renderHistoryPage);
    }

    // Search and Filter Listeners
    const searchInput = document.getElementById("mailboxSearch");
    if (searchInput) {
        searchInput.addEventListener("input", applyFilter);
    }

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

    if (!dataResponse.ok) {
        throw new Error(`Could not load ${DATA_URL}: ${dataResponse.status}`);
    }

    dashboardData = await dataResponse.json();

    if (dashboardData.webRefreshSeconds) {
        refreshMs = Number(dashboardData.webRefreshSeconds) * 1000;
        resetAutoRefreshTimer();
    }

    if (historyResponse.ok) {
        historyData = await historyResponse.json();
    } else {
        console.warn(`Could not load ${HISTORY_URL}, history charts may be empty.`);
    }

    populateSearchDropdown(dashboardData.mailboxes || []);
    highlightNav();

    const page = document.body.getAttribute("data-page");
    if (page === "overview") {
        updateLastUpdated(dashboardData.generatedUtc);
        applyFilter(); // Renders cards, charts, and table with current filter state
    } else if (page === "history") {
        populateHistorySelect();
        renderHistoryPage();
    } else if (page === "permissions") {
        renderPermissionsTable();
    } else if (page === "thresholds") {
        renderThresholdsTable();
    }
}

// --- Search / Filter Logic ---

function populateSearchDropdown(mailboxes) {
    const dataList = document.getElementById('mailboxList');
    if (!dataList) return;
    
    dataList.innerHTML = ''; 
    mailboxes.forEach(m => {
        if (!m.error) {
            const option = document.createElement('option');
            option.value = m.primarySmtpAddress;
            option.textContent = m.displayName || m.primarySmtpAddress;
            dataList.appendChild(option);
        }
    });
}

function getMailboxes() {
    const allMailboxes = dashboardData?.mailboxes || [];
    const searchInput = document.getElementById("mailboxSearch");
    
    // If no search input exists on the page, or it's empty, return everything
    if (!searchInput || !searchInput.value) {
        return allMailboxes;
    }

    const term = searchInput.value.toLowerCase();
    
    // Filter by DisplayName or SMTP Address
    return allMailboxes.filter(m => 
        (m.displayName && m.displayName.toLowerCase().includes(term)) ||
        (m.primarySmtpAddress && m.primarySmtpAddress.toLowerCase().includes(term))
    );
}

function applyFilter() {
    updateTopCards();
    drawDonutChart();
    drawBarChart();
    renderUsageTable();

    const searchInput = document.getElementById("mailboxSearch");
    const tableTitle = document.getElementById("tableTitle");
    if (tableTitle && searchInput) {
        const count = getMailboxes().length;
        tableTitle.textContent = searchInput.value ? `Current usage (Filtered: ${count})` : "Current usage";
    }
}

// --- Render Logic ---

function resetAutoRefreshTimer() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(() => {
        loadDashboard().catch(showError);
    }, refreshMs);
}

function updateLastUpdated(utcString) {
    const el = document.getElementById("lastUpdated");
    if (!el) return;
    if (!utcString) {
        el.textContent = "Data unavailable";
        return;
    }
    const d = new Date(utcString);
    el.textContent = `Last updated: ${d.toLocaleString()}`;
}

function highlightNav() {
    const page = document.body.getAttribute("data-page");
    if (!page) return;
    const links = document.querySelectorAll("nav.view-nav a");
    links.forEach(link => {
        link.classList.remove("active");
        const href = link.getAttribute("href");
        if (
            (page === "overview" && href.includes("index.html")) ||
            href.includes(`${page}.html`)
        ) {
            link.classList.add("active");
        }
    });
}

function showError(error) {
    const lastUpdated = document.getElementById("lastUpdated");
    if (lastUpdated) {
        lastUpdated.textContent = error.message;
    }
    console.error(error);
}

function renderUsageTable() {
    const tbody = document.querySelector("#usageTable tbody");
    if (!tbody) return;

    tbody.innerHTML = "";
    const mailboxes = getMailboxes();

    if (mailboxes.length === 0) {
        tbody.innerHTML = `<tr><td colspan="8" style="text-align:center; padding: 20px;">No mailboxes found matching that search.</td></tr>`;
        return;
    }

    for (const m of mailboxes) {
        const tr = document.createElement("tr");

        if (m.error) {
            tr.innerHTML = `
                <td>${escapeHtml(m.primarySmtpAddress || m.displayName)}</td>
                <td colspan="7"><span class="badge danger">Error</span> ${escapeHtml(m.error)}</td>
            `;
        } else {
            tr.innerHTML = `
                <td>${escapeHtml(m.primarySmtpAddress)}</td>
                <td>${escapeHtml(m.recipientTypeDetails || "")}</td>
                <td>${formatGB(m.current?.totalGB)}</td>
                <td>${formatNumber(m.current?.itemCount)}</td>
                <td>${formatGB(m.current?.quotaGB)}</td>
                <td>${usageBadge(m.current?.usagePercent)}</td>
                <td>${formatNumber(m.permissions?.length || 0)}</td>
                <td>${formatDate(m.current?.lastLogonTime)}</td>
            `;
        }
        tbody.appendChild(tr);
    }
}

function updateTopCards() {
    const mailboxes = getMailboxes();
    let validBoxes = mailboxes.filter(m => !m.error && m.current);

    const countEl = document.getElementById("mailboxCount");
    if (countEl) countEl.textContent = formatNumber(mailboxes.length);

    const totalStorageEl = document.getElementById("totalStorage");
    if (totalStorageEl) {
        const sumGB = validBoxes.reduce((acc, m) => acc + (m.current.totalGB || 0), 0);
        totalStorageEl.textContent = `${formatGB(sumGB)} GB`;
    }

    const totalPermsEl = document.getElementById("totalPermissions");
    if (totalPermsEl) {
        const sumPerms = validBoxes.reduce((acc, m) => acc + (m.permissions?.length || 0), 0);
        totalPermsEl.textContent = formatNumber(sumPerms);
    }

    const thresholdEl = document.getElementById("thresholdCount");
    if (thresholdEl) {
        const threshSettings = dashboardData?.thresholds || { warningPercent: 80, criticalPercent: 95 };
        const overWarn = validBoxes.filter(m => m.current.usagePercent >= threshSettings.warningPercent).length;
        thresholdEl.textContent = formatNumber(overWarn);
    }

    const largestEl = document.getElementById("largestMailbox");
    if (largestEl) {
        if (validBoxes.length === 0) {
            largestEl.textContent = "N/A";
        } else {
            const largest = validBoxes.reduce((prev, current) => {
                return (prev.current.totalGB > current.current.totalGB) ? prev : current;
            });
            largestEl.textContent = `${largest.displayName || largest.primarySmtpAddress} (${formatGB(largest.current.totalGB)} GB)`;
        }
    }
}

function drawDonutChart() {
    const canvas = document.getElementById("usageDonutChart");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const mailboxes = getMailboxes();
    let totalUsed = 0;
    let totalFree = 0;

    for (const m of mailboxes) {
        if (m.error || !m.current) continue;
        const used = m.current.totalGB || 0;
        const quota = m.current.quotaGB || 50; 
        totalUsed += used;
        totalFree += Math.max(0, quota - used);
    }

    if (totalUsed === 0 && totalFree === 0) {
        totalFree = 1; 
    }

    const cx = canvas.width / 2;
    const cy = canvas.height / 2;
    const radius = Math.min(cx, cy) * 0.7;

    const total = totalUsed + totalFree;
    const usedAngle = (totalUsed / total) * 2 * Math.PI;

    ctx.lineWidth = 40;
    ctx.lineCap = "round";

    // Draw background track (Free space)
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, 2 * Math.PI);
    ctx.strokeStyle = getCssVariable("--border-color") || "#eee";
    ctx.stroke();

    // Draw used track
    if (usedAngle > 0) {
        ctx.beginPath();
        ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + usedAngle);
        ctx.strokeStyle = "#0078d4";
        ctx.stroke();
    }

    // Inner text
    ctx.fillStyle = getCssVariable("--text-primary") || "#333";
    ctx.font = "bold 24px sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const percentStr = total > 0 ? ((totalUsed / total) * 100).toFixed(1) + "%" : "0%";
    ctx.fillText(percentStr, cx, cy - 10);

    ctx.font = "14px sans-serif";
    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.fillText("Used overall", cx, cy + 15);
}

function drawBarChart() {
    const canvas = document.getElementById("topStorageChart");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const mailboxes = getMailboxes().filter(m => !m.error && m.current);
    mailboxes.sort((a, b) => (b.current.totalGB || 0) - (a.current.totalGB || 0));

    const top = mailboxes.slice(0, 10);
    if (top.length === 0) return;

    const maxVal = top[0].current.totalGB || 1;
    const chartHeight = canvas.height - 60;
    const chartWidth = canvas.width - 40;
    const barSpacing = chartWidth / top.length;
    const barWidth = barSpacing * 0.6;

    ctx.fillStyle = "#0078d4";
    ctx.textAlign = "center";
    ctx.textBaseline = "bottom";

    top.forEach((m, idx) => {
        const val = m.current.totalGB || 0;
        const barH = (val / maxVal) * chartHeight;
        const x = 20 + idx * barSpacing + (barSpacing - barWidth) / 2;
        const y = canvas.height - 30 - barH;

        ctx.fillRect(x, y, barWidth, barH);

        // Value text
        ctx.fillStyle = getCssVariable("--text-primary") || "#333";
        ctx.font = "12px sans-serif";
        ctx.fillText(val.toFixed(1), x + barWidth / 2, y - 5);

        // Label (truncate name)
        let label = (m.displayName || m.primarySmtpAddress).split("@")[0];
        if (label.length > 10) label = label.substring(0, 8) + "...";
        ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
        ctx.fillText(label, x + barWidth / 2, canvas.height - 10);
        ctx.fillStyle = "#0078d4";
    });
}

function populateHistorySelect() {
    const sel = document.getElementById("mailboxSelect");
    if (!sel || !dashboardData) return;

    sel.innerHTML = `<option value="">-- Select a mailbox --</option>`;
    
    const sorted = [...(dashboardData.mailboxes || [])].sort((a, b) => {
        const nameA = (a.displayName || a.primarySmtpAddress || "").toLowerCase();
        const nameB = (b.displayName || b.primarySmtpAddress || "").toLowerCase();
        return nameA.localeCompare(nameB);
    });

    for (const m of sorted) {
        if (m.error) continue;
        const opt = document.createElement("option");
        opt.value = m.exchangeGuid;
        opt.textContent = `${m.displayName || m.primarySmtpAddress} (${m.primarySmtpAddress})`;
        sel.appendChild(opt);
    }
}

function renderHistoryPage() {
    const sel = document.getElementById("mailboxSelect");
    if (!sel || !sel.value) return;

    const guid = sel.value;
    const histPoints = historyData?.[guid] || [];

    const tbody = document.querySelector("#historyTable tbody");
    if (tbody) {
        tbody.innerHTML = "";
        if (histPoints.length === 0) {
            tbody.innerHTML = `<tr><td colspan="4">No history data for this mailbox.</td></tr>`;
        } else {
            const sortedDesc = [...histPoints].sort((a, b) => new Date(b.Timestamp) - new Date(a.Timestamp));
            for (const pt of sortedDesc) {
                const tr = document.createElement("tr");
                tr.innerHTML = `
                    <td>${formatDate(pt.Timestamp)}</td>
                    <td>${formatGB(pt.TotalGB)}</td>
                    <td>${formatNumber(pt.ItemCount)}</td>
                    <td>${pt.UsagePercent != null ? pt.UsagePercent.toFixed(1) + "%" : ""}</td>
                `;
                tbody.appendChild(tr);
            }
        }
    }
    drawHistoryChart(histPoints);
}

function drawHistoryChart(histPoints) {
    const canvas = document.getElementById("historyChart");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (!histPoints || histPoints.length < 2) {
        ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
        ctx.font = "14px sans-serif";
        ctx.textAlign = "center";
        ctx.fillText("Not enough history to chart.", canvas.width / 2, canvas.height / 2);
        return;
    }

    const sorted = [...histPoints].sort((a, b) => new Date(a.Timestamp) - new Date(b.Timestamp));
    let minVal = Number.MAX_VALUE;
    let maxVal = Number.MIN_VALUE;

    for (const pt of sorted) {
        const v = pt.TotalGB || 0;
        if (v < minVal) minVal = v;
        if (v > maxVal) maxVal = v;
    }

    if (maxVal === minVal) {
        minVal = 0; 
        maxVal = maxVal * 2 || 10;
    }

    const padX = 40;
    const padY = 40;
    const chartW = canvas.width - padX * 2;
    const chartH = canvas.height - padY * 2;

    const getX = (index) => padX + (index / (sorted.length - 1)) * chartW;
    const getY = (val) => (canvas.height - padY) - ((val - minVal) / (maxVal - minVal)) * chartH;

    ctx.beginPath();
    ctx.strokeStyle = "#0078d4";
    ctx.lineWidth = 3;
    ctx.lineJoin = "round";

    sorted.forEach((pt, i) => {
        const x = getX(i);
        const y = getY(pt.TotalGB || 0);
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });
    ctx.stroke();

    ctx.fillStyle = "#0078d4";
    sorted.forEach((pt, i) => {
        const x = getX(i);
        const y = getY(pt.TotalGB || 0);
        ctx.beginPath();
        ctx.arc(x, y, 5, 0, 2 * Math.PI);
        ctx.fill();
    });

    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.font = "12px sans-serif";
    ctx.textAlign = "center";
    ctx.fillText(formatDate(sorted[0].Timestamp).split(",")[0], padX, canvas.height - 15);
    ctx.fillText(formatDate(sorted[sorted.length - 1].Timestamp).split(",")[0], canvas.width - padX, canvas.height - 15);

    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    ctx.fillText(maxVal.toFixed(1) + " GB", padX - 10, padY);
    ctx.fillText(minVal.toFixed(1) + " GB", padX - 10, canvas.height - padY);
}

function renderPermissionsTable() {
    const tbody = document.querySelector("#permsTable tbody");
    if (!tbody || !dashboardData) return;
    tbody.innerHTML = "";

    const mailboxes = dashboardData.mailboxes || [];
    let hasAny = false;

    for (const m of mailboxes) {
        if (m.error || !m.permissions || m.permissions.length === 0) continue;
        for (const p of m.permissions) {
            hasAny = true;
            const tr = document.createElement("tr");
            tr.innerHTML = `
                <td>${escapeHtml(m.displayName || m.primarySmtpAddress)}</td>
                <td>${escapeHtml(p.user)}</td>
                <td>${escapeHtml(p.accessRights.join(", "))}</td>
                <td>${p.isInherited ? "Yes" : "No"}</td>
            `;
            tbody.appendChild(tr);
        }
    }

    if (!hasAny) {
        tbody.innerHTML = `<tr><td colspan="4">No permissions found.</td></tr>`;
    }
}

function renderThresholdsTable() {
    const tbody = document.querySelector("#thresholdsTable tbody");
    if (!tbody || !dashboardData) return;
    tbody.innerHTML = "";

    const mailboxes = dashboardData.mailboxes || [];
    const thresholds = dashboardData.thresholds || { warningPercent: 80, criticalPercent: 95 };

    let count = 0;
    for (const m of mailboxes) {
        if (m.error || !m.current) continue;
        const pct = m.current.usagePercent || 0;
        
        let state = "";
        if (pct >= thresholds.criticalPercent) {
            state = "Critical";
        } else if (pct >= thresholds.warningPercent) {
            state = "Warning";
        }

        if (state) {
            count++;
            const tr = document.createElement("tr");
            tr.innerHTML = `
                <td>${escapeHtml(m.displayName || m.primarySmtpAddress)}</td>
                <td>${formatGB(m.current.totalGB)}</td>
                <td>${formatGB(m.current.quotaGB)}</td>
                <td>${usageBadge(pct)}</td>
                <td><span class="badge ${state === 'Critical' ? 'danger' : 'warning'}">${state}</span></td>
            `;
            tbody.appendChild(tr);
        }
    }

    if (count === 0) {
        tbody.innerHTML = `<tr><td colspan="5">No mailboxes currently over warning/critical thresholds.</td></tr>`;
    }
}

// --- Helpers ---

function escapeHtml(str) {
    if (!str) return "";
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}

function formatGB(val) {
    if (typeof val !== "number") return "0.00";
    return val.toFixed(2);
}

function formatNumber(val) {
    if (typeof val !== "number") return "0";
    return val.toLocaleString();
}

function formatDate(isoString) {
    if (!isoString) return "N/A";
    const d = new Date(isoString);
    return d.toLocaleString();
}

function usageBadge(percent) {
    if (typeof percent !== "number") return "0%";
    const pStr = percent.toFixed(1) + "%";
    const thresholds = dashboardData?.thresholds || { warningPercent: 80, criticalPercent: 95 };
    if (percent >= thresholds.criticalPercent) {
        return `<span class="badge danger">${pStr}</span>`;
    } else if (percent >= thresholds.warningPercent) {
        return `<span class="badge warning">${pStr}</span>`;
    }
    return pStr;
}

function getCssVariable(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}