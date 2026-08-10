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
        historyData = { mailboxHistory: [] };
    }

    renderCommon();
    renderCurrentPage();
}

function resetAutoRefreshTimer() {
    if (refreshTimer) {
        clearInterval(refreshTimer);
    }

    refreshTimer = setInterval(() => {
        loadDashboard().catch(showError);
    }, refreshMs);
}

function renderCommon() {
    const lastUpdated = document.getElementById("lastUpdated");

    if (lastUpdated && dashboardData) {
        lastUpdated.textContent = `Generated: ${formatDate(dashboardData.generatedUtc)} | Auto-refresh: ${refreshMs / 1000}s`;
    }

    highlightCurrentNav();
}

function renderCurrentPage() {
    const page = document.body.dataset.page || "overview";

    if (page === "thresholds") {
        renderThresholdPage();
        return;
    }

    if (page === "history") {
        renderHistorySelect();
        renderHistoryPage();
        return;
    }

    if (page === "permissions") {
        renderPermissionsPage();
        return;
    }

    renderOverviewPage();
}

function getMailboxes() {
    return dashboardData?.Mailboxes || [];
}

function updateGlobalStats() {
    document.getElementById("mailboxCount").textContent = dashboardData.MailboxCount || 0;

    let totalStorage = 0;
    let totalPerms = 0;

    getMailboxes().forEach(m => {
        totalStorage += (m.TotalGB || 0);
        // Ensure Permissions exists before counting
        if (m.Permissions && Array.isArray(m.Permissions)) {
            totalPerms += m.Permissions.length;
        }
    });

    document.getElementById("totalStorage").textContent = totalStorage.toFixed(2) + " GB";
    document.getElementById("totalPermissions").textContent = totalPerms;
    document.getElementById("thresholdCount").textContent = dashboardData.ThresholdCount || 0;
}

// 2. Update Table Rendering to use flattened PascalCase properties
function renderUsageTable() {
    const tbody = document.querySelector("#usageTable tbody");
    if (!tbody) return;

    tbody.innerHTML = "";

    for (const m of getMailboxes()) {
        const tr = document.createElement("tr");

        if (m.Error) {
            tr.innerHTML = `
        <td>${escapeHtml(m.PrimarySmtpAddress || m.DisplayName)}</td>
        <td colspan="7"><span class="badge danger">Error</span> ${escapeHtml(m.Error)}</td>
      `;
        } else {
            // Updated to strip 'current' nesting and use PascalCase
            tr.innerHTML = `
        <td>${escapeHtml(m.PrimarySmtpAddress)}</td>
        <td>${escapeHtml(m.RecipientTypeDetails || "")}</td>
        <td>${formatGB(m.TotalGB)}</td>
        <td>${formatNumber(m.ItemCount)}</td>
        <td>${formatGB(m.QuotaGB)}</td>
        <td>${m.UsagePercent}%</td>
        <td>${m.Permissions ? m.Permissions.length : 0}</td>
        <td>${escapeHtml(m.ThresholdState || "ok")}</td>
      `;
        }
        tbody.appendChild(tr);
    }

    function getHealthyMailboxes() {
        return getMailboxes().filter(m => !m.error && m.current);
    }

    function renderOverviewPage() {
        if (!document.getElementById("mailboxCount")) return;

        const mailboxes = getHealthyMailboxes();

        const totalGB = mailboxes.reduce((sum, m) => sum + Number(m.current?.totalGB || 0), 0);
        const totalPermissions = mailboxes.reduce((sum, m) => sum + (m.permissions?.length || 0), 0);
        const thresholdCount = dashboardData.thresholdCount || 0;

        const largest = [...mailboxes].sort((a, b) => {
            return Number(b.current?.totalGB || 0) - Number(a.current?.totalGB || 0);
        })[0];

        document.getElementById("mailboxCount").textContent = formatNumber(dashboardData.mailboxCount || mailboxes.length);
        document.getElementById("totalStorage").textContent = formatGB(totalGB);
        document.getElementById("totalPermissions").textContent = formatNumber(totalPermissions);
        document.getElementById("thresholdCount").textContent = formatNumber(thresholdCount);
        document.getElementById("largestMailbox").textContent =
            largest ? `${largest.primarySmtpAddress} (${formatGB(largest.current?.totalGB)})` : "N/A";

        renderUsageTable();
        drawUsageDonut("usageDonutChart", mailboxes);
        drawTopStorageBarChart("topStorageChart", mailboxes);
    }

    function renderThresholdPage() {
        const thresholdMailboxes = dashboardData.thresholdMailboxes || [];
        const tbody = document.querySelector("#thresholdTable tbody");

        if (tbody) {
            tbody.innerHTML = "";

            for (const m of thresholdMailboxes) {
                const tr = document.createElement("tr");

                tr.innerHTML = `
        <td>${escapeHtml(m.primarySmtpAddress)}</td>
        <td>${escapeHtml(m.recipientTypeDetails || "")}</td>
        <td>${formatGB(m.current?.totalGB)}</td>
        <td>${formatGB(m.current?.quotaGB)}</td>
        <td>${usageBadge(m.current?.usagePercent)}</td>
        <td>${formatNumber(m.current?.itemCount)}</td>
        <td>${formatNumber(m.permissions?.length || 0)}</td>
        <td><span class="badge danger">Critical</span></td>
      `;

                tbody.appendChild(tr);
            }

            if (thresholdMailboxes.length === 0) {
                const tr = document.createElement("tr");
                tr.innerHTML = `<td colspan="8"><span class="badge ok">No mailboxes are above the critical threshold.</span></td>`;
                tbody.appendChild(tr);
            }
        }

        drawThresholdChart("thresholdChart", thresholdMailboxes);
    }
    // Locate where you process history data and add this check:
    const mailboxHistoryData = historyData.MailboxHistory.find(h => h.PrimarySmtpAddress === selectedMailbox);

    if (mailboxHistoryData) {
        // Array Normalization: If Samples is a single object, wrap it in an array []
        const samplesArray = Array.isArray(mailboxHistoryData.Samples)
            ? mailboxHistoryData.Samples
            : [mailboxHistoryData.Samples];

        // Now safely run .map() on samplesArray
        const labels = samplesArray.map(s => new Date(s.TimestampUtc).toLocaleDateString());
        const dataPoints = samplesArray.map(s => s.TotalGB);

        // Continue building chart...
    }
    function renderHistorySelect() {
        const select = document.getElementById("mailboxSelect");
        if (!select) return;

        const selected = select.value;
        select.innerHTML = "";

        const historyEntries = historyData?.mailboxHistory || [];

        for (const entry of historyEntries) {
            const option = document.createElement("option");
            option.value = entry.primarySmtpAddress;
            option.textContent = entry.primarySmtpAddress;
            select.appendChild(option);
        }

        if ([...select.options].some(o => o.value === selected)) {
            select.value = selected;
        }
    }

    function renderHistoryPage() {
        const select = document.getElementById("mailboxSelect");
        if (!select) return;

        const entry = (historyData?.mailboxHistory || [])
            .find(h => h.primarySmtpAddress === select.value);

        drawLineChart(
            "historyStorageChart",
            entry?.samples || [],
            "totalGB",
            "Storage GB",
            "#2563eb",
            value => `${value.toFixed(2)} GB`
        );

        drawLineChart(
            "historyUtilisationChart",
            entry?.samples || [],
            "usagePercent",
            "Utilisation %",
            "#dc2626",
            value => `${value.toFixed(1)}%`
        );
    }

    // Locate where you process history data and add this check:
    const mailboxHistoryData = historyData.MailboxHistory.find(h => h.PrimarySmtpAddress === selectedMailbox);

    if (mailboxHistoryData) {
        // Array Normalization: If Samples is a single object, wrap it in an array []
        const samplesArray = Array.isArray(mailboxHistoryData.Samples)
            ? mailboxHistoryData.Samples
            : [mailboxHistoryData.Samples];

        // Now safely run .map() on samplesArray
        const labels = samplesArray.map(s => new Date(s.TimestampUtc).toLocaleDateString());
        const dataPoints = samplesArray.map(s => s.TotalGB);

        // Continue building chart...
    }// 1. Update Global Variable assignments to use PascalCase
    function getMailboxes() {
        return dashboardData?.Mailboxes || [];
    }

    function updateGlobalStats() {
        document.getElementById("mailboxCount").textContent = dashboardData.MailboxCount || 0;

        let totalStorage = 0;
        let totalPerms = 0;

        getMailboxes().forEach(m => {
            totalStorage += (m.TotalGB || 0);
            // Ensure Permissions exists before counting
            if (m.Permissions && Array.isArray(m.Permissions)) {
                totalPerms += m.Permissions.length;
            }
        });

        document.getElementById("totalStorage").textContent = totalStorage.toFixed(2) + " GB";
        document.getElementById("totalPermissions").textContent = totalPerms;
        document.getElementById("thresholdCount").textContent = dashboardData.ThresholdCount || 0;
    }

    // 2. Update Table Rendering to use flattened PascalCase properties
    function renderUsageTable() {
        const tbody = document.querySelector("#usageTable tbody");
        if (!tbody) return;

        tbody.innerHTML = "";

        for (const m of getMailboxes()) {
            const tr = document.createElement("tr");

            if (m.Error) {
                tr.innerHTML = `
        <td>${escapeHtml(m.PrimarySmtpAddress || m.DisplayName)}</td>
        <td colspan="7"><span class="badge danger">Error</span> ${escapeHtml(m.Error)}</td>
      `;
            } else {
                // Updated to strip 'current' nesting and use PascalCase
                tr.innerHTML = `
        <td>${escapeHtml(m.PrimarySmtpAddress)}</td>
        <td>${escapeHtml(m.RecipientTypeDetails || "")}</td>
        <td>${formatGB(m.TotalGB)}</td>
        <td>${formatNumber(m.ItemCount)}</td>
        <td>${formatGB(m.QuotaGB)}</td>
        <td>${m.UsagePercent}%</td>
        <td>${m.Permissions ? m.Permissions.length : 0}</td>
        <td>${escapeHtml(m.ThresholdState || "ok")}</td>
      `;
            }
            tbody.appendChild(tr);
        }
    }

    function renderPermissionsPage() {
        const container = document.getElementById("permissionsContainer");
        if (!container) return;

        container.innerHTML = "";

        for (const m of getHealthyMailboxes()) {
            const card = document.createElement("div");
            card.className = "permission-card";

            const permissionRows = (m.permissions || []).map(p => `
      <tr>
        <td>${escapeHtml(p.permissionType || "")}</td>
        <td>${escapeHtml(p.user || "")}</td>
        <td>${escapeHtml(p.accessRights || "")}</td>
      </tr>
    `).join("");

            card.innerHTML = `
      <h3>${escapeHtml(m.primarySmtpAddress)}</h3>
      ${permissionRows
                    ? `<table>
               <thead>
                 <tr>
                   <th>Type</th>
                   <th>User / principal</th>
                   <th>Rights</th>
                 </tr>
               </thead>
               <tbody>${permissionRows}</tbody>
             </table>`
                    : `<p><span class="badge ok">No explicit permissions found</span></p>`
                }
    `;

            container.appendChild(card);
        }
    }

    function drawUsageDonut(canvasId, mailboxes) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) return;

        const counts = {
            ok: mailboxes.filter(m => m.current.thresholdState === "ok").length,
            warning: mailboxes.filter(m => m.current.thresholdState === "warning").length,
            critical: mailboxes.filter(m => m.current.thresholdState === "critical").length
        };

        drawDonut(canvas, [
            { label: "OK", value: counts.ok, color: "#16a34a" },
            { label: "Warning", value: counts.warning, color: "#d97706" },
            { label: "Critical", value: counts.critical, color: "#dc2626" }
        ]);
    }

    function drawTopStorageBarChart(canvasId, mailboxes) {
        const top = [...mailboxes]
            .sort((a, b) => Number(b.current.totalGB || 0) - Number(a.current.totalGB || 0))
            .slice(0, 10)
            .map(m => ({
                label: m.primarySmtpAddress,
                value: Number(m.current.totalGB || 0),
                color: stateColor(m.current.thresholdState)
            }));

        drawBarChart(canvasId, top, "Top mailbox storage usage");
    }

    function drawThresholdChart(canvasId, mailboxes) {
        const data = [...mailboxes]
            .sort((a, b) => Number(b.current.usagePercent || 0) - Number(a.current.usagePercent || 0))
            .map(m => ({
                label: m.primarySmtpAddress,
                value: Number(m.current.usagePercent || 0),
                color: "#dc2626"
            }));

        drawBarChart(canvasId, data, "Critical mailboxes by utilisation %");
    }

    function drawDonut(canvas, segments) {
        const ctx = canvas.getContext("2d");
        clearCanvas(ctx, canvas);

        const total = segments.reduce((sum, s) => sum + s.value, 0);
        const cx = canvas.width / 2;
        const cy = canvas.height / 2;
        const radius = Math.min(cx, cy) - 30;

        if (total === 0) {
            ctx.fillText("No data available", 30, 40);
            return;
        }

        let start = -Math.PI / 2;

        for (const segment of segments) {
            const angle = (segment.value / total) * Math.PI * 2;

            ctx.beginPath();
            ctx.moveTo(cx, cy);
            ctx.arc(cx, cy, radius, start, start + angle);
            ctx.closePath();
            ctx.fillStyle = segment.color;
            ctx.fill();

            start += angle;
        }

        ctx.beginPath();
        ctx.fillStyle = "#ffffff";
        ctx.arc(cx, cy, radius * 0.55, 0, Math.PI * 2);
        ctx.fill();

        ctx.fillStyle = "#111827";
        ctx.font = "22px Segoe UI";
        ctx.textAlign = "center";
        ctx.fillText(`${total}`, cx, cy - 4);
        ctx.font = "13px Segoe UI";
        ctx.fillText("Mailboxes", cx, cy + 18);

        ctx.textAlign = "left";
        let y = 24;

        for (const segment of segments) {
            ctx.fillStyle = segment.color;
            ctx.fillRect(20, y - 10, 12, 12);
            ctx.fillStyle = "#111827";
            ctx.fillText(`${segment.label}: ${segment.value}`, 40, y);
            y += 22;
        }
    }

    function drawBarChart(canvasId, data, title) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) return;

        const ctx = canvas.getContext("2d");
        clearCanvas(ctx, canvas);

        if (!data.length) {
            ctx.fillStyle = "#111827";
            ctx.fillText("No data available", 30, 40);
            return;
        }

        const paddingLeft = 220;
        const paddingRight = 40;
        const paddingTop = 50;
        const rowHeight = 32;
        const barHeight = 20;
        const maxValue = Math.max(...data.map(d => d.value), 1);
        const chartWidth = canvas.width - paddingLeft - paddingRight;

        ctx.fillStyle = "#111827";
        ctx.font = "16px Segoe UI";
        ctx.fillText(title, 20, 26);

        data.forEach((d, index) => {
            const y = paddingTop + index * rowHeight;
            const barWidth = (d.value / maxValue) * chartWidth;

            ctx.fillStyle = "#374151";
            ctx.font = "12px Segoe UI";
            ctx.fillText(shorten(d.label, 28), 20, y + 15);

            ctx.fillStyle = d.color || "#2563eb";
            ctx.fillRect(paddingLeft, y, barWidth, barHeight);

            ctx.fillStyle = "#111827";
            ctx.fillText(d.value.toFixed(2), paddingLeft + barWidth + 8, y + 15);
        });
    }

    function drawLineChart(canvasId, samples, valueField, title, color, labelFormatter) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) return;

        const ctx = canvas.getContext("2d");
        clearCanvas(ctx, canvas);

        if (!samples.length) {
            ctx.fillStyle = "#111827";
            ctx.fillText("No historical data available yet.", 30, 40);
            return;
        }

        const points = samples.map(s => ({
            timestamp: s.timestampUtc,
            value: Number(s[valueField] || 0),
            state: s.thresholdState || "ok"
        }));

        const padding = 50;
        const width = canvas.width - padding * 2;
        const height = canvas.height - padding * 2;
        const maxY = Math.max(...points.map(p => p.value), 1);

        ctx.fillStyle = "#111827";
        ctx.font = "16px Segoe UI";
        ctx.fillText(title, 20, 26);

        ctx.strokeStyle = "#e5e7eb";
        ctx.lineWidth = 1;

        for (let i = 0; i <= 4; i++) {
            const y = padding + (height / 4) * i;

            ctx.beginPath();
            ctx.moveTo(padding, y);
            ctx.lineTo(canvas.width - padding, y);
            ctx.stroke();

            const label = labelFormatter(maxY - (maxY / 4) * i);
            ctx.fillStyle = "#6b7280";
            ctx.fillText(label, 8, y + 4);
        }

        ctx.strokeStyle = color;
        ctx.lineWidth = 3;
        ctx.beginPath();

        points.forEach((point, index) => {
            const x = padding + (points.length === 1 ? 0 : (width / (points.length - 1)) * index);
            const y = padding + height - (point.value / maxY) * height;

            if (index === 0) {
                ctx.moveTo(x, y);
            } else {
                ctx.lineTo(x, y);
            }
        });

        ctx.stroke();

        points.forEach((point, index) => {
            const x = padding + (points.length === 1 ? 0 : (width / (points.length - 1)) * index);
            const y = padding + height - (point.value / maxY) * height;

            ctx.beginPath();
            ctx.fillStyle = stateColor(point.state);
            ctx.arc(x, y, 4, 0, Math.PI * 2);
            ctx.fill();
        });

        const first = points[0];
        const last = points[points.length - 1];

        ctx.fillStyle = "#6b7280";
        ctx.font = "12px Segoe UI";
        ctx.fillText(`First: ${formatDate(first.timestamp)}`, padding, canvas.height - 16);
        ctx.fillText(`Latest: ${formatDate(last.timestamp)}`, canvas.width / 2, canvas.height - 16);
    }

    function usageBadge(percent) {
        if (percent === null || percent === undefined || isNaN(percent)) {
            return `<span class="badge">N/A</span>`;
        }

        const critical = dashboardData?.criticalThresholdPercent ?? 94;
        const warning = dashboardData?.warningThresholdPercent ?? 85;

        const cls = percent >= critical ? "danger" : percent >= warning ? "warning" : "ok";
        return `<span class="badge ${cls}">${Number(percent).toFixed(2)}%</span>`;
    }

    function stateColor(state) {
        if (state === "critical") return "#dc2626";
        if (state === "warning") return "#d97706";
        return "#16a34a";
    }

    function clearCanvas(ctx, canvas) {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = "#ffffff";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
    }

    function formatNumber(value) {
        if (value === null || value === undefined || isNaN(value)) return "N/A";
        return Number(value).toLocaleString();
    }

    function formatGB(value) {
        if (value === null || value === undefined || isNaN(value)) return "N/A";
        return `${Number(value).toLocaleString(undefined, { maximumFractionDigits: 2 })} GB`;
    }

    function formatDate(value) {
        if (!value) return "N/A";

        const date = new Date(value);
        if (isNaN(date.getTime())) return value;

        return date.toLocaleString();
    }

    function shorten(value, maxLength) {
        const text = String(value || "");
        if (text.length <= maxLength) return text;
        return `${text.slice(0, maxLength - 3)}...`;
    }

    function escapeHtml(value) {
        return String(value ?? "")
            .replaceAll("&", "&amp;")
            .replaceAll("<", "&lt;")
            .replaceAll(">", "&gt;")
            .replaceAll('"', "&quot;")
            .replaceAll("'", "&#039;");
    }

    function highlightCurrentNav() {
        const page = document.body.dataset.page || "overview";
        const links = document.querySelectorAll(".view-nav a");

        links.forEach(link => {
            const href = link.getAttribute("href") || "";

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

        for (const m of getMailboxes()) {
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
}
