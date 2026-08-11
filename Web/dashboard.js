const DATA_URL = "data.json";
const HISTORY_URL = "history.json";
const MAX_SEARCH_RESULTS = 24;
const MAX_TABLE_ROWS = 250;
const WARNING_THRESHOLD = 85;
const CRITICAL_THRESHOLD = 94;

let refreshTimer = null;
let refreshMs = 60000;

const state = {
    historyData: createEmptyHistoryData(),
    currentMailboxes: [],
    selectableMailboxes: [],
    mailboxLookup: new Map(),
    selectedMailboxKey: null
};

window.allMailboxes = [];

document.addEventListener("DOMContentLoaded", () => {
    bindHeaderControls();
    bindSearchControls();
    loadDashboard().catch(showError);
    resetAutoRefreshTimer();
});

function bindHeaderControls() {
    const refreshButton = document.getElementById("refreshButton");
    if (refreshButton) {
        refreshButton.addEventListener("click", () => loadDashboard().catch(showError));
    }

    const themeBtn = document.getElementById("themeToggle");
    if (themeBtn) {
        themeBtn.textContent = document.documentElement.getAttribute("data-theme") === "light"
            ? "Switch to Dark Mode"
            : "Switch to Light Mode";

        themeBtn.addEventListener("click", () => {
            const currentTheme = document.documentElement.getAttribute("data-theme");
            const newTheme = currentTheme === "light" ? "dark" : "light";
            document.documentElement.setAttribute("data-theme", newTheme);
            localStorage.setItem("dashboardTheme", newTheme);
            themeBtn.textContent = newTheme === "light" ? "Switch to Dark Mode" : "Switch to Light Mode";
            applyFilter();
        });
    }
}

function bindSearchControls() {
    const searchInput = document.getElementById("mailboxSearch");
    if (searchInput) {
        searchInput.addEventListener("input", handleSearchInput);
        searchInput.addEventListener("keydown", handleSearchKeyDown);
    }

    const clearBtn = document.getElementById("clearSearchBtn");
    if (clearBtn) {
        clearBtn.addEventListener("click", clearMailboxSelection);
    }

    const openBtn = document.getElementById("openMailboxBtn");
    if (openBtn) {
        openBtn.addEventListener("click", () => {
            const selected = getSelectedMailbox() || getRankedMailboxes(getSearchInputValue(), MAX_SEARCH_RESULTS)[0];
            if (!selected) return;
            navigateToMailboxPage(selected);
        });
    }

    const results = document.getElementById("searchResults");
    if (results) {
        results.addEventListener("click", event => {
            const resultButton = event.target.closest("[data-mailbox-key]");
            if (!resultButton) return;
            const mailbox = state.mailboxLookup.get(resultButton.getAttribute("data-mailbox-key"));
            if (!mailbox) return;
            selectMailbox(mailbox, { pushHistory: true });
        });
    }

    const selectedSummary = document.getElementById("selectedMailboxSummary");
    if (selectedSummary) {
        selectedSummary.addEventListener("click", event => {
            const action = event.target.closest("[data-action]");
            if (!action) return;

            const selected = getSelectedMailbox();
            if (!selected) return;

            const actionName = action.getAttribute("data-action");
            if (actionName === "open") {
                navigateToMailboxPage(selected);
            } else if (actionName === "clear") {
                clearMailboxSelection();
            }
        });
    }
}

async function loadDashboard() {
    const cacheBust = Date.now();
    const dataUrl = `${DATA_URL}?cacheBust=${cacheBust}`;
    const historyUrl = `${HISTORY_URL}?cacheBust=${cacheBust}`;

    const [dataResponse, historyResponse] = await Promise.all([
        fetch(dataUrl, { cache: "no-store" }),
        fetch(historyUrl, { cache: "no-store" })
    ]);

    if (!dataResponse.ok) {
        throw new Error(`Could not load ${DATA_URL}`);
    }

    const rawDashboardData = await dataResponse.json();
    const rawHistoryData = historyResponse.ok ? await historyResponse.json() : null;

    state.historyData = normaliseHistoryData(rawHistoryData);

    const currentFromData = extractMailboxArray(rawDashboardData)
        .map(normaliseMailbox)
        .filter(isMailboxRenderable);

    const currentFromHistory = state.historyData.mailboxes.filter(isMailboxRenderable);

    state.currentMailboxes = mergeMailboxCollections(currentFromData, currentFromHistory);
    state.selectableMailboxes = mergeMailboxCollections(state.currentMailboxes, currentFromHistory);
    state.mailboxLookup = new Map(state.selectableMailboxes.map(mailbox => [getMailboxKey(mailbox), mailbox]));
    window.allMailboxes = state.currentMailboxes;

    synchroniseSelection();
    updateSearchInput();
    updateNavLinks();
    updateLastUpdated(
        rawDashboardData?.GeneratedUtc ||
        rawDashboardData?.generatedUtc ||
        state.historyData.generatedUtc
    );
    highlightNav();
    applyFilter();
}

function handleSearchInput() {
    const selected = getSelectedMailbox();
    const input = getSearchInputValue().trim().toLowerCase();
    if (selected && input !== getMailboxSearchLabel(selected).toLowerCase()) {
        state.selectedMailboxKey = null;
        updateMailboxQueryParam(null, true);
    }
    applyFilter();
}

function handleSearchKeyDown(event) {
    if (event.key !== "Enter") return;
    const firstResult = getRankedMailboxes(getSearchInputValue(), 1)[0];
    if (!firstResult) return;
    event.preventDefault();
    selectMailbox(firstResult, { pushHistory: true });
}

function clearMailboxSelection() {
    state.selectedMailboxKey = null;
    const searchInput = document.getElementById("mailboxSearch");
    if (searchInput) searchInput.value = "";
    updateMailboxQueryParam(null, true);
    updateNavLinks();
    applyFilter();
}

function selectMailbox(mailbox, options = {}) {
    if (!mailbox) return;
    state.selectedMailboxKey = getMailboxKey(mailbox);
    updateSearchInput();
    updateMailboxQueryParam(mailbox, Boolean(options.pushHistory));
    updateNavLinks();
    applyFilter();
}

function synchroniseSelection() {
    const requested = getRequestedMailboxValue();
    const currentPage = getCurrentPage();

    if (requested) {
        const matched = findMailboxByRequestedValue(requested);
        if (matched) {
            state.selectedMailboxKey = getMailboxKey(matched);
            return;
        }
    }

    if ((currentPage === "history" || currentPage === "mailbox") && state.selectableMailboxes.length > 0) {
        state.selectedMailboxKey = getMailboxKey(state.selectableMailboxes[0]);
        updateMailboxQueryParam(state.selectableMailboxes[0], true);
    }
}

function updateSearchInput() {
    const input = document.getElementById("mailboxSearch");
    if (!input) return;
    const selected = getSelectedMailbox();
    if (selected) {
        input.value = getMailboxSearchLabel(selected);
    }
}

function getCurrentPage() {
    return document.body.getAttribute("data-page");
}

function getSearchInputValue() {
    const input = document.getElementById("mailboxSearch");
    return input ? input.value : "";
}

function getSelectedMailbox() {
    if (!state.selectedMailboxKey) return null;
    return state.mailboxLookup.get(state.selectedMailboxKey) || null;
}

function getMailboxes() {
    const selected = getSelectedMailbox();
    if (selected) return [selected];
    return filterMailboxes(state.currentMailboxes, getSearchInputValue());
}

function applyFilter() {
    renderSearchUi();

    switch (getCurrentPage()) {
        case "overview":
            renderOverviewPage();
            break;
        case "history":
            renderHistoryPage();
            break;
        case "permissions":
            renderPermissionsPage();
            break;
        case "thresholds":
            renderThresholdsPage();
            break;
        case "mailbox":
            renderMailboxPage();
            break;
        default:
            renderOverviewPage();
            break;
    }
}

function renderSearchUi() {
    const totalMailboxes = state.selectableMailboxes.length;
    const selected = getSelectedMailbox();
    const query = getSearchInputValue().trim();
    const results = selected ? [] : getRankedMailboxes(query, MAX_SEARCH_RESULTS);
    const totalMatches = selected ? 1 : (query ? filterMailboxes(state.selectableMailboxes, query).length : totalMailboxes);

    const status = document.getElementById("searchStatus");
    if (status) {
        if (selected) {
            status.textContent = `Viewing a single mailbox: ${selected.displayName} (${selected.primarySmtpAddress || selected.exchangeGuid}).`;
        } else if (query) {
            status.textContent = `${formatNumber(totalMatches)} mailbox${totalMatches === 1 ? "" : "es"} match "${query}". Select one to drill in.`;
        } else {
            status.textContent = `${formatNumber(totalMailboxes)} mailboxes loaded. Use search to jump directly to one mailbox.`;
        }
    }

    renderSelectedMailboxSummary(selected);
    renderSearchResults(results, totalMatches, query);
}

function renderSelectedMailboxSummary(selected) {
    const container = document.getElementById("selectedMailboxSummary");
    if (!container) return;

    if (!selected) {
        container.hidden = true;
        container.innerHTML = "";
        return;
    }

    container.hidden = false;
    container.innerHTML = `
        <div class="selected-mailbox-summary-top">
            <div>
                <div class="selected-mailbox-summary-title">${escapeHtml(selected.displayName)}</div>
                <div class="selected-mailbox-summary-address">${escapeHtml(selected.primarySmtpAddress || selected.exchangeGuid)}</div>
            </div>
            <div class="header-actions">
                <button class="btn-link" data-action="open" type="button">Open full mailbox view</button>
                <button class="btn-link" data-action="clear" type="button">Clear selection</button>
            </div>
        </div>
        <div class="summary-metrics">
            <div class="summary-metric"><span class="label">Primary</span><strong>${formatGB(selected.current.totalGB)} GB</strong></div>
            <div class="summary-metric"><span class="label">Archive</span><strong>${formatGB(selected.current.archiveSizeGB)} GB</strong></div>
            <div class="summary-metric"><span class="label">Usage</span><strong>${formatPercent(selected.current.usagePercent)}</strong></div>
            <div class="summary-metric"><span class="label">Permissions</span><strong>${formatNumber(selected.permissions.length)}</strong></div>
        </div>
    `;
}

function renderSearchResults(results, totalMatches, query) {
    const panel = document.getElementById("searchResultsPanel");
    const list = document.getElementById("searchResults");
    const title = document.getElementById("searchResultsTitle");
    const meta = document.getElementById("searchResultsMeta");

    if (!panel || !list || !title || !meta) return;

    if (!query || results.length === 0 || getSelectedMailbox()) {
        panel.hidden = true;
        list.innerHTML = "";
        return;
    }

    panel.hidden = false;
    title.textContent = "Top matches";
    meta.textContent = `Showing ${results.length} of ${formatNumber(totalMatches)}`;
    list.innerHTML = results.map(mailbox => `
        <button class="search-result" type="button" data-mailbox-key="${escapeHtml(getMailboxKey(mailbox))}">
            <div>
                <div class="search-result-title">${escapeHtml(mailbox.displayName)}</div>
                <div class="search-result-subtitle">${escapeHtml(mailbox.primarySmtpAddress || mailbox.exchangeGuid)}</div>
            </div>
            <div class="search-result-meta">
                ${formatGB(mailbox.current.totalGB)} GB<br>
                ${formatPercent(mailbox.current.usagePercent)}
            </div>
        </button>
    `).join("");
}

function renderOverviewPage() {
    const mailboxes = getMailboxes();
    updateTopCards(mailboxes);
    renderSelectedMailboxPanel(getSelectedMailbox());
    drawUsageDonutChart(mailboxes);
    drawTopStorageChart(mailboxes);
    drawUsageHistogram(mailboxes);
    drawAlertStatusChart(mailboxes);
    renderUsageTable(mailboxes);

    const tableTitle = document.getElementById("tableTitle");
    if (tableTitle) {
        tableTitle.textContent = getSelectedMailbox() ? "Selected mailbox usage" : "Current usage";
    }
}

function renderHistoryPage() {
    const selected = getSelectedMailbox();
    renderSelectedMailboxPanel(selected);

    const tableTitle = document.getElementById("tableTitle");
    if (tableTitle) {
        tableTitle.textContent = selected ? `History for ${selected.displayName}` : "Historical storage and utilisation";
    }

    const histPoints = selected ? getHistoryPointsForMailbox(selected) : [];
    renderHistoryTable(histPoints);
    drawHistoryMetricChart(histPoints, "historyStorageChart", point => point.SizeGB, "GB", getChartColor("primary"));
    drawHistoryMetricChart(histPoints, "historyUsageChart", point => point.UsagePercent, "%", getChartColor("warning"));
}

function renderPermissionsPage() {
    renderSelectedMailboxPanel(getSelectedMailbox());
    renderPermissionsTable();
}

function renderThresholdsPage() {
    renderSelectedMailboxPanel(getSelectedMailbox());
    renderThresholdsTable();
}

function renderMailboxPage() {
    const selected = getSelectedMailbox();
    renderSelectedMailboxPanel(selected);
    renderMailboxMetricCards(selected);
    renderMailboxSnapshotsTable(selected);
    renderMailboxPermissionsTable(selected);
    drawMailboxStorageChart(selected);
    drawHistoryMetricChart(
        selected ? getHistoryPointsForMailbox(selected) : [],
        "mailboxHistoryChart",
        point => point.SizeGB,
        "GB",
        getChartColor("primary")
    );
}

function renderSelectedMailboxPanel(selected) {
    const panel = document.getElementById("selectedMailboxPanel");
    if (!panel) return;

    if (!selected) {
        panel.hidden = true;
        panel.innerHTML = "";
        return;
    }

    const history = getHistoryPointsForMailbox(selected);
    const latestSample = history.length > 0 ? history[history.length - 1] : null;
    const previousSample = history.length > 1 ? history[history.length - 2] : null;
    const deltaGB = latestSample && previousSample ? latestSample.SizeGB - previousSample.SizeGB : null;

    panel.hidden = false;
    panel.innerHTML = `
        <div class="selected-mailbox-layout">
            <div>
                <h2>${escapeHtml(selected.displayName)}</h2>
                <p class="selected-mailbox-meta">${escapeHtml(selected.primarySmtpAddress || selected.exchangeGuid)}</p>
                <div class="spotlight-metrics">
                    <div class="spotlight-metric"><span class="label">Primary storage</span><strong>${formatGB(selected.current.totalGB)} GB</strong></div>
                    <div class="spotlight-metric"><span class="label">Archive storage</span><strong>${formatGB(selected.current.archiveSizeGB)} GB</strong></div>
                    <div class="spotlight-metric"><span class="label">Quota</span><strong>${selected.current.quotaGB == null ? "Unlimited" : `${formatGB(selected.current.quotaGB)} GB`}</strong></div>
                    <div class="spotlight-metric"><span class="label">Usage</span><strong>${formatPercent(selected.current.usagePercent)}</strong></div>
                    <div class="spotlight-metric"><span class="label">Items</span><strong>${formatNumber(selected.current.itemCount)}</strong></div>
                    <div class="spotlight-metric"><span class="label">Permissions</span><strong>${formatNumber(selected.permissions.length)}</strong></div>
                    <div class="spotlight-metric"><span class="label">Last logon</span><strong>${formatDate(selected.current.lastLogonTime)}</strong></div>
                    <div class="spotlight-metric"><span class="label">Change since last sample</span><strong>${deltaGB == null ? "N/A" : `${deltaGB >= 0 ? "+" : ""}${formatGB(deltaGB)} GB`}</strong></div>
                </div>
            </div>
            <canvas id="selectedMailboxSpotlightChart" width="320" height="320"></canvas>
        </div>
    `;

    drawMailboxStorageRing("selectedMailboxSpotlightChart", selected);
}

function renderMailboxMetricCards(selected) {
    const container = document.getElementById("mailboxMetricCards");
    if (!container) return;

    if (!selected) {
        container.innerHTML = "";
        return;
    }

    const history = getHistoryPointsForMailbox(selected);
    const first = history.length > 0 ? history[0] : null;
    const latest = history.length > 0 ? history[history.length - 1] : null;
    const growth = first && latest ? latest.SizeGB - first.SizeGB : null;

    container.innerHTML = `
        <article><span class="label">Current usage</span><strong>${formatPercent(selected.current.usagePercent)}</strong></article>
        <article><span class="label">Primary items</span><strong>${formatNumber(selected.current.itemCount)}</strong></article>
        <article><span class="label">Archive items</span><strong>${formatNumber(selected.current.archiveItemCount)}</strong></article>
        <article><span class="label">Historical samples</span><strong>${formatNumber(history.length)}</strong></article>
        <article><span class="label">Growth in window</span><strong>${growth == null ? "N/A" : `${growth >= 0 ? "+" : ""}${formatGB(growth)} GB`}</strong></article>
    `;
}

function renderUsageTable(mailboxes) {
    const tbody = document.querySelector("#usageTable tbody");
    const tableMeta = document.getElementById("tableMeta");
    if (!tbody) return;

    const sorted = [...mailboxes].sort((a, b) => (b.current.totalGB || 0) - (a.current.totalGB || 0));
    const rows = sorted.slice(0, MAX_TABLE_ROWS);

    if (tableMeta) {
        tableMeta.textContent = rows.length < sorted.length
            ? `Showing ${formatNumber(rows.length)} of ${formatNumber(sorted.length)} matching mailboxes.`
            : `${formatNumber(sorted.length)} mailbox${sorted.length === 1 ? "" : "es"} shown.`;
    }

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="8" class="empty-state">No mailboxes found matching that search.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(mailbox => `
        <tr>
            <td><a class="table-link" href="${escapeHtml(buildMailboxUrl("mailbox.html", mailbox))}">${escapeHtml(mailbox.displayName)}</a></td>
            <td>${escapeHtml(mailbox.primarySmtpAddress)}</td>
            <td>${formatGB(mailbox.current.totalGB)}</td>
            <td>${formatNumber(mailbox.current.itemCount)}</td>
            <td>${mailbox.current.quotaGB == null ? "Unlimited" : formatGB(mailbox.current.quotaGB)}</td>
            <td>${usageBadge(mailbox.current.usagePercent)}</td>
            <td>${formatNumber(mailbox.permissions.length)}</td>
            <td>${formatDate(mailbox.current.lastLogonTime)}</td>
        </tr>
    `).join("");
}

function renderPermissionsTable() {
    const tbody = document.querySelector("#permsTable tbody");
    const tableMeta = document.getElementById("tableMeta");
    if (!tbody) return;

    const selected = getSelectedMailbox();
    const query = getSearchInputValue().trim().toLowerCase();
    const mailboxes = selected ? [selected] : state.currentMailboxes;
    const rows = [];

    mailboxes.forEach(mailbox => {
        mailbox.permissions.forEach(permission => {
            const mailboxName = `${mailbox.displayName} ${mailbox.primarySmtpAddress}`.toLowerCase();
            const delegateName = String(permission.User || permission.user || permission.Delegate || "").toLowerCase();
            if (query && !selected && !mailboxName.includes(query) && !delegateName.includes(query)) {
                return;
            }

            rows.push({ mailbox, permission });
        });
    });

    if (tableMeta) {
        tableMeta.textContent = selected
            ? `${formatNumber(rows.length)} explicit permission row${rows.length === 1 ? "" : "s"} for the selected mailbox.`
            : `${formatNumber(rows.length)} explicit permission row${rows.length === 1 ? "" : "s"} in view.`;
    }

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="4" class="empty-state">No explicit permissions found for the current view.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.slice(0, MAX_TABLE_ROWS).map(({ mailbox, permission }) => `
        <tr>
            <td><a class="table-link" href="${escapeHtml(buildMailboxUrl("mailbox.html", mailbox))}">${escapeHtml(mailbox.displayName)}</a></td>
            <td>${escapeHtml(permission.User || permission.user || permission.Delegate || "")}</td>
            <td>${escapeHtml(Array.isArray(permission.AccessRights || permission.accessRights) ? (permission.AccessRights || permission.accessRights).join(", ") : String(permission.AccessRights || permission.accessRights || permission.Rights || ""))}</td>
            <td>${(permission.IsInherited || permission.isInherited) ? "Yes" : "No"}</td>
        </tr>
    `).join("");
}

function renderThresholdsTable() {
    const tbody = document.querySelector("#thresholdTable tbody");
    const tableMeta = document.getElementById("tableMeta");
    if (!tbody) return;

    const rows = getMailboxes()
        .filter(mailbox => (mailbox.current.usagePercent || 0) >= WARNING_THRESHOLD)
        .sort((a, b) => (b.current.usagePercent || 0) - (a.current.usagePercent || 0));

    if (tableMeta) {
        tableMeta.textContent = rows.length === 0
            ? "No warning or critical mailboxes in the current view."
            : `${formatNumber(rows.length)} mailbox${rows.length === 1 ? "" : "es"} at or above ${WARNING_THRESHOLD}% usage.`;
    }

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="empty-state">No mailboxes currently over warning/critical thresholds.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(mailbox => {
        const status = (mailbox.current.usagePercent || 0) >= CRITICAL_THRESHOLD ? "Critical" : "Warning";
        return `
            <tr>
                <td><a class="table-link" href="${escapeHtml(buildMailboxUrl("mailbox.html", mailbox))}">${escapeHtml(mailbox.displayName)}</a></td>
                <td>${formatGB(mailbox.current.totalGB)}</td>
                <td>${mailbox.current.quotaGB == null ? "Unlimited" : formatGB(mailbox.current.quotaGB)}</td>
                <td>${usageBadge(mailbox.current.usagePercent)}</td>
                <td><span class="badge ${status === "Critical" ? "danger" : "warning"}">${status}</span></td>
            </tr>
        `;
    }).join("");
}

function renderHistoryTable(histPoints) {
    const tbody = document.querySelector("#historyTable tbody");
    const tableMeta = document.getElementById("tableMeta");
    if (!tbody) return;

    const sorted = [...histPoints].sort((a, b) => new Date(b.TimestampUtc) - new Date(a.TimestampUtc));

    if (tableMeta) {
        tableMeta.textContent = `${formatNumber(sorted.length)} historical snapshot${sorted.length === 1 ? "" : "s"} loaded.`;
    }

    if (sorted.length === 0) {
        tbody.innerHTML = `<tr><td colspan="4" class="empty-state">No history data available for this mailbox.</td></tr>`;
        return;
    }

    tbody.innerHTML = sorted.map(point => `
        <tr>
            <td>${formatDate(point.TimestampUtc)}</td>
            <td>${formatGB(point.SizeGB)}</td>
            <td>${formatNumber(point.ItemCount)}</td>
            <td>${formatPercent(point.UsagePercent)}</td>
        </tr>
    `).join("");
}

function renderMailboxSnapshotsTable(selected) {
    const tbody = document.querySelector("#mailboxSnapshotsTable tbody");
    const meta = document.getElementById("mailboxSnapshotsMeta");
    if (!tbody || !meta) return;

    const history = selected ? getHistoryPointsForMailbox(selected).slice().sort((a, b) => new Date(b.TimestampUtc) - new Date(a.TimestampUtc)) : [];
    meta.textContent = `${formatNumber(history.length)} snapshot${history.length === 1 ? "" : "s"} available.`;

    if (!selected || history.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="empty-state">Select a mailbox to inspect recent snapshots.</td></tr>`;
        return;
    }

    tbody.innerHTML = history.slice(0, 25).map(point => `
        <tr>
            <td>${formatDate(point.TimestampUtc)}</td>
            <td>${formatGB(point.SizeGB)}</td>
            <td>${formatGB(point.ArchiveSizeGB)}</td>
            <td>${formatNumber(point.ItemCount)}</td>
            <td>${formatPercent(point.UsagePercent)}</td>
        </tr>
    `).join("");
}

function renderMailboxPermissionsTable(selected) {
    const tbody = document.querySelector("#mailboxPermissionsTable tbody");
    const meta = document.getElementById("mailboxPermissionsMeta");
    if (!tbody || !meta) return;

    const permissions = selected ? selected.permissions : [];
    meta.textContent = `${formatNumber(permissions.length)} explicit permission row${permissions.length === 1 ? "" : "s"}.`;

    if (!selected || permissions.length === 0) {
        tbody.innerHTML = `<tr><td colspan="3" class="empty-state">No explicit permissions are available for this mailbox.</td></tr>`;
        return;
    }

    tbody.innerHTML = permissions.map(permission => `
        <tr>
            <td>${escapeHtml(permission.User || permission.user || permission.Delegate || "")}</td>
            <td>${escapeHtml(Array.isArray(permission.AccessRights || permission.accessRights) ? (permission.AccessRights || permission.accessRights).join(", ") : String(permission.AccessRights || permission.accessRights || permission.Rights || ""))}</td>
            <td>${(permission.IsInherited || permission.isInherited) ? "Yes" : "No"}</td>
        </tr>
    `).join("");
}

function updateTopCards(mailboxes) {
    const countEl = document.getElementById("mailboxCount");
    const totalStorageEl = document.getElementById("totalStorage");
    const totalArchiveEl = document.getElementById("totalArchiveStorage");
    const thresholdEl = document.getElementById("thresholdCount");
    const largestEl = document.getElementById("largestMailbox");

    const largest = mailboxes.reduce((winner, mailbox) => {
        if (!winner) return mailbox;
        return (winner.current.totalGB || 0) >= (mailbox.current.totalGB || 0) ? winner : mailbox;
    }, null);

    if (countEl) countEl.textContent = formatNumber(mailboxes.length);
    if (totalStorageEl) totalStorageEl.textContent = `${formatGB(sumMailboxes(mailboxes, mailbox => mailbox.current.totalGB))} GB`;
    if (totalArchiveEl) totalArchiveEl.textContent = `${formatGB(sumMailboxes(mailboxes, mailbox => mailbox.current.archiveSizeGB))} GB`;
    if (thresholdEl) thresholdEl.textContent = formatNumber(mailboxes.filter(mailbox => (mailbox.current.usagePercent || 0) >= WARNING_THRESHOLD).length);
    if (largestEl) largestEl.textContent = largest ? `${largest.displayName} (${formatGB(largest.current.totalGB)} GB)` : "N/A";
}

function drawUsageDonutChart(mailboxes) {
    const totalUsed = sumMailboxes(mailboxes, mailbox => mailbox.current.totalGB);
    let totalQuota = sumMailboxes(mailboxes, mailbox => mailbox.current.quotaGB || 0);
    if (totalQuota <= 0) totalQuota = 1;
    drawRingChart("usageDonutChart", [
        { label: "Used", value: totalUsed, color: getChartColor("primary") },
        { label: "Available", value: Math.max(totalQuota - totalUsed, 0), color: getChartColor("muted") }
    ], [`${((totalUsed / totalQuota) * 100).toFixed(1)}%`, "used quota"]);
}

function drawAlertStatusChart(mailboxes) {
    const healthy = mailboxes.filter(mailbox => (mailbox.current.usagePercent || 0) < WARNING_THRESHOLD).length;
    const warning = mailboxes.filter(mailbox => (mailbox.current.usagePercent || 0) >= WARNING_THRESHOLD && (mailbox.current.usagePercent || 0) < CRITICAL_THRESHOLD).length;
    const critical = mailboxes.filter(mailbox => (mailbox.current.usagePercent || 0) >= CRITICAL_THRESHOLD).length;

    drawRingChart("alertStatusChart", [
        { label: "Healthy", value: healthy, color: getChartColor("success") },
        { label: "Warning", value: warning, color: getChartColor("warning") },
        { label: "Critical", value: critical, color: getChartColor("danger") }
    ], [`${formatNumber(mailboxes.length)}`, "mailboxes"]);
}

function drawMailboxStorageChart(selected) {
    drawMailboxStorageRing("mailboxStorageChart", selected);
}

function drawMailboxStorageRing(canvasId, selected) {
    if (!selected) {
        drawEmptyCanvasMessage(canvasId, "Select a mailbox to view its storage breakdown.");
        return;
    }

    const primary = selected.current.totalGB || 0;
    const archive = selected.current.archiveSizeGB || 0;
    const freeQuota = selected.current.quotaGB == null ? 0 : Math.max(selected.current.quotaGB - primary, 0);

    drawRingChart(canvasId, [
        { label: "Primary", value: primary, color: getChartColor("primary") },
        { label: "Archive", value: archive, color: getChartColor("secondary") },
        { label: "Free quota", value: freeQuota, color: getChartColor("muted") }
    ], [`${formatGB(primary + archive)} GB`, "primary + archive"]);
}

function drawTopStorageChart(mailboxes) {
    const top = [...mailboxes]
        .sort((a, b) => (b.current.totalGB || 0) - (a.current.totalGB || 0))
        .slice(0, 10);

    drawHorizontalBarChart(
        "topStorageChart",
        top.map(mailbox => ({
            label: truncateLabel(mailbox.displayName || mailbox.primarySmtpAddress, 26),
            value: mailbox.current.totalGB || 0
        })),
        "GB"
    );
}

function drawUsageHistogram(mailboxes) {
    const buckets = [
        { label: "0-25%", min: 0, max: 25, count: 0 },
        { label: "25-50%", min: 25, max: 50, count: 0 },
        { label: "50-75%", min: 50, max: 75, count: 0 },
        { label: "75-90%", min: 75, max: 90, count: 0 },
        { label: "90-100%", min: 90, max: 100.01, count: 0 }
    ];

    mailboxes.forEach(mailbox => {
        const usage = mailbox.current.usagePercent || 0;
        const bucket = buckets.find(item => usage >= item.min && usage < item.max);
        if (bucket) bucket.count += 1;
    });

    drawVerticalBarChart(
        "usageHistogramChart",
        buckets.map(bucket => ({ label: bucket.label, value: bucket.count })),
        "mailboxes"
    );
}

function drawHistoryMetricChart(histPoints, canvasId, valueSelector, unitLabel, color) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (!histPoints || histPoints.length < 2) {
        drawEmptyCanvasMessage(canvasId, "Not enough history points to chart yet.");
        return;
    }

    const sorted = [...histPoints].sort((a, b) => new Date(a.TimestampUtc) - new Date(b.TimestampUtc));
    const values = sorted.map(point => Number(valueSelector(point) || 0));
    const maxVal = Math.max(...values, 1);
    const minVal = Math.min(...values, 0);
    const padLeft = 56;
    const padRight = 28;
    const padTop = 24;
    const padBottom = 42;
    const chartW = canvas.width - padLeft - padRight;
    const chartH = canvas.height - padTop - padBottom;

    const getX = index => padLeft + (index / (sorted.length - 1)) * chartW;
    const getY = value => {
        const range = Math.max(maxVal - minVal, 1);
        return canvas.height - padBottom - ((value - minVal) / range) * chartH;
    };

    ctx.strokeStyle = getChartColor("muted");
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(padLeft, padTop);
    ctx.lineTo(padLeft, canvas.height - padBottom);
    ctx.lineTo(canvas.width - padRight, canvas.height - padBottom);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    ctx.beginPath();
    sorted.forEach((point, index) => {
        const x = getX(index);
        const y = getY(Number(valueSelector(point) || 0));
        if (index === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });
    ctx.stroke();

    ctx.fillStyle = color;
    sorted.forEach((point, index) => {
        const x = getX(index);
        const y = getY(Number(valueSelector(point) || 0));
        ctx.beginPath();
        ctx.arc(x, y, 4, 0, Math.PI * 2);
        ctx.fill();
    });

    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.font = "12px sans-serif";
    ctx.textAlign = "right";
    ctx.fillText(`${maxVal.toFixed(1)} ${unitLabel}`, padLeft - 8, padTop + 4);
    ctx.fillText(`${minVal.toFixed(1)} ${unitLabel}`, padLeft - 8, canvas.height - padBottom);
    ctx.textAlign = "center";
    ctx.fillText(formatShortDate(sorted[0].TimestampUtc), padLeft, canvas.height - 12);
    ctx.fillText(formatShortDate(sorted[sorted.length - 1].TimestampUtc), canvas.width - padRight, canvas.height - 12);
}

function drawRingChart(canvasId, segments, centerLines) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;

    const validSegments = segments.filter(segment => segment.value > 0);
    if (validSegments.length === 0) {
        drawEmptyCanvasMessage(canvasId, "No data available for this chart.");
        return;
    }

    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const total = validSegments.reduce((sum, segment) => sum + segment.value, 0);
    const cx = canvas.width * 0.36;
    const cy = canvas.height / 2;
    const radius = Math.min(canvas.width, canvas.height) * 0.24;
    const lineWidth = Math.max(22, radius * 0.34);
    let startAngle = -Math.PI / 2;

    validSegments.forEach(segment => {
        const angle = (segment.value / total) * Math.PI * 2;
        ctx.beginPath();
        ctx.arc(cx, cy, radius, startAngle, startAngle + angle);
        ctx.strokeStyle = segment.color;
        ctx.lineWidth = lineWidth;
        ctx.stroke();
        startAngle += angle;
    });

    ctx.fillStyle = getCssVariable("--text-primary") || "#222";
    ctx.textAlign = "center";
    ctx.font = "bold 22px sans-serif";
    ctx.fillText(centerLines[0] || "", cx, cy - 4);
    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.font = "13px sans-serif";
    ctx.fillText(centerLines[1] || "", cx, cy + 18);

    const legendX = canvas.width * 0.66;
    let legendY = cy - ((validSegments.length - 1) * 22) / 2;
    validSegments.forEach(segment => {
        ctx.fillStyle = segment.color;
        ctx.fillRect(legendX, legendY - 10, 12, 12);
        ctx.fillStyle = getCssVariable("--text-primary") || "#222";
        ctx.textAlign = "left";
        ctx.font = "13px sans-serif";
        ctx.fillText(`${segment.label}: ${formatCompactNumber(segment.value)}`, legendX + 18, legendY);
        legendY += 24;
    });
}

function drawHorizontalBarChart(canvasId, items, unitLabel) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    if (!items || items.length === 0) {
        drawEmptyCanvasMessage(canvasId, "No mailboxes available for this ranking.");
        return;
    }

    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const leftPad = 190;
    const rightPad = 44;
    const topPad = 26;
    const barHeight = 24;
    const gap = 12;
    const maxValue = Math.max(...items.map(item => item.value), 1);

    items.forEach((item, index) => {
        const y = topPad + index * (barHeight + gap);
        const width = ((canvas.width - leftPad - rightPad) * item.value) / maxValue;

        ctx.fillStyle = getChartColor("muted");
        ctx.fillRect(leftPad, y, canvas.width - leftPad - rightPad, barHeight);
        ctx.fillStyle = getChartColor(index < 3 ? "secondary" : "primary");
        ctx.fillRect(leftPad, y, width, barHeight);

        ctx.fillStyle = getCssVariable("--text-primary") || "#222";
        ctx.textAlign = "right";
        ctx.font = "13px sans-serif";
        ctx.fillText(item.label, leftPad - 10, y + 17);
        ctx.textAlign = "left";
        ctx.fillText(`${item.value.toFixed(2)} ${unitLabel}`, leftPad + width + 8, y + 17);
    });
}

function drawVerticalBarChart(canvasId, items, unitLabel) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    if (!items || items.length === 0) {
        drawEmptyCanvasMessage(canvasId, "No data available for this histogram.");
        return;
    }

    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const maxValue = Math.max(...items.map(item => item.value), 1);
    const leftPad = 40;
    const bottomPad = 48;
    const topPad = 24;
    const chartHeight = canvas.height - topPad - bottomPad;
    const barSpace = (canvas.width - leftPad - 20) / items.length;
    const barWidth = barSpace * 0.62;

    items.forEach((item, index) => {
        const barHeight = (item.value / maxValue) * chartHeight;
        const x = leftPad + index * barSpace + (barSpace - barWidth) / 2;
        const y = canvas.height - bottomPad - barHeight;

        ctx.fillStyle = getChartColor(index >= items.length - 1 ? "danger" : index >= items.length - 2 ? "warning" : "primary");
        ctx.fillRect(x, y, barWidth, barHeight);

        ctx.fillStyle = getCssVariable("--text-primary") || "#222";
        ctx.textAlign = "center";
        ctx.font = "13px sans-serif";
        ctx.fillText(String(item.value), x + barWidth / 2, y - 6);
        ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
        ctx.fillText(item.label, x + barWidth / 2, canvas.height - 18);
    });

    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.textAlign = "right";
    ctx.fillText(`${maxValue} ${unitLabel}`, leftPad - 6, topPad + 4);
}

function drawEmptyCanvasMessage(canvasId, message) {
    const canvas = document.getElementById(canvasId);
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = getCssVariable("--text-secondary") || "#666";
    ctx.font = "14px sans-serif";
    ctx.textAlign = "center";
    ctx.fillText(message, canvas.width / 2, canvas.height / 2);
}

function sumMailboxes(mailboxes, selector) {
    return mailboxes.reduce((sum, mailbox) => sum + Number(selector(mailbox) || 0), 0);
}

function mergeMailboxCollections(primary, secondary) {
    const merged = new Map();

    secondary.forEach(mailbox => {
        if (isMailboxRenderable(mailbox)) {
            merged.set(getMailboxKey(mailbox), mailbox);
        }
    });

    primary.forEach(mailbox => {
        if (!isMailboxRenderable(mailbox)) return;
        const key = getMailboxKey(mailbox);
        const existing = merged.get(key);
        merged.set(key, existing ? mergeMailbox(existing, mailbox) : mailbox);
    });

    return [...merged.values()].sort((a, b) => {
        const left = (a.displayName || a.primarySmtpAddress || "").toLowerCase();
        const right = (b.displayName || b.primarySmtpAddress || "").toLowerCase();
        return left.localeCompare(right);
    });
}

function mergeMailbox(existing, incoming) {
    return {
        ...existing,
        ...incoming,
        displayName: incoming.displayName || existing.displayName,
        primarySmtpAddress: incoming.primarySmtpAddress || existing.primarySmtpAddress,
        current: {
            totalGB: pickValue(incoming.current.totalGB, existing.current.totalGB),
            itemCount: pickValue(incoming.current.itemCount, existing.current.itemCount),
            quotaGB: pickValue(incoming.current.quotaGB, existing.current.quotaGB),
            usagePercent: pickValue(incoming.current.usagePercent, existing.current.usagePercent),
            lastLogonTime: incoming.current.lastLogonTime || existing.current.lastLogonTime,
            archiveEnabled: incoming.current.archiveEnabled || existing.current.archiveEnabled,
            archiveSizeGB: pickValue(incoming.current.archiveSizeGB, existing.current.archiveSizeGB),
            archiveItemCount: pickValue(incoming.current.archiveItemCount, existing.current.archiveItemCount)
        },
        permissions: incoming.permissions.length >= existing.permissions.length ? incoming.permissions : existing.permissions
    };
}

function pickValue(primary, fallback) {
    return primary == null ? fallback : primary;
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
    if (Array.isArray(payload)) return payload;
    if (Array.isArray(payload?.mailboxes)) return payload.mailboxes;
    if (Array.isArray(payload?.Mailboxes)) return payload.Mailboxes;
    if (Array.isArray(payload?.data)) return payload.data;
    if (Array.isArray(payload?.value)) return payload.value;
    return [];
}

function normaliseHistoryData(payload) {
    const history = createEmptyHistoryData();
    if (!payload || typeof payload !== "object") return history;

    history.generatedUtc = payload.GeneratedUtc ?? payload.generatedUtc ?? null;

    if (Array.isArray(payload.MailboxHistory) || Array.isArray(payload.mailboxHistory)) {
        const mailboxHistory = Array.isArray(payload.MailboxHistory) ? payload.MailboxHistory : payload.mailboxHistory;
        mailboxHistory.forEach(record => addHistoryMailboxRecord(history, record));
        return history;
    }

    if (Array.isArray(payload)) {
        payload.forEach(record => addHistoryMailboxRecord(history, record));
        return history;
    }

    Object.entries(payload).forEach(([guid, samples]) => {
        if (guid === "GeneratedUtc" || guid === "generatedUtc" || !Array.isArray(samples) || samples.length === 0) return;
        const normalisedSamples = normaliseHistorySamples(samples);
        if (normalisedSamples.length === 0) return;

        const latest = normalisedSamples[normalisedSamples.length - 1];
        const mailbox = normaliseMailbox({
            ExchangeGuid: guid,
            PrimarySmtpAddress: latest.PrimarySmtpAddress,
            DisplayName: latest.DisplayName,
            Samples: normalisedSamples
        });

        history.mailboxes.push(mailbox);
        history.byGuid[mailbox.exchangeGuid] = normalisedSamples;
        if (mailbox.primarySmtpAddress) history.bySmtp[mailbox.primarySmtpAddress.toLowerCase()] = normalisedSamples;
    });

    return history;
}

function addHistoryMailboxRecord(history, record) {
    if (!record) return;
    const mailbox = normaliseMailbox(record);
    const samples = normaliseHistorySamples(record.Samples || record.samples);
    if (!isMailboxRenderable(mailbox) || samples.length === 0) return;

    history.mailboxes.push(mailbox);
    if (mailbox.exchangeGuid) history.byGuid[mailbox.exchangeGuid] = samples;
    if (mailbox.primarySmtpAddress) history.bySmtp[mailbox.primarySmtpAddress.toLowerCase()] = samples;
}

function normaliseHistorySamples(samples) {
    if (!Array.isArray(samples)) return [];

    return samples
        .filter(sample => sample && typeof sample === "object")
        .map(sample => ({
            TimestampUtc: sample.TimestampUtc ?? sample.timestampUtc ?? sample.Timestamp ?? sample.timestamp ?? null,
            PrimarySmtpAddress: sample.PrimarySmtpAddress ?? sample.primarySmtpAddress ?? "",
            DisplayName: sample.DisplayName ?? sample.displayName ?? "",
            SizeGB: getNumber(sample, ["SizeGB", "sizeGB", "TotalGB", "totalGB", "StorageGB", "MailboxSizeGB"]) ?? 0,
            ItemCount: getNumber(sample, ["ItemCount", "itemCount", "Items"]) ?? 0,
            UsagePercent: getNumber(sample, ["UsagePercent", "usagePercent"]) ?? 0,
            QuotaGB: getNumber(sample, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]),
            LastLogonTime: sample.LastLogonTime ?? sample.lastLogonTime ?? null,
            ArchiveEnabled: Boolean(sample.ArchiveEnabled ?? sample.archiveEnabled),
            ArchiveSizeGB: getNumber(sample, ["ArchiveSizeGB", "archiveSizeGB"]) ?? 0,
            ArchiveItemCount: getNumber(sample, ["ArchiveItemCount", "archiveItemCount"]) ?? 0
        }));
}

function normaliseMailbox(source) {
    const sample = Array.isArray(source?.Samples) && source.Samples.length > 0
        ? source.Samples[source.Samples.length - 1]
        : source?.current || {};

    const displayName = source?.DisplayName ?? source?.displayName ?? source?.MailboxName ?? source?.Mailbox?.DisplayName ?? source?.primarySmtpAddress ?? source?.PrimarySmtpAddress ?? "";
    const primarySmtpAddress = source?.PrimarySmtpAddress ?? source?.primarySmtpAddress ?? source?.SmtpAddress ?? source?.UserPrincipalName ?? source?.Mailbox?.PrimarySmtpAddress ?? "";
    const permissions = normalisePermissions(
        source?.permissions ??
        source?.Permissions ??
        source?.CurrentPermissions ??
        sample?.permissions ??
        sample?.Permissions
    );

    const totalGB = getNumber(sample, ["SizeGB", "totalGB", "StorageGB", "TotalItemSizeGB", "MailboxSizeGB"]) ??
        getNumber(source, ["SizeGB", "totalGB", "StorageGB", "TotalItemSizeGB", "MailboxSizeGB"]) ??
        0;
    const quotaGB = getNumber(sample, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]) ??
        getNumber(source, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]) ??
        null;
    const usagePercent = getNumber(sample, ["UsagePercent", "usagePercent"]) ??
        getNumber(source, ["UsagePercent", "usagePercent"]) ??
        (quotaGB > 0 ? (totalGB / quotaGB) * 100 : 0);

    return {
        exchangeGuid: String(source?.ExchangeGuid ?? source?.exchangeGuid ?? ""),
        displayName: String(displayName || primarySmtpAddress || source?.ExchangeGuid || "Unknown mailbox"),
        primarySmtpAddress: String(primarySmtpAddress || ""),
        current: {
            totalGB,
            itemCount: getNumber(sample, ["ItemCount", "itemCount", "Items"]) ?? getNumber(source, ["ItemCount", "itemCount", "Items"]) ?? 0,
            quotaGB,
            usagePercent,
            lastLogonTime: sample?.LastLogonTime ?? sample?.lastLogonTime ?? source?.LastLogonTime ?? source?.lastLogonTime ?? null,
            archiveEnabled: Boolean(sample?.ArchiveEnabled ?? sample?.archiveEnabled ?? source?.ArchiveEnabled ?? source?.archiveEnabled),
            archiveSizeGB: getNumber(sample, ["ArchiveSizeGB", "archiveSizeGB"]) ?? getNumber(source, ["ArchiveSizeGB", "archiveSizeGB"]) ?? 0,
            archiveItemCount: getNumber(sample, ["ArchiveItemCount", "archiveItemCount"]) ?? getNumber(source, ["ArchiveItemCount", "archiveItemCount"]) ?? 0
        },
        permissions
    };
}

function normalisePermissions(permissionSource) {
    if (!Array.isArray(permissionSource)) return [];
    return permissionSource
        .filter(Boolean)
        .map(permission => ({
            User: permission.User ?? permission.user ?? permission.Delegate ?? "",
            AccessRights: Array.isArray(permission.AccessRights ?? permission.accessRights ?? permission.Rights)
                ? (permission.AccessRights ?? permission.accessRights ?? permission.Rights)
                : String(permission.AccessRights ?? permission.accessRights ?? permission.Rights ?? "")
                    .split(",")
                    .map(part => part.trim())
                    .filter(Boolean),
            IsInherited: Boolean(permission.IsInherited ?? permission.isInherited),
            Deny: Boolean(permission.Deny ?? permission.deny)
        }));
}

function getHistoryPointsForMailbox(mailbox) {
    if (!mailbox) return [];
    if (mailbox.exchangeGuid && Array.isArray(state.historyData.byGuid[mailbox.exchangeGuid])) {
        return state.historyData.byGuid[mailbox.exchangeGuid];
    }
    const smtpAddress = String(mailbox.primarySmtpAddress || "").toLowerCase();
    if (smtpAddress && Array.isArray(state.historyData.bySmtp[smtpAddress])) {
        return state.historyData.bySmtp[smtpAddress];
    }
    return [];
}

function filterMailboxes(mailboxes, searchText) {
    const query = String(searchText || "").trim().toLowerCase();
    if (!query) return [...mailboxes];

    return mailboxes.filter(mailbox => {
        const haystack = `${mailbox.displayName} ${mailbox.primarySmtpAddress}`.toLowerCase();
        return query.split(/\s+/).every(token => haystack.includes(token));
    });
}

function getRankedMailboxes(searchText, limit) {
    const query = String(searchText || "").trim().toLowerCase();
    if (!query) return state.selectableMailboxes.slice(0, limit);

    const tokens = query.split(/\s+/).filter(Boolean);
    const ranked = state.selectableMailboxes
        .map(mailbox => ({ mailbox, score: scoreMailbox(mailbox, query, tokens) }))
        .filter(item => item.score > 0)
        .sort((left, right) => right.score - left.score || (right.mailbox.current.totalGB || 0) - (left.mailbox.current.totalGB || 0));

    return ranked.slice(0, limit).map(item => item.mailbox);
}

function scoreMailbox(mailbox, query, tokens) {
    const display = String(mailbox.displayName || "").toLowerCase();
    const smtp = String(mailbox.primarySmtpAddress || "").toLowerCase();
    const combined = `${display} ${smtp}`;
    if (!combined.includes(query)) {
        const everyTokenPresent = tokens.every(token => combined.includes(token));
        if (!everyTokenPresent) return 0;
    }

    let score = 0;
    if (smtp === query) score += 1200;
    if (display === query) score += 1150;
    if (display.startsWith(query)) score += 950;
    if (smtp.startsWith(query)) score += 930;
    if (display.includes(query)) score += 700;
    if (smtp.includes(query)) score += 680;
    if (tokens.every(token => display.includes(token))) score += 540;
    if (tokens.every(token => smtp.includes(token))) score += 520;
    score += Math.min(mailbox.current.totalGB || 0, 500) / 10;
    return score;
}

function isMailboxRenderable(mailbox) {
    return Boolean(mailbox && (mailbox.primarySmtpAddress || mailbox.exchangeGuid || mailbox.displayName));
}

function getMailboxKey(mailbox) {
    return String(mailbox.primarySmtpAddress || mailbox.exchangeGuid || mailbox.displayName || "").toLowerCase();
}

function getMailboxSearchLabel(mailbox) {
    return mailbox.primarySmtpAddress || mailbox.displayName || mailbox.exchangeGuid;
}

function buildMailboxUrl(pageName, mailbox) {
    const url = new URL(pageName, window.location.href);
    if (mailbox) {
        url.searchParams.set("mailbox", mailbox.primarySmtpAddress || mailbox.exchangeGuid);
    }
    return `${url.pathname.split("/").pop()}${url.search}`;
}

function navigateToMailboxPage(mailbox) {
    window.location.href = buildMailboxUrl("mailbox.html", mailbox);
}

function getRequestedMailboxValue() {
    return new URL(window.location.href).searchParams.get("mailbox");
}

function findMailboxByRequestedValue(value) {
    const needle = String(value || "").trim().toLowerCase();
    if (!needle) return null;
    return state.selectableMailboxes.find(mailbox =>
        getMailboxKey(mailbox) === needle ||
        String(mailbox.primarySmtpAddress || "").toLowerCase() === needle ||
        String(mailbox.exchangeGuid || "").toLowerCase() === needle
    ) || null;
}

function updateMailboxQueryParam(mailboxOrNull, replace) {
    const url = new URL(window.location.href);
    if (!mailboxOrNull) {
        url.searchParams.delete("mailbox");
    } else {
        url.searchParams.set("mailbox", mailboxOrNull.primarySmtpAddress || mailboxOrNull.exchangeGuid);
    }

    const method = replace ? "replaceState" : "pushState";
    window.history[method]({}, "", `${url.pathname.split("/").pop()}${url.search}`);
}

function updateNavLinks() {
    const selected = getSelectedMailbox();
    document.querySelectorAll("nav.view-nav a").forEach(link => {
        const url = new URL(link.getAttribute("href"), window.location.href);
        if (selected) {
            url.searchParams.set("mailbox", selected.primarySmtpAddress || selected.exchangeGuid);
        } else {
            url.searchParams.delete("mailbox");
        }
        link.setAttribute("href", `${url.pathname.split("/").pop()}${url.search}`);
    });
}

function resetAutoRefreshTimer() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(() => loadDashboard().catch(showError), refreshMs);
}

function updateLastUpdated(utcString) {
    const el = document.getElementById("lastUpdated");
    if (!el) return;
    el.textContent = utcString ? `Last updated: ${new Date(utcString).toLocaleString()}` : "Data loaded";
}

function highlightNav() {
    const page = getCurrentPage();
    document.querySelectorAll("nav.view-nav a").forEach(link => {
        link.classList.remove("active");
        const href = link.getAttribute("href") || "";
        if ((page === "overview" && href.includes("index.html")) || href.includes(`${page}.html`)) {
            link.classList.add("active");
        }
    });
}

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

function truncateLabel(text, maxLength) {
    const value = String(text || "");
    return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value;
}

function formatGB(value) {
    return Number(value || 0).toFixed(2);
}

function formatPercent(value) {
    return `${Number(value || 0).toFixed(1)}%`;
}

function formatCompactNumber(value) {
    return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value || 0);
}

function formatNumber(value) {
    return Number(value || 0).toLocaleString();
}

function formatDate(value) {
    if (!value) return "N/A";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "N/A" : date.toLocaleString();
}

function formatShortDate(value) {
    if (!value) return "N/A";
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "N/A" : date.toLocaleDateString();
}

function usageBadge(percent) {
    const value = Number(percent || 0);
    if (value >= CRITICAL_THRESHOLD) return `<span class="badge danger">${formatPercent(value)}</span>`;
    if (value >= WARNING_THRESHOLD) return `<span class="badge warning">${formatPercent(value)}</span>`;
    return formatPercent(value);
}

function getCssVariable(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function getChartColor(name) {
    return getCssVariable(`--chart-${name}`) || "#0078d4";
}

function escapeHtml(text) {
    return String(text || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function showError(error) {
    console.error(error);
    const status = document.getElementById("searchStatus");
    if (status) {
        status.textContent = error instanceof Error ? error.message : "An unexpected error occurred while loading the dashboard.";
    }
}
