const DATA_URL = "data.json";
const HISTORY_URL = "history.json";
const MAX_SEARCH_RESULTS = 24;
const MAX_TABLE_ROWS = 250;
const DEFAULT_PAGE_SIZE = 50;
const WARNING_THRESHOLD = 85;
const CRITICAL_THRESHOLD = 94;
const CLEANUP_WARNING_DAYS = 30;

const AVAILABLE_THEMES = [
    { id: "default-light",  name: "Default Light",   file: null,                         baseTheme: "light" },
    { id: "default-dark",   name: "Default Dark",    file: null,                         baseTheme: "dark"  },
    { id: "aurora-night",   name: "Aurora Night",    file: "theme/aurora-night.jsonc",   baseTheme: "dark"  },
    { id: "nerv",           name: "Nerv",            file: "theme/nerv.jsonc",           baseTheme: "dark"  },
    { id: "graphite-ocean", name: "Graphite Ocean",  file: "theme/graphite-ocean.jsonc", baseTheme: "dark"  },
    { id: "summit-light",   name: "Summit Light",    file: "theme/summit-light.jsonc",   baseTheme: "light" },
    { id: "dusk-rose",      name: "Dusk Rose",       file: "theme/dusk-rose.jsonc",      baseTheme: "light" },
];

const TABLE_EXPORT_CONFIG = {
    usageTable: {
        title: "Current Mailbox Usage",
        toExportRow: m => ({
            displayName: m.displayName, primarySmtpAddress: m.primarySmtpAddress,
            storageGB: m.current.totalGB, itemCount: m.current.itemCount,
            quotaGB: m.current.quotaGB, usagePercent: m.current.usagePercent,
            mailboxType: m.licensing.recipientTypeDetails,
            licenseRequired: m.licensing.licenseRequired,
            hasLicense: m.licensing.hasLicense,
            licenseType: m.licensing.licenseType,
            cleanupStatus: getCleanupStatusLabel(m),
            retentionPolicy: m.retention.retentionPolicy,
            permissions: m.permissions.length, lastLogonTime: m.current.lastLogonTime
        }),
        columns: [
            { header: "Mailbox",       value: m => m.displayName },
            { header: "SMTP Address",  value: m => m.primarySmtpAddress },
            { header: "Storage GB",    value: m => m.current.totalGB },
            { header: "Items",         value: m => m.current.itemCount },
            { header: "Quota GB",      value: m => m.current.quotaGB ?? "Unlimited" },
            { header: "Usage %",       value: m => m.current.usagePercent },
            { header: "Mailbox Type",  value: m => m.licensing.recipientTypeDetails || "Unknown" },
            { header: "License",       value: m => getLicenseStatusLabel(m) },
            { header: "Cleanup",       value: m => getCleanupStatusLabel(m) },
            { header: "Permissions",   value: m => m.permissions.length },
            { header: "Last Logon",    value: m => m.current.lastLogonTime ?? "" },
        ]
    },
    permsTable: {
        title: "Mailbox Permissions",
        toExportRow: ({ mailbox, permission }) => ({
            mailboxName: mailbox.displayName, mailboxAddress: mailbox.primarySmtpAddress,
            delegateUser: permission.User, accessRights: Array.isArray(permission.AccessRights) ? permission.AccessRights.join(", ") : permission.AccessRights,
            isInherited: permission.IsInherited
        }),
        columns: [
            { header: "Mailbox",      value: r => r.mailbox.displayName },
            { header: "SMTP Address", value: r => r.mailbox.primarySmtpAddress },
            { header: "Delegate",     value: r => r.permission.User },
            { header: "Rights",       value: r => Array.isArray(r.permission.AccessRights) ? r.permission.AccessRights.join(", ") : String(r.permission.AccessRights || "") },
            { header: "Inherited",    value: r => r.permission.IsInherited ? "Yes" : "No" },
        ]
    },
    thresholdTable: {
        title: "Mailboxes at Threshold",
        toExportRow: m => ({
            displayName: m.displayName, primarySmtpAddress: m.primarySmtpAddress,
            storageGB: m.current.totalGB, quotaGB: m.current.quotaGB,
            usagePercent: m.current.usagePercent,
            status: safeNumber(m.current.usagePercent) >= CRITICAL_THRESHOLD ? "Critical" : "Warning"
        }),
        columns: [
            { header: "Mailbox",    value: m => m.displayName },
            { header: "Storage GB", value: m => m.current.totalGB },
            { header: "Quota GB",   value: m => m.current.quotaGB ?? "Unlimited" },
            { header: "Usage %",    value: m => m.current.usagePercent },
            { header: "Status",     value: m => safeNumber(m.current.usagePercent) >= CRITICAL_THRESHOLD ? "Critical" : "Warning" },
        ]
    },
    historyTable: {
        title: "Mailbox History",
        toExportRow: p => ({ timestampUtc: p.TimestampUtc, storageGB: p.SizeGB, itemCount: p.ItemCount, usagePercent: p.UsagePercent }),
        columns: [
            { header: "Snapshot Date", value: p => p.TimestampUtc },
            { header: "Storage GB",    value: p => p.SizeGB },
            { header: "Items",         value: p => p.ItemCount },
            { header: "Usage %",       value: p => p.UsagePercent },
        ]
    },
    mailboxSnapshotsTable: {
        title: "Mailbox Snapshots",
        toExportRow: p => ({ timestampUtc: p.TimestampUtc, primaryGB: p.SizeGB, archiveGB: p.ArchiveSizeGB, itemCount: p.ItemCount, usagePercent: p.UsagePercent }),
        columns: [
            { header: "Snapshot Date", value: p => p.TimestampUtc },
            { header: "Primary GB",    value: p => p.SizeGB },
            { header: "Archive GB",    value: p => p.ArchiveSizeGB },
            { header: "Items",         value: p => p.ItemCount },
            { header: "Usage %",       value: p => p.UsagePercent },
        ]
    },
    mailboxPermissionsTable: {
        title: "Explicit Permissions",
        toExportRow: p => ({ user: p.User, accessRights: Array.isArray(p.AccessRights) ? p.AccessRights.join(", ") : String(p.AccessRights || ""), isInherited: p.IsInherited }),
        columns: [
            { header: "Delegate", value: p => p.User },
            { header: "Rights",   value: p => Array.isArray(p.AccessRights) ? p.AccessRights.join(", ") : String(p.AccessRights || "") },
            { header: "Inherited", value: p => p.IsInherited ? "Yes" : "No" },
        ]
    },
    licensingTable: {
        title: "Mailbox Licensing",
        toExportRow: m => ({
            displayName: m.displayName,
            primarySmtpAddress: m.primarySmtpAddress,
            mailboxType: m.licensing.recipientTypeDetails,
            licenseRequired: m.licensing.licenseRequired,
            hasLicense: m.licensing.hasLicense,
            licenseType: m.licensing.licenseType,
            isLicenseCompliant: m.licensing.isLicenseCompliant,
            reason: m.licensing.licenseRequirementReason
        }),
        columns: [
            { header: "Mailbox", value: m => m.displayName },
            { header: "SMTP Address", value: m => m.primarySmtpAddress },
            { header: "Mailbox Type", value: m => m.licensing.recipientTypeDetails || "Unknown" },
            { header: "Required", value: m => m.licensing.licenseRequired === true ? "Yes" : (m.licensing.licenseRequired === false ? "No" : "Unknown") },
            { header: "Assigned", value: m => m.licensing.hasLicense === true ? "Yes" : (m.licensing.hasLicense === false ? "No" : "Unknown") },
            { header: "License Type", value: m => m.licensing.licenseType || "" },
            { header: "Compliance", value: m => m.licensing.isLicenseCompliant === true ? "Compliant" : "Gap" },
        ]
    },
    retentionPolicyCatalogTable: {
        title: "Retention Policy Catalog",
        toExportRow: p => ({
            policy: p.name,
            mailboxCount: p.mailboxCount,
            isDefaultPolicy: p.isDefaultPolicy,
            tagCount: p.tagCount,
            properties: formatRetentionPolicyProperties(p)
        }),
        columns: [
            { header: "Policy", value: p => p.name },
            { header: "Mailboxes", value: p => p.mailboxCount },
            { header: "Default", value: p => p.isDefaultPolicy === true ? "Yes" : "No" },
            { header: "Tag Count", value: p => p.tagCount ?? 0 },
            { header: "Properties", value: p => formatRetentionPolicyProperties(p) }
        ]
    },
};

let refreshTimer = null;
let refreshMs = 60000;

const state = {
    historyData: createEmptyHistoryData(),
    retentionPolicies: [],
    currentMailboxes: [],
    selectableMailboxes: [],
    mailboxLookup: new Map(),
    selectedMailboxKey: null,
    scopes: [],
    activeScopeId: null,
    scopeCounts: { total: 0, inScope: 0 },
    filterQuery: "",
    sort: {},
    pagination: {
        usageTable:              { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        permsTable:              { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        thresholdTable:          { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        historyTable:            { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        mailboxSnapshotsTable:   { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        mailboxPermissionsTable: { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        licensingTable:          { pageSize: DEFAULT_PAGE_SIZE, page: 1 },
        retentionPolicyCatalogTable: { pageSize: DEFAULT_PAGE_SIZE, page: 1 }
    },
    tableData: {}
};

window.allMailboxes = [];

document.addEventListener("DOMContentLoaded", () => {
    readFilterSortFromUrl();
    bindHeaderControls();
    bindSearchControls();
    bindTableControls();
    bindSortableHeaders();
    buildFilterBar();
    loadDashboard().catch(showError);
    resetAutoRefreshTimer();
});

function bindHeaderControls() {
    const refreshButton = document.getElementById("refreshButton");
    if (refreshButton) {
        refreshButton.addEventListener("click", () => loadDashboard().catch(showError));
    }

    initThemeSelector();
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

    await ensureScopesLoaded();

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
    const retentionPoliciesFromData = normaliseRetentionPolicyCatalog(rawDashboardData);
    const retentionPoliciesFromHistory = normaliseRetentionPolicyCatalog(rawHistoryData);
    state.retentionPolicies = retentionPoliciesFromData.length > 0 ? retentionPoliciesFromData : retentionPoliciesFromHistory;

    const currentFromData = extractMailboxArray(rawDashboardData)
        .map(normaliseMailbox)
        .filter(isMailboxRenderable);

    const currentFromHistory = state.historyData.mailboxes.filter(isMailboxRenderable);

    const allCurrent = mergeMailboxCollections(currentFromData, currentFromHistory);
    const allSelectable = mergeMailboxCollections(allCurrent, currentFromHistory);

    const scope = getActiveScope();
    state.scopeCounts = { total: allCurrent.length, inScope: 0 };
    state.currentMailboxes = applyScopeFilter(allCurrent, scope);
    state.selectableMailboxes = applyScopeFilter(allSelectable, scope);
    state.scopeCounts.inScope = state.currentMailboxes.length;

    state.mailboxLookup = new Map(state.selectableMailboxes.map(mailbox => [getMailboxKey(mailbox), mailbox]));
    window.allMailboxes = state.currentMailboxes;

    renderScopeIndicator();
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
    const found = filterMailboxes(state.currentMailboxes, getSearchInputValue());
    return applyTableFilter(found);
}

/* ═══════════════════════════════════════════════════════════════
   TABLE FILTER AND SORT
═══════════════════════════════════════════════════════════════ */

// Columns are described here rather than in the HTML so that any copy of a report
// page picks up sorting automatically. Order must match the <th> order.
const SORTABLE_COLUMNS = {
    usageTable: [
        { key: "displayName",   type: "text",   get: m => m.displayName },
        { key: "smtp",          type: "text",   get: m => m.primarySmtpAddress },
        { key: "totalGB",       type: "number", get: m => m.current.totalGB },
        { key: "itemCount",     type: "number", get: m => m.current.itemCount },
        { key: "quotaGB",       type: "number", get: m => m.current.quotaGB },
        { key: "usagePercent",  type: "number", get: m => m.current.usagePercent },
        { key: "permissions",   type: "number", get: m => m.permissions.length },
        { key: "lastLogon",     type: "date",   get: m => m.current.lastLogonTime }
    ],
    thresholdTable: [
        { key: "displayName",   type: "text",   get: m => m.displayName },
        { key: "totalGB",       type: "number", get: m => m.current.totalGB },
        { key: "quotaGB",       type: "number", get: m => m.current.quotaGB },
        { key: "usagePercent",  type: "number", get: m => m.current.usagePercent },
        { key: "status",        type: "number", get: m => m.current.usagePercent }
    ],
    permsTable: [
        { key: "displayName",   type: "text",   get: r => r.mailbox.displayName },
        { key: "delegate",      type: "text",   get: r => r.permission.User || r.permission.user || r.permission.Delegate || "" },
        { key: "rights",        type: "text",   get: r => formatAccessRights(r.permission) },
        { key: "inherited",     type: "number", get: r => (r.permission.IsInherited || r.permission.isInherited) ? 1 : 0 }
    ]
};

function formatAccessRights(permission) {
    const rights = permission.AccessRights || permission.accessRights || permission.Rights;
    return Array.isArray(rights) ? rights.join(", ") : String(rights || "");
}

function hasWildcard(text) {
    return /[*?]/.test(text);
}

function applyTableFilter(mailboxes) {
    const query = state.filterQuery.trim();
    if (!query) return mailboxes;
    return mailboxes.filter(mailbox => mailboxMatchesFilter(mailbox, query));
}

// A query containing * or ? is treated as a whole-value wildcard pattern;
// anything else is a plain substring search, which is what people expect by default.
function mailboxMatchesFilter(mailbox, query) {
    const fields = [
        String(mailbox.displayName || "").toLowerCase(),
        String(mailbox.primarySmtpAddress || "").toLowerCase(),
        String(mailbox.exchangeGuid || "").toLowerCase()
    ];

    const lowered = query.toLowerCase();

    if (hasWildcard(lowered)) {
        return lowered.split(/\s+/).filter(Boolean).every(term =>
            fields.some(field => matchesPattern(field, term))
        );
    }

    return lowered.split(/\s+/).filter(Boolean).every(term =>
        fields.some(field => field.includes(term))
    );
}

function getSortState(tableId) {
    if (!state.sort[tableId]) {
        state.sort[tableId] = { key: null, direction: "asc" };
    }
    return state.sort[tableId];
}

function sortRows(tableId, rows) {
    const sort = getSortState(tableId);
    if (!sort.key) return rows;

    const column = (SORTABLE_COLUMNS[tableId] || []).find(c => c.key === sort.key);
    if (!column) return rows;

    const factor = sort.direction === "desc" ? -1 : 1;

    return [...rows].sort((left, right) => {
        const a = column.get(left);
        const b = column.get(right);

        // Missing values always sort last, whichever direction is active.
        const aMissing = a === null || a === undefined || a === "";
        const bMissing = b === null || b === undefined || b === "";
        if (aMissing && bMissing) return 0;
        if (aMissing) return 1;
        if (bMissing) return -1;

        if (column.type === "number") return (Number(a) - Number(b)) * factor;
        if (column.type === "date") return (new Date(a) - new Date(b)) * factor;
        return String(a).localeCompare(String(b), undefined, { sensitivity: "base" }) * factor;
    });
}

function bindSortableHeaders() {
    document.addEventListener("click", event => {
        const header = event.target.closest("th[data-sort-key]");
        if (!header) return;

        const table = header.closest("table");
        if (!table || !SORTABLE_COLUMNS[table.id]) return;

        const key = header.getAttribute("data-sort-key");
        const sort = getSortState(table.id);

        if (sort.key === key) {
            sort.direction = sort.direction === "asc" ? "desc" : "asc";
        } else {
            sort.key = key;
            sort.direction = header.getAttribute("data-sort-type") === "text" ? "asc" : "desc";
        }

        updateFilterSortQueryParams();
        applyFilter();
    });
}

function decorateSortableHeaders() {
    Object.entries(SORTABLE_COLUMNS).forEach(([tableId, columns]) => {
        const table = document.getElementById(tableId);
        if (!table) return;

        const headers = table.querySelectorAll("thead th");
        const sort = getSortState(tableId);

        headers.forEach((header, index) => {
            const column = columns[index];
            if (!column) return;

            header.setAttribute("data-sort-key", column.key);
            header.setAttribute("data-sort-type", column.type);
            header.classList.add("sortable");
            header.classList.toggle("sorted-asc", sort.key === column.key && sort.direction === "asc");
            header.classList.toggle("sorted-desc", sort.key === column.key && sort.direction === "desc");
            header.setAttribute("aria-sort",
                sort.key !== column.key ? "none" : (sort.direction === "asc" ? "ascending" : "descending"));
            if (!header.title) header.title = "Sort by this column";
        });
    });
}

function buildFilterBar() {
    const host = document.querySelector(".table-header");
    if (!host || document.getElementById("tableFilter")) return;
    if (!Object.keys(SORTABLE_COLUMNS).some(id => document.getElementById(id))) return;

    const wrapper = document.createElement("div");
    wrapper.className = "table-filter";
    wrapper.innerHTML = `
        <label class="sr-only" for="tableFilter">Filter results</label>
        <input id="tableFilter" type="search" autocomplete="off"
               placeholder="Filter results - use * and ? for wildcards"
               value="${escapeHtml(state.filterQuery)}">
        <button id="clearTableFilter" class="btn-link" type="button" hidden>Clear</button>
        <span id="tableFilterMeta" class="table-filter-meta"></span>
    `;

    const controls = host.querySelector(".table-controls");
    if (controls) {
        host.insertBefore(wrapper, controls);
    } else {
        host.appendChild(wrapper);
    }

    const input = wrapper.querySelector("#tableFilter");
    let debounce = null;
    input.addEventListener("input", () => {
        clearTimeout(debounce);
        debounce = setTimeout(() => {
            state.filterQuery = input.value;
            Object.keys(state.pagination).forEach(k => { state.pagination[k].page = 1; });
            updateFilterSortQueryParams();
            applyFilter({ keepPagination: true });
        }, 200);
    });

    wrapper.querySelector("#clearTableFilter").addEventListener("click", () => {
        input.value = "";
        state.filterQuery = "";
        updateFilterSortQueryParams();
        applyFilter();
        input.focus();
    });
}

function renderFilterMeta(shown, total) {
    const meta = document.getElementById("tableFilterMeta");
    const clear = document.getElementById("clearTableFilter");
    if (clear) clear.hidden = !state.filterQuery;
    if (!meta) return;

    meta.textContent = state.filterQuery
        ? `${formatNumber(shown)} of ${formatNumber(total)} match`
        : "";
}

function readFilterSortFromUrl() {
    const params = new URL(window.location.href).searchParams;

    state.filterQuery = params.get("q") || "";

    const sortKey = params.get("sort");
    const direction = params.get("dir") === "desc" ? "desc" : "asc";
    if (sortKey) {
        Object.keys(SORTABLE_COLUMNS).forEach(tableId => {
            if (SORTABLE_COLUMNS[tableId].some(c => c.key === sortKey)) {
                state.sort[tableId] = { key: sortKey, direction };
            }
        });
    }
}

function updateFilterSortQueryParams() {
    const url = new URL(window.location.href);

    if (state.filterQuery) {
        url.searchParams.set("q", state.filterQuery);
    } else {
        url.searchParams.delete("q");
    }

    const activeSort = getActiveSortForPage();
    if (activeSort?.key) {
        url.searchParams.set("sort", activeSort.key);
        url.searchParams.set("dir", activeSort.direction);
    } else {
        url.searchParams.delete("sort");
        url.searchParams.delete("dir");
    }

    window.history.replaceState({}, "", `${url.pathname.split("/").pop()}${url.search}`);
}

function getActiveSortForPage() {
    for (const tableId of Object.keys(SORTABLE_COLUMNS)) {
        if (document.getElementById(tableId) && state.sort[tableId]?.key) {
            return state.sort[tableId];
        }
    }
    return null;
}

function applyFilter(opts = {}) {
    if (!opts.keepPagination) {
        Object.keys(state.pagination).forEach(k => { state.pagination[k].page = 1; });
    }
    renderSearchUi();
    updateNavLinks();

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
        case "licensing":
            renderLicensingPage();
            break;
        case "retentionpolicy":
            renderRetentionPolicyPage();
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
            <div class="summary-metric"><span class="label">Cleanup</span><strong>${escapeHtml(getCleanupStatusLabel(selected))}</strong></div>
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
    renderRetentionPolicyTable();
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

function renderLicensingPage() {
    const selected = getSelectedMailbox();
    const mailboxes = selected ? [selected] : getMailboxes();

    renderSelectedMailboxPanel(selected);
    drawLicensingOverviewCharts(mailboxes);
    renderLicensingTable(mailboxes);
}

function renderRetentionPolicyPage() {
    const selected = getSelectedMailbox();
    const mailboxes = selected ? [selected] : getMailboxes();

    renderSelectedMailboxPanel(selected);
    drawRetentionPolicyCharts(mailboxes);
    renderRetentionPolicyCatalogTable(mailboxes);
    drawSingleMailboxPolicyChangeChart(selected);
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
                    <div class="spotlight-metric"><span class="label">Cleanup health</span><strong>${escapeHtml(getCleanupStatusLabel(selected))}</strong></div>
                    <div class="spotlight-metric"><span class="label">Mailbox type</span><strong>${escapeHtml(selected.licensing.recipientTypeDetails || "Unknown")}</strong></div>
                    <div class="spotlight-metric"><span class="label">License required</span><strong>${selected.licensing.licenseRequired === true ? "Yes" : (selected.licensing.licenseRequired === false ? "No" : "Unknown")}</strong></div>
                    <div class="spotlight-metric"><span class="label">License assigned</span><strong>${selected.licensing.hasLicense === true ? "Yes" : (selected.licensing.hasLicense === false ? "No" : "Unknown")}</strong></div>
                    <div class="spotlight-metric"><span class="label">License type</span><strong>${escapeHtml(selected.licensing.licenseType || "N/A")}</strong></div>
                    <div class="spotlight-metric"><span class="label">Retention policy</span><strong>${escapeHtml(selected.retention.retentionPolicy || "None")}</strong></div>
                    <div class="spotlight-metric"><span class="label">Policy mailbox bindings</span><strong>${selected.retention.retentionPolicyDetails?.mailboxCount == null ? "N/A" : formatNumber(selected.retention.retentionPolicyDetails.mailboxCount)}</strong></div>
                    <div class="spotlight-metric"><span class="label">Retention policy changed</span><strong>${escapeHtml(getChangeAgeLabel(selected.retentionPolicyChangeHistory))}</strong></div>
                    <div class="spotlight-metric"><span class="label">License state changed</span><strong>${escapeHtml(getChangeAgeLabel(selected.licenseAssignmentHistory))}</strong></div>
                    <div class="spotlight-metric"><span class="label">Litigation hold</span><strong>${formatBooleanState(selected.retention.litigationHoldEnabled)}</strong></div>
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
        <article><span class="label">Cleanup status</span><strong>${escapeHtml(getCleanupStatusLabel(selected))}</strong></article>
        <article><span class="label">Mailbox type</span><strong>${escapeHtml(selected.licensing.recipientTypeDetails || "Unknown")}</strong></article>
        <article><span class="label">License required</span><strong>${selected.licensing.licenseRequired === true ? "Yes" : (selected.licensing.licenseRequired === false ? "No" : "Unknown")}</strong></article>
        <article><span class="label">License assigned</span><strong>${selected.licensing.hasLicense === true ? "Yes" : (selected.licensing.hasLicense === false ? "No" : "Unknown")}</strong></article>
        <article><span class="label">License type</span><strong>${escapeHtml(selected.licensing.licenseType || "N/A")}</strong></article>
        <article><span class="label">Retention policy</span><strong>${escapeHtml(selected.retention.retentionPolicy || "None")}</strong></article>
        <article><span class="label">Policy mailbox bindings</span><strong>${selected.retention.retentionPolicyDetails?.mailboxCount == null ? "N/A" : formatNumber(selected.retention.retentionPolicyDetails.mailboxCount)}</strong></article>
        <article><span class="label">Retention policy changed</span><strong>${escapeHtml(getChangeAgeLabel(selected.retentionPolicyChangeHistory))}</strong></article>
        <article><span class="label">License state changed</span><strong>${escapeHtml(getChangeAgeLabel(selected.licenseAssignmentHistory))}</strong></article>
        <article><span class="label">Litigation hold</span><strong>${formatBooleanState(selected.retention.litigationHoldEnabled)}</strong></article>
    `;
}

function renderUsageTable(mailboxes) {
    const tbody = document.querySelector("#usageTable tbody");
    const tableMeta = document.getElementById("tableMeta");
    if (!tbody) return;

    const sortState = getSortState("usageTable");
    const sorted = sortState.key
        ? sortRows("usageTable", mailboxes)
        : [...mailboxes].sort((a, b) => safeNumber(b.current.totalGB) - safeNumber(a.current.totalGB));

    state.tableData.usageTable = sorted;
    renderFilterMeta(sorted.length, state.currentMailboxes.length);
    decorateSortableHeaders();

    const pg = state.pagination.usageTable;
    const totalPages = Math.max(1, Math.ceil(sorted.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const rows = sorted.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    if (tableMeta) {
        tableMeta.textContent = sorted.length === 0
            ? "No mailboxes found matching that search."
            : `${formatNumber(sorted.length)} mailbox${sorted.length === 1 ? "" : "es"}`;
    }

    renderPaginationBar("usageTablePagination", "usageTable");

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="11" class="empty-state">No mailboxes found matching that search.</td></tr>`;
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
            <td>${escapeHtml(mailbox.licensing.recipientTypeDetails || "Unknown")}</td>
            <td>${licenseBadge(mailbox)}</td>
            <td>${cleanupBadge(mailbox)}</td>
            <td>${formatNumber(mailbox.permissions.length)}</td>
            <td>${formatDate(mailbox.current.lastLogonTime)}</td>
        </tr>
    `).join("");
}

function renderRetentionPolicyTable() {
    const tbody = document.querySelector("#retentionPolicyTable tbody");
    const meta = document.getElementById("retentionPolicyMeta");
    if (!tbody || !meta) return;

    const catalog = state.retentionPolicies.length > 0
        ? state.retentionPolicies
        : buildRetentionPolicyCatalogFromMailboxes(state.currentMailboxes);

    if (catalog.length === 0) {
        meta.textContent = "No retention policy assignments were discovered.";
        tbody.innerHTML = `<tr><td colspan="5" class="empty-state">No retention policy catalog is available yet.</td></tr>`;
        return;
    }

    const totalMailboxesBound = catalog.reduce((sum, policy) => sum + safeNumber(policy.mailboxCount), 0);
    meta.textContent = `${formatNumber(catalog.length)} policy${catalog.length === 1 ? "" : "ies"} cataloged across ${formatNumber(totalMailboxesBound)} mailbox binding${totalMailboxesBound === 1 ? "" : "s"}.`;

    tbody.innerHTML = catalog.map(policy => `
        <tr>
            <td>${escapeHtml(policy.name)}</td>
            <td>${formatNumber(policy.mailboxCount)}</td>
            <td>${policy.isDefaultPolicy === true ? "Yes" : "No"}</td>
            <td>${formatNumber(policy.tagCount)}</td>
            <td>${escapeHtml(formatRetentionPolicyProperties(policy))}</td>
        </tr>
    `).join("");
}

function drawLicensingOverviewCharts(mailboxes) {
    const requiredAndCompliant = mailboxes.filter(mailbox => mailbox.licensing.licenseRequired === true && mailbox.licensing.hasLicense === true).length;
    const requiredAndMissing = mailboxes.filter(mailbox => mailbox.licensing.licenseRequired === true && mailbox.licensing.hasLicense !== true).length;
    const notRequired = mailboxes.filter(mailbox => mailbox.licensing.licenseRequired === false).length;

    drawRingChart("licensingComplianceChart", [
        { label: "Required + Assigned", value: requiredAndCompliant, color: getChartColor("success") },
        { label: "Required + Missing", value: requiredAndMissing, color: getChartColor("danger") },
        { label: "Not Required", value: notRequired, color: getChartColor("muted") }
    ], [`${formatNumber(mailboxes.length)}`, "mailboxes"]);

    const typeCounts = new Map();
    mailboxes.forEach(mailbox => {
        const key = String(mailbox.licensing.licenseType || (mailbox.licensing.hasLicense ? "Assigned (Unknown Type)" : "Unassigned")).trim();
        typeCounts.set(key, safeNumber(typeCounts.get(key)) + 1);
    });
    const typeBars = Array.from(typeCounts.entries())
        .map(([label, value]) => ({ label: truncateLabel(label, 28), value }))
        .sort((left, right) => right.value - left.value)
        .slice(0, 12);
    drawHorizontalBarChart("licensingTypeHistogramChart", typeBars, "mailboxes");
}

function renderLicensingTable(mailboxes) {
    const tbody = document.querySelector("#licensingTable tbody");
    const tableMeta = document.getElementById("licensingTableMeta");
    if (!tbody || !tableMeta) return;

    const rows = [...mailboxes].sort((left, right) => {
        const leftGap = left.licensing.licenseRequired === true && left.licensing.hasLicense !== true ? 1 : 0;
        const rightGap = right.licensing.licenseRequired === true && right.licensing.hasLicense !== true ? 1 : 0;
        if (rightGap !== leftGap) return rightGap - leftGap;
        return safeNumber(right.current.totalGB) - safeNumber(left.current.totalGB);
    });
    state.tableData.licensingTable = rows;

    const pg = state.pagination.licensingTable;
    const totalPages = Math.max(1, Math.ceil(rows.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const pageRows = rows.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    const gaps = rows.filter(mailbox => mailbox.licensing.licenseRequired === true && mailbox.licensing.hasLicense !== true).length;
    tableMeta.textContent = `${formatNumber(rows.length)} mailbox${rows.length === 1 ? "" : "es"} in view, ${formatNumber(gaps)} required-license gap${gaps === 1 ? "" : "s"}.`;

    renderPaginationBar("licensingTablePagination", "licensingTable");

    if (pageRows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="8" class="empty-state">No mailbox licensing data found.</td></tr>`;
        return;
    }

    tbody.innerHTML = pageRows.map(mailbox => `
        <tr>
            <td><a class="table-link" href="${escapeHtml(buildMailboxUrl("mailbox.html", mailbox))}">${escapeHtml(mailbox.displayName)}</a></td>
            <td>${escapeHtml(mailbox.primarySmtpAddress)}</td>
            <td>${escapeHtml(mailbox.licensing.recipientTypeDetails || "Unknown")}</td>
            <td>${mailbox.licensing.licenseRequired === true ? "Yes" : (mailbox.licensing.licenseRequired === false ? "No" : "Unknown")}</td>
            <td>${mailbox.licensing.hasLicense === true ? "Yes" : (mailbox.licensing.hasLicense === false ? "No" : "Unknown")}</td>
            <td>${escapeHtml(mailbox.licensing.licenseType || "")}</td>
            <td>${licenseBadge(mailbox)}</td>
            <td>${escapeHtml(mailbox.licensing.licenseRequirementReason || "")}</td>
        </tr>
    `).join("");
}

function drawRetentionPolicyCharts(mailboxes) {
    const policyCounts = new Map();
    mailboxes.forEach(mailbox => {
        const policyName = String(mailbox.retention.retentionPolicy || "Unassigned").trim() || "Unassigned";
        policyCounts.set(policyName, safeNumber(policyCounts.get(policyName)) + 1);
    });

    const ringSegments = Array.from(policyCounts.entries())
        .sort((left, right) => right[1] - left[1])
        .slice(0, 8)
        .map(([label, value], index) => ({
            label,
            value,
            color: [
                getChartColor("primary"),
                getChartColor("secondary"),
                getChartColor("accent"),
                getChartColor("warning"),
                getChartColor("success"),
                getChartColor("danger"),
                getChartColor("muted"),
                "#9b59b6"
            ][index % 8]
        }));

    drawRingChart("retentionPolicyDistributionChart", ringSegments, [`${formatNumber(mailboxes.length)}`, "mailboxes"]);

    const bars = Array.from(policyCounts.entries())
        .map(([label, value]) => ({ label: truncateLabel(label, 26), value }))
        .sort((left, right) => right.value - left.value)
        .slice(0, 12);
    drawVerticalBarChart("retentionPolicyHistogramChart", bars, "mailboxes");
}

function renderRetentionPolicyCatalogTable(mailboxes) {
    const tbody = document.querySelector("#retentionPolicyCatalogTable tbody");
    const tableMeta = document.getElementById("retentionPolicyCatalogMeta");
    if (!tbody || !tableMeta) return;

    const selected = getSelectedMailbox();
    const fullCatalog = state.retentionPolicies.length > 0 ? state.retentionPolicies : buildRetentionPolicyCatalogFromMailboxes(state.currentMailboxes);
    const filtered = selected
        ? fullCatalog.filter(policy => String(policy.name || "").toLowerCase() === String(selected.retention.retentionPolicy || "").toLowerCase())
        : fullCatalog;

    state.tableData.retentionPolicyCatalogTable = filtered;
    const pg = state.pagination.retentionPolicyCatalogTable;
    const totalPages = Math.max(1, Math.ceil(filtered.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const pageRows = filtered.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    tableMeta.textContent = selected
        ? `Catalog details for selected mailbox policy (${selected.retention.retentionPolicy || "Unassigned"}).`
        : `${formatNumber(filtered.length)} retention policy catalog entr${filtered.length === 1 ? "y" : "ies"}.`;

    renderPaginationBar("retentionPolicyCatalogPagination", "retentionPolicyCatalogTable");

    if (pageRows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="empty-state">No retention policy metadata is available for this view.</td></tr>`;
        return;
    }

    tbody.innerHTML = pageRows.map(policy => `
        <tr>
            <td>${escapeHtml(policy.name)}</td>
            <td>${formatNumber(policy.mailboxCount)}</td>
            <td>${policy.isDefaultPolicy === true ? "Yes" : "No"}</td>
            <td>${formatNumber(policy.tagCount)}</td>
            <td>${escapeHtml(formatRetentionPolicyProperties(policy))}</td>
        </tr>
    `).join("");
}

function drawSingleMailboxPolicyChangeChart(selected) {
    const canvasId = "singleMailboxPolicyChangeChart";
    if (!document.getElementById(canvasId)) return;
    if (!selected) {
        drawEmptyCanvasMessage(canvasId, "Select a mailbox to inspect retention-policy change timing.");
        return;
    }

    const changes = selected.retentionPolicyChangeHistory || [];
    if (changes.length < 2) {
        drawEmptyCanvasMessage(canvasId, "Policy change history requires at least two snapshots.");
        return;
    }

    const rows = [];
    for (let index = 1; index < changes.length; index += 1) {
        const previous = new Date(changes[index - 1].timestampUtc);
        const current = new Date(changes[index].timestampUtc);
        const days = Number.isFinite(current.getTime()) && Number.isFinite(previous.getTime())
            ? Math.max(0, Math.round((current - previous) / 86400000))
            : 0;
        rows.push({
            label: truncateLabel(changes[index].retentionPolicy || "Policy", 24),
            value: days
        });
    }

    drawVerticalBarChart(canvasId, rows, "days");
}

function renderPermissionsTable() {
    const tbody = document.querySelector("#permsTable tbody");
    const tableMeta = document.getElementById("tableMeta");
    if (!tbody) return;

    const selected = getSelectedMailbox();
    const query = getSearchInputValue().trim().toLowerCase();
    const mailboxes = selected ? [selected] : state.currentMailboxes;
    const rows = [];
    let totalRows = 0;

    mailboxes.forEach(mailbox => {
        mailbox.permissions.forEach(permission => {
            totalRows++;

            const mailboxName = `${mailbox.displayName} ${mailbox.primarySmtpAddress}`.toLowerCase();
            const delegateName = String(permission.User || permission.user || permission.Delegate || "").toLowerCase();
            if (query && !selected && !mailboxName.includes(query) && !delegateName.includes(query)) {
                return;
            }

            // The wildcard filter also matches the delegate, so a search like *@contoso.com
            // finds every mailbox that delegate has rights on.
            if (state.filterQuery && !selected) {
                const matchesMailbox = mailboxMatchesFilter(mailbox, state.filterQuery);
                const matchesDelegate = hasWildcard(state.filterQuery)
                    ? matchesPattern(delegateName, state.filterQuery.toLowerCase())
                    : delegateName.includes(state.filterQuery.toLowerCase());
                if (!matchesMailbox && !matchesDelegate) return;
            }

            rows.push({ mailbox, permission });
        });
    });

    const sorted = sortRows("permsTable", rows);
    state.tableData.permsTable = sorted;
    renderFilterMeta(sorted.length, totalRows);
    decorateSortableHeaders();

    const pg = state.pagination.permsTable;
    const totalPages = Math.max(1, Math.ceil(sorted.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const pageRows = sorted.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    if (tableMeta) {
        tableMeta.textContent = selected
            ? `${formatNumber(sorted.length)} explicit permission row${sorted.length === 1 ? "" : "s"} for the selected mailbox.`
            : `${formatNumber(sorted.length)} explicit permission row${sorted.length === 1 ? "" : "s"} in view.`;
    }

    renderPaginationBar("permsTablePagination", "permsTable");

    if (pageRows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="4" class="empty-state">No explicit permissions found for the current view.</td></tr>`;
        return;
    }

    tbody.innerHTML = pageRows.map(({ mailbox, permission }) => `
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

    const overThreshold = getMailboxes()
        .filter(mailbox => safeNumber(mailbox.current.usagePercent) >= WARNING_THRESHOLD);

    const sortState = getSortState("thresholdTable");
    const sorted = sortState.key
        ? sortRows("thresholdTable", overThreshold)
        : [...overThreshold].sort((a, b) => safeNumber(b.current.usagePercent) - safeNumber(a.current.usagePercent));

    state.tableData.thresholdTable = sorted;
    renderFilterMeta(sorted.length, overThreshold.length);
    decorateSortableHeaders();

    const pg = state.pagination.thresholdTable;
    const totalPages = Math.max(1, Math.ceil(sorted.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const rows = sorted.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    if (tableMeta) {
        tableMeta.textContent = sorted.length === 0
            ? "No warning or critical mailboxes in the current view."
            : `${formatNumber(sorted.length)} mailbox${sorted.length === 1 ? "" : "es"} at or above ${WARNING_THRESHOLD}% usage.`;
    }

    renderPaginationBar("thresholdTablePagination", "thresholdTable");

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="empty-state">No mailboxes currently over warning/critical thresholds.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(mailbox => {
        const status = safeNumber(mailbox.current.usagePercent) >= CRITICAL_THRESHOLD ? "Critical" : "Warning";
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
    state.tableData.historyTable = sorted;

    const pg = state.pagination.historyTable;
    const totalPages = Math.max(1, Math.ceil(sorted.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const rows = sorted.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    if (tableMeta) {
        tableMeta.textContent = `${formatNumber(sorted.length)} historical snapshot${sorted.length === 1 ? "" : "s"} loaded.`;
    }

    renderPaginationBar("historyTablePagination", "historyTable");

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="4" class="empty-state">No history data available for this mailbox.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(point => `
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
    state.tableData.mailboxSnapshotsTable = history;

    const pg = state.pagination.mailboxSnapshotsTable;
    const totalPages = Math.max(1, Math.ceil(history.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const rows = history.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    meta.textContent = `${formatNumber(history.length)} snapshot${history.length === 1 ? "" : "s"} available.`;

    renderPaginationBar("mailboxSnapshotsTablePagination", "mailboxSnapshotsTable");

    if (!selected || rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="empty-state">Select a mailbox to inspect recent snapshots.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(point => `
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
    state.tableData.mailboxPermissionsTable = permissions;

    const pg = state.pagination.mailboxPermissionsTable;
    const totalPages = Math.max(1, Math.ceil(permissions.length / pg.pageSize));
    pg.page = Math.max(1, Math.min(pg.page, totalPages));
    const rows = permissions.slice((pg.page - 1) * pg.pageSize, pg.page * pg.pageSize);

    meta.textContent = `${formatNumber(permissions.length)} explicit permission row${permissions.length === 1 ? "" : "s"}.`;

    renderPaginationBar("mailboxPermissionsTablePagination", "mailboxPermissionsTable");

    if (!selected || rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="3" class="empty-state">No explicit permissions are available for this mailbox.</td></tr>`;
        return;
    }

    tbody.innerHTML = rows.map(permission => `
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
    const staleCleanupEl = document.getElementById("staleCleanupCount");
    const neverCleanedEl = document.getElementById("neverCleanedCount");
    const licenseGapEl = document.getElementById("licenseGapCount");

    const largest = mailboxes.reduce((winner, mailbox) => {
        if (!winner) return mailbox;
        return safeNumber(winner.current.totalGB) >= safeNumber(mailbox.current.totalGB) ? winner : mailbox;
    }, null);

    if (countEl) countEl.textContent = formatNumber(mailboxes.length);
    if (totalStorageEl) totalStorageEl.textContent = `${formatGB(sumMailboxes(mailboxes, mailbox => mailbox.current.totalGB))} GB`;
    if (totalArchiveEl) totalArchiveEl.textContent = `${formatGB(sumMailboxes(mailboxes, mailbox => mailbox.current.archiveSizeGB))} GB`;
    if (thresholdEl) thresholdEl.textContent = formatNumber(mailboxes.filter(mailbox => safeNumber(mailbox.current.usagePercent) >= WARNING_THRESHOLD).length);
    if (largestEl) largestEl.textContent = largest ? `${largest.displayName} (${formatGB(largest.current.totalGB)} GB)` : "N/A";
    if (staleCleanupEl) {
        staleCleanupEl.textContent = formatNumber(mailboxes.filter(mailbox => isCleanupStale(mailbox)).length);
    }
    if (neverCleanedEl) {
        neverCleanedEl.textContent = formatNumber(mailboxes.filter(mailbox => isNeverCleaned(mailbox)).length);
    }
    if (licenseGapEl) {
        licenseGapEl.textContent = formatNumber(mailboxes.filter(mailbox => mailbox.licensing.licenseRequired === true && mailbox.licensing.hasLicense !== true).length);
    }
}

function drawUsageDonutChart(mailboxes) {
    const totalUsed = sumMailboxes(mailboxes, mailbox => mailbox.current.totalGB);
    let totalQuota = sumMailboxes(mailboxes, mailbox => safeNumber(mailbox.current.quotaGB));
    if (totalQuota <= 0) totalQuota = 1;
    drawRingChart("usageDonutChart", [
        { label: "Used", value: totalUsed, color: getChartColor("primary") },
        { label: "Available", value: Math.max(totalQuota - totalUsed, 0), color: getChartColor("muted") }
    ], [`${((totalUsed / totalQuota) * 100).toFixed(1)}%`, "used quota"]);
}

function drawAlertStatusChart(mailboxes) {
    const healthy = mailboxes.filter(mailbox => safeNumber(mailbox.current.usagePercent) < WARNING_THRESHOLD).length;
    const warning = mailboxes.filter(mailbox => {
        const usage = safeNumber(mailbox.current.usagePercent);
        return usage >= WARNING_THRESHOLD && usage < CRITICAL_THRESHOLD;
    }).length;
    const critical = mailboxes.filter(mailbox => safeNumber(mailbox.current.usagePercent) >= CRITICAL_THRESHOLD).length;

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

    const primary = safeNumber(selected.current.totalGB);
    const archive = safeNumber(selected.current.archiveSizeGB);
    const freeQuota = selected.current.quotaGB == null ? 0 : Math.max(selected.current.quotaGB - primary, 0);

    drawRingChart(canvasId, [
        { label: "Primary", value: primary, color: getChartColor("primary") },
        { label: "Archive", value: archive, color: getChartColor("secondary") },
        { label: "Free quota", value: freeQuota, color: getChartColor("muted") }
    ], [`${formatGB(primary + archive)} GB`, "primary + archive"]);
}

function drawTopStorageChart(mailboxes) {
    const top = [...mailboxes]
        .sort((a, b) => safeNumber(b.current.totalGB) - safeNumber(a.current.totalGB))
        .slice(0, 10);

    drawHorizontalBarChart(
        "topStorageChart",
        top.map(mailbox => ({
            label: truncateLabel(mailbox.displayName || mailbox.primarySmtpAddress, 26),
            value: safeNumber(mailbox.current.totalGB)
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
        const usage = safeNumber(mailbox.current.usagePercent);
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
    const values = sorted.map(point => safeNumber(valueSelector(point)));
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
        const y = getY(safeNumber(valueSelector(point)));
        if (index === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });
    ctx.stroke();

    ctx.fillStyle = color;
    sorted.forEach((point, index) => {
        const x = getX(index);
        const y = getY(safeNumber(valueSelector(point)));
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
    return mailboxes.reduce((sum, mailbox) => {
        const numeric = Number(selector(mailbox));
        return sum + (Number.isFinite(numeric) ? numeric : 0);
    }, 0);
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
            archiveEnabled: incoming.current.archiveEnabled ?? existing.current.archiveEnabled,
            archiveSizeGB: pickValue(incoming.current.archiveSizeGB, existing.current.archiveSizeGB),
            archiveItemCount: pickValue(incoming.current.archiveItemCount, existing.current.archiveItemCount)
        },
        retention: {
            ...existing.retention,
            ...incoming.retention
        },
        licensing: {
            ...existing.licensing,
            ...incoming.licensing
        },
        mailboxMaintenance: {
            ...existing.mailboxMaintenance,
            ...incoming.mailboxMaintenance
        },
        cleanupStatus: incoming.cleanupStatus || existing.cleanupStatus,
        lastCleanupSuccessUtc: incoming.lastCleanupSuccessUtc || existing.lastCleanupSuccessUtc,
        daysSinceSuccessfulCleanup: pickValue(incoming.daysSinceSuccessfulCleanup, existing.daysSinceSuccessfulCleanup),
        permissions: incoming.permissions.length >= existing.permissions.length ? incoming.permissions : existing.permissions
    };
}

function pickValue(primary, fallback) {
    if (primary == null || primary === "") return fallback;
    if (fallback == null || fallback === "") return primary;

    const primaryNumber = toNumber(primary);
    const fallbackNumber = toNumber(fallback);

    if (Number.isFinite(primaryNumber) && Number.isFinite(fallbackNumber)) {
        const primaryIsZero = primaryNumber === 0;
        const fallbackIsZero = fallbackNumber === 0;

        if (primaryIsZero && !fallbackIsZero) return fallback;
        if (!primaryIsZero && fallbackIsZero) return primary;
    }

    return primary;
}

function createEmptyHistoryData() {
    return {
        generatedUtc: null,
        mailboxes: [],
        byGuid: {},
        bySmtp: {}
    };
}

function normaliseRetentionPolicyCatalog(payload) {
    const catalogSource = payload?.RetentionPolicies ?? payload?.retentionPolicies;
    if (!Array.isArray(catalogSource)) return [];

    return catalogSource
        .filter(policy => policy && typeof policy === "object")
        .map(policy => {
            const tagLinks = policy.RetentionPolicyTagLinks ?? policy.retentionPolicyTagLinks;
            return {
                name: String(policy.Name ?? policy.name ?? "").trim(),
                isKnownPolicy: getBoolean(policy, ["IsKnownPolicy", "isKnownPolicy"]),
                mailboxCount: getNumber(policy, ["MailboxCount", "mailboxCount"]) ?? 0,
                isDefaultPolicy: getBoolean(policy, ["IsDefaultPolicy", "isDefaultPolicy"]),
                retentionId: policy.RetentionId ?? policy.retentionId ?? null,
                retentionPolicyTagLinks: Array.isArray(tagLinks) ? tagLinks.map(item => String(item || "")).filter(Boolean) : [],
                tagCount: getNumber(policy, ["TagCount", "tagCount"]) ?? 0,
                comment: policy.Comment ?? policy.comment ?? null
            };
        })
        .filter(policy => policy.name.length > 0)
        .sort((left, right) => safeNumber(right.mailboxCount) - safeNumber(left.mailboxCount) || left.name.localeCompare(right.name));
}

function buildRetentionPolicyCatalogFromMailboxes(mailboxes) {
    const policyIndex = new Map();
    mailboxes.forEach(mailbox => {
        const name = String(mailbox?.retention?.retentionPolicy || "").trim();
        if (!name) return;

        const key = name.toLowerCase();
        if (!policyIndex.has(key)) {
            policyIndex.set(key, {
                name,
                isKnownPolicy: getBoolean(mailbox?.retention?.retentionPolicyDetails || {}, ["isKnownPolicy", "IsKnownPolicy"]),
                mailboxCount: 0,
                isDefaultPolicy: getBoolean(mailbox?.retention?.retentionPolicyDetails || {}, ["isDefaultPolicy", "IsDefaultPolicy"]),
                retentionId: mailbox?.retention?.retentionPolicyDetails?.retentionId ?? mailbox?.retention?.retentionPolicyDetails?.RetentionId ?? null,
                retentionPolicyTagLinks: [],
                tagCount: getNumber(mailbox?.retention?.retentionPolicyDetails || {}, ["tagCount", "TagCount"]) ?? 0,
                comment: mailbox?.retention?.retentionPolicyDetails?.comment ?? mailbox?.retention?.retentionPolicyDetails?.Comment ?? null
            });
        }

        const policy = policyIndex.get(key);
        policy.mailboxCount += 1;
    });

    return Array.from(policyIndex.values())
        .sort((left, right) => right.mailboxCount - left.mailboxCount || left.name.localeCompare(right.name));
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

    const normalisedSamples = samples
        .filter(sample => sample && typeof sample === "object")
        .map(sample => {
            const sizeGb = getNumber(sample, ["SizeGB", "sizeGB", "TotalGB", "totalGB", "StorageGB", "MailboxSizeGB"]) ?? 0;
            const quotaGb = getNumber(sample, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]);
            const usagePercent = getNumber(sample, ["UsagePercent", "usagePercent"]);

            return {
                TimestampUtc: sample.TimestampUtc ?? sample.timestampUtc ?? sample.Timestamp ?? sample.timestamp ?? null,
                PrimarySmtpAddress: sample.PrimarySmtpAddress ?? sample.primarySmtpAddress ?? "",
                DisplayName: sample.DisplayName ?? sample.displayName ?? "",
                SizeGB: sizeGb,
                ItemCount: getNumber(sample, ["ItemCount", "itemCount", "Items"]) ?? 0,
                UsagePercent: usagePercent ?? (quotaGb > 0 ? (sizeGb / quotaGb) * 100 : 0),
                QuotaGB: quotaGb,
                LastLogonTime: sample.LastLogonTime ?? sample.lastLogonTime ?? null,
                ArchiveEnabled: getBoolean(sample, ["ArchiveEnabled", "archiveEnabled"]) ?? false,
                ArchiveSizeGB: getNumber(sample, ["ArchiveSizeGB", "archiveSizeGB"]) ?? 0,
                ArchiveItemCount: getNumber(sample, ["ArchiveItemCount", "archiveItemCount"]) ?? 0
            };
        });

    normalisedSamples.sort((left, right) => {
        const leftTime = left.TimestampUtc ? Date.parse(left.TimestampUtc) : Number.NaN;
        const rightTime = right.TimestampUtc ? Date.parse(right.TimestampUtc) : Number.NaN;

        if (Number.isNaN(leftTime) && Number.isNaN(rightTime)) return 0;
        if (Number.isNaN(leftTime)) return 1;
        if (Number.isNaN(rightTime)) return -1;

        return leftTime - rightTime;
    });

    return normalisedSamples;
}

function normaliseMailbox(source) {
    const rawSamples = Array.isArray(source?.Samples)
        ? source.Samples
        : (Array.isArray(source?.samples) ? source.samples : []);
    const samples = rawSamples.length > 0 ? normaliseHistorySamples(rawSamples) : [];
    const sample = samples.length > 0
        ? samples[samples.length - 1]
        : (source?.current ?? source?.Current ?? {});
    const currentSource = source?.current ?? source?.Current ?? source ?? {};
    const archiveSource = sample?.Archive ?? sample?.archive ?? currentSource?.Archive ?? currentSource?.archive ?? {};

    const displayName = source?.DisplayName ?? source?.displayName ?? source?.MailboxName ?? source?.Mailbox?.DisplayName ?? source?.primarySmtpAddress ?? source?.PrimarySmtpAddress ?? "";
    const primarySmtpAddress = source?.PrimarySmtpAddress ?? source?.primarySmtpAddress ?? source?.SmtpAddress ?? source?.UserPrincipalName ?? source?.Mailbox?.PrimarySmtpAddress ?? "";
    const permissions = normalisePermissions(
        source?.permissions ??
        source?.Permissions ??
        source?.CurrentPermissions ??
        sample?.permissions ??
        sample?.Permissions
    );

    const totalGB = getNumber(sample, ["SizeGB", "sizeGB", "TotalGB", "totalGB", "StorageGB", "TotalItemSizeGB", "MailboxSizeGB"]) ??
        getNumber(currentSource, ["totalGB", "TotalGB", "SizeGB", "sizeGB", "StorageGB", "TotalItemSizeGB", "MailboxSizeGB"]) ??
        0;
    const quotaGB = getNumber(sample, ["QuotaGB", "quotaGB", "ProhibitSendReceiveQuotaGB"]) ??
        getNumber(currentSource, ["quotaGB", "QuotaGB", "ProhibitSendReceiveQuotaGB", "ProhibitSendQuotaGB"]) ??
        parseStorageValueInGb(currentSource?.ProhibitSendReceiveQuota ?? currentSource?.prohibitSendReceiveQuota ?? currentSource?.ProhibitSendQuota ?? currentSource?.prohibitSendQuota) ??
        null;
    const usagePercent = getNumber(sample, ["UsagePercent", "usagePercent"]) ??
        getNumber(currentSource, ["usagePercent", "UsagePercent"]) ??
        (quotaGB > 0 ? (totalGB / quotaGB) * 100 : 0);
    const archiveEnabled = getBoolean(sample, ["ArchiveEnabled", "archiveEnabled"]) ??
        getBoolean(currentSource, ["ArchiveEnabled", "archiveEnabled"]) ??
        (getNumber(archiveSource, ["TotalGB", "totalGB", "ArchiveSizeGB", "archiveSizeGB"]) ?? 0) > 0;

    const retention = normaliseRetentionProfile(source);
    const licensing = normaliseLicensingProfile(source);
    const mailboxMaintenance = normaliseMaintenanceProfile(source);
    const retentionPolicyChangeHistory = normaliseRetentionPolicyChangeHistory(source);
    const licenseAssignmentHistory = normaliseLicenseAssignmentHistory(source);

    return {
        exchangeGuid: String(source?.ExchangeGuid ?? source?.exchangeGuid ?? ""),
        displayName: String(displayName || primarySmtpAddress || source?.ExchangeGuid || "Unknown mailbox"),
        primarySmtpAddress: String(primarySmtpAddress || ""),
        current: {
            totalGB,
            itemCount: getNumber(sample, ["ItemCount", "itemCount", "Items"]) ??
                getNumber(currentSource, ["itemCount", "ItemCount", "Items"]) ??
                0,
            quotaGB,
            usagePercent,
            lastLogonTime: sample?.LastLogonTime ?? sample?.lastLogonTime ??
                currentSource?.LastLogonTime ?? currentSource?.lastLogonTime ??
                currentSource?.lastLogonTime ?? null,
            archiveEnabled,
            archiveSizeGB: getNumber(sample, ["ArchiveSizeGB", "archiveSizeGB"]) ??
                getNumber(currentSource, ["archiveSizeGB", "ArchiveSizeGB"]) ??
                getNumber(archiveSource, ["TotalGB", "totalGB", "ArchiveSizeGB", "archiveSizeGB"]) ??
                0,
            archiveItemCount: getNumber(sample, ["ArchiveItemCount", "archiveItemCount"]) ??
                getNumber(currentSource, ["archiveItemCount", "ArchiveItemCount"]) ??
                getNumber(archiveSource, ["ItemCount", "itemCount"]) ??
                0
        },
        retention,
        licensing,
        mailboxMaintenance,
        retentionPolicyChangeHistory,
        licenseAssignmentHistory,
        cleanupStatus: mailboxMaintenance.cleanupStatus,
        lastCleanupSuccessUtc: mailboxMaintenance.lastCleanupSuccessUtc,
        daysSinceSuccessfulCleanup: mailboxMaintenance.daysSinceSuccessfulCleanup,
        permissions
    };
}

function normaliseRetentionPolicyChangeHistory(source) {
    const history = source?.RetentionPolicyChangeHistory ?? source?.retentionPolicyChangeHistory;
    if (!Array.isArray(history)) return [];
    return history
        .filter(item => item && typeof item === "object")
        .map(item => ({
            timestampUtc: item.TimestampUtc ?? item.timestampUtc ?? null,
            retentionPolicy: item.RetentionPolicy ?? item.retentionPolicy ?? null
        }))
        .filter(item => item.timestampUtc)
        .sort((left, right) => new Date(left.timestampUtc) - new Date(right.timestampUtc));
}

function normaliseLicenseAssignmentHistory(source) {
    const history = source?.LicenseAssignmentHistory ?? source?.licenseAssignmentHistory;
    if (!Array.isArray(history)) return [];
    return history
        .filter(item => item && typeof item === "object")
        .map(item => ({
            timestampUtc: item.TimestampUtc ?? item.timestampUtc ?? null,
            hasLicense: getBoolean(item, ["HasLicense", "hasLicense"]),
            licenseRequired: getBoolean(item, ["LicenseRequired", "licenseRequired"]),
            licenseType: item.LicenseType ?? item.licenseType ?? null
        }))
        .filter(item => item.timestampUtc)
        .sort((left, right) => new Date(left.timestampUtc) - new Date(right.timestampUtc));
}

function normaliseRetentionProfile(source) {
    const retentionSource = source?.retention ?? source?.Retention ?? {};
    const inPlaceHolds = retentionSource.InPlaceHolds ?? retentionSource.inPlaceHolds;
    const retentionPolicyDetailsSource = retentionSource.RetentionPolicyDetails ?? retentionSource.retentionPolicyDetails ?? {};
    return {
        retentionPolicy: retentionSource.RetentionPolicy ?? retentionSource.retentionPolicy ?? source?.RetentionPolicy ?? source?.retentionPolicy ?? null,
        retentionHoldEnabled: getBoolean(retentionSource, ["RetentionHoldEnabled", "retentionHoldEnabled"]) ?? getBoolean(source, ["RetentionHoldEnabled", "retentionHoldEnabled"]),
        litigationHoldEnabled: getBoolean(retentionSource, ["LitigationHoldEnabled", "litigationHoldEnabled"]) ?? getBoolean(source, ["LitigationHoldEnabled", "litigationHoldEnabled"]),
        litigationHoldDurationDays: getNumber(retentionSource, ["LitigationHoldDurationDays", "litigationHoldDurationDays"]) ?? getNumber(source, ["LitigationHoldDurationDays", "litigationHoldDurationDays"]),
        inPlaceHolds: Array.isArray(inPlaceHolds) ? inPlaceHolds.map(item => String(item || "")).filter(Boolean) : [],
        singleItemRecoveryEnabled: getBoolean(retentionSource, ["SingleItemRecoveryEnabled", "singleItemRecoveryEnabled"]) ?? getBoolean(source, ["SingleItemRecoveryEnabled", "singleItemRecoveryEnabled"]),
        retainDeletedItemsFor: retentionSource.RetainDeletedItemsFor ?? retentionSource.retainDeletedItemsFor ?? null,
        retentionPolicyDetails: {
            name: retentionPolicyDetailsSource.Name ?? retentionPolicyDetailsSource.name ?? null,
            isKnownPolicy: getBoolean(retentionPolicyDetailsSource, ["IsKnownPolicy", "isKnownPolicy"]),
            mailboxCount: getNumber(retentionPolicyDetailsSource, ["MailboxCount", "mailboxCount"]),
            isDefaultPolicy: getBoolean(retentionPolicyDetailsSource, ["IsDefaultPolicy", "isDefaultPolicy"]),
            retentionId: retentionPolicyDetailsSource.RetentionId ?? retentionPolicyDetailsSource.retentionId ?? null,
            tagCount: getNumber(retentionPolicyDetailsSource, ["TagCount", "tagCount"]),
            comment: retentionPolicyDetailsSource.Comment ?? retentionPolicyDetailsSource.comment ?? null
        }
    };
}

function normaliseLicensingProfile(source) {
    const licensingSource = source?.licensing ?? source?.Licensing ?? {};
    const capabilities = licensingSource.PersistedCapabilities ?? licensingSource.persistedCapabilities;
    const recipientTypeDetails = licensingSource.RecipientTypeDetails ??
        licensingSource.recipientTypeDetails ??
        source?.RecipientTypeDetails ??
        source?.recipientTypeDetails ??
        null;

    const inferredLicenseRequired = inferLicenseRequired(recipientTypeDetails, getBoolean(licensingSource, ["IsInactiveMailbox", "isInactiveMailbox"]));
    const hasLicenseFromSource = getBoolean(licensingSource, ["HasLicense", "hasLicense"]);
    const inferredHasLicense = hasLicenseFromSource ?? (getBoolean(licensingSource, ["SKUAssigned", "skuAssigned"]) === true || (Array.isArray(capabilities) && capabilities.length > 0));
    const licenseTypes = Array.isArray(licensingSource.LicenseTypes ?? licensingSource.licenseTypes)
        ? (licensingSource.LicenseTypes ?? licensingSource.licenseTypes).map(item => String(item || "")).filter(Boolean)
        : (Array.isArray(capabilities) ? capabilities.map(item => String(item || "")).filter(Boolean) : []);

    return {
        recipientTypeDetails,
        isSharedMailbox: getBoolean(licensingSource, ["IsSharedMailbox", "isSharedMailbox"]) ?? (recipientTypeDetails === "SharedMailbox"),
        skuAssigned: getBoolean(licensingSource, ["SKUAssigned", "skuAssigned"]),
        persistedCapabilities: Array.isArray(capabilities) ? capabilities.map(item => String(item || "")).filter(Boolean) : [],
        archiveStatus: licensingSource.ArchiveStatus ?? licensingSource.archiveStatus ?? null,
        isInactiveMailbox: getBoolean(licensingSource, ["IsInactiveMailbox", "isInactiveMailbox"]),
        licenseRequired: getBoolean(licensingSource, ["LicenseRequired", "licenseRequired"]) ?? inferredLicenseRequired,
        hasLicense: inferredHasLicense,
        licenseTypes,
        licenseType: licensingSource.LicenseType ?? licensingSource.licenseType ?? (licenseTypes.length > 0 ? licenseTypes.join(", ") : null),
        isLicenseCompliant: getBoolean(licensingSource, ["IsLicenseCompliant", "isLicenseCompliant"]) ?? ((inferredLicenseRequired !== true) || inferredHasLicense === true),
        licenseRequirementReason: licensingSource.LicenseRequirementReason ?? licensingSource.licenseRequirementReason ?? getDefaultLicenseRequirementReason(recipientTypeDetails, inferredLicenseRequired)
    };
}

function normaliseMaintenanceProfile(source) {
    const maintenanceSource = source?.mailboxMaintenance ?? source?.MailboxMaintenance ?? {};
    return {
        lastCleanupAttemptUtc: maintenanceSource.LastCleanupAttemptUtc ?? maintenanceSource.lastCleanupAttemptUtc ?? null,
        lastCleanupSuccessUtc: maintenanceSource.LastCleanupSuccessUtc ??
            maintenanceSource.lastCleanupSuccessUtc ??
            source?.LastCleanupSuccessUtc ??
            source?.lastCleanupSuccessUtc ??
            null,
        cleanupStatus: maintenanceSource.CleanupStatus ??
            maintenanceSource.cleanupStatus ??
            source?.CleanupStatus ??
            source?.cleanupStatus ??
            "Unknown",
        daysSinceSuccessfulCleanup: getNumber(maintenanceSource, ["DaysSinceSuccessfulCleanup", "daysSinceSuccessfulCleanup"]) ??
            getNumber(source, ["DaysSinceSuccessfulCleanup", "daysSinceSuccessfulCleanup"]),
        cleanupVersion: maintenanceSource.CleanupVersion ?? maintenanceSource.cleanupVersion ?? null,
        lastProcessedBy: maintenanceSource.LastProcessedBy ?? maintenanceSource.lastProcessedBy ?? null,
        correlationId: maintenanceSource.CorrelationId ?? maintenanceSource.correlationId ?? null,
        notes: maintenanceSource.Notes ?? maintenanceSource.notes ?? null
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
            IsInherited: getBoolean(permission, ["IsInherited", "isInherited"]) ?? false,
            Deny: getBoolean(permission, ["Deny", "deny"]) ?? false
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
        .sort((left, right) => right.score - left.score || safeNumber(right.mailbox.current.totalGB) - safeNumber(left.mailbox.current.totalGB));

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
    const totalGb = Number(mailbox?.current?.totalGB);
    score += Math.min(Number.isFinite(totalGb) ? totalGb : 0, 500) / 10;
    return score;
}

function isMailboxRenderable(mailbox) {
    return Boolean(mailbox && (mailbox.primarySmtpAddress || mailbox.exchangeGuid || mailbox.displayName));
}

// ExchangeGuid is the durable identity; SMTP addresses change and must never key a record.
function getMailboxKey(mailbox) {
    return String(mailbox.exchangeGuid || mailbox.primarySmtpAddress || mailbox.displayName || "").toLowerCase();
}

function getMailboxSearchLabel(mailbox) {
    return mailbox.primarySmtpAddress || mailbox.displayName || mailbox.exchangeGuid;
}

function buildMailboxUrl(pageName, mailbox) {
    const url = new URL(pageName, window.location.href);
    if (mailbox) {
        url.searchParams.set("mailbox", mailbox.exchangeGuid || mailbox.primarySmtpAddress);
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
    // Still matches an SMTP address so links bookmarked before the switch keep working.
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
        url.searchParams.set("mailbox", mailboxOrNull.exchangeGuid || mailboxOrNull.primarySmtpAddress);
    }

    const method = replace ? "replaceState" : "pushState";
    window.history[method]({}, "", `${url.pathname.split("/").pop()}${url.search}`);
}

function updateNavLinks() {
    const selected = getSelectedMailbox();
    const scopeId = state.activeScopeId;
    const activeSort = getActiveSortForPage();

    document.querySelectorAll("nav.view-nav a").forEach(link => {
        const url = new URL(link.getAttribute("href"), window.location.href);
        if (selected) {
            url.searchParams.set("mailbox", selected.exchangeGuid || selected.primarySmtpAddress);
        } else {
            url.searchParams.delete("mailbox");
        }

        // Carry the scope across pages so a scoped report stays scoped.
        if (scopeId && scopeId !== ALL_SCOPE.id && !isScopePinned()) {
            url.searchParams.set("scope", scopeId);
        } else {
            url.searchParams.delete("scope");
        }

        // Carry the filter and sort so a narrowed result set survives navigation.
        if (state.filterQuery) {
            url.searchParams.set("q", state.filterQuery);
        } else {
            url.searchParams.delete("q");
        }

        if (activeSort?.key) {
            url.searchParams.set("sort", activeSort.key);
            url.searchParams.set("dir", activeSort.direction);
        } else {
            url.searchParams.delete("sort");
            url.searchParams.delete("dir");
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
        const parsed = toNumber(record?.[propertyName]);
        if (parsed !== null) return parsed;
    }
    return null;
}

function toNumber(value) {
    if (value === undefined || value === null || value === "") return null;

    if (typeof value === "number") {
        if (!Number.isFinite(value)) return null;
        return Math.abs(value) >= 1_000_000 ? value / (1024 ** 3) : value;
    }

    if (typeof value === "bigint") {
        return Number(value) >= 1_000_000 ? Number(value) / (1024 ** 3) : Number(value);
    }

    const source = String(value).trim();
    if (source === "") return null;
    if (/^(unlimited|n\/a|not available|null|none)$/i.test(source)) return null;

    const percentMatch = source.match(/^([-+]?\d+(?:\.\d+)?)\s*%$/i);
    if (percentMatch) {
        return Number(percentMatch[1]);
    }

    const directNumber = Number(source);
    if (Number.isFinite(directNumber)) {
        const numericValue = Number(source.replace(/,/g, ""));
        const isLikelyByteCount = /^\d{4,}(?:\.\d+)?$/.test(source.replace(/,/g, "")) && Math.abs(numericValue) >= 1_000_000;
        if (isLikelyByteCount) {
            return numericValue / (1024 ** 3);
        }
        return directNumber;
    }

    const storageValue = parseStorageValueInGb(source);
    if (storageValue !== null) return storageValue;

    const bytesValue = parseByteCount(source);
    if (bytesValue !== null) return bytesValue / (1024 ** 3);

    return null;
}

function parseByteCount(value) {
    if (value == null || value === "") return null;

    const text = String(value).trim();
    if (!text) return null;

    const pureNumeric = text.replace(/,/g, "");
    if (/^\d+(?:\.\d+)?$/.test(pureNumeric)) {
        const numericValue = Number(pureNumeric);
        if (Number.isFinite(numericValue) && Math.abs(numericValue) >= 1_000_000) {
            return numericValue;
        }
        return null;
    }

    const match = text.match(/([\d,]+(?:\.\d+)?)\s*(?:bytes?|B)\b/i);
    if (!match) return null;

    const numericValue = Number(match[1].replace(/,/g, ""));
    return Number.isFinite(numericValue) ? numericValue : null;
}

function getBoolean(record, propertyNames) {
    for (const propertyName of propertyNames) {
        const value = record?.[propertyName];
        if (value === undefined || value === null || value === "") {
            continue;
        }
        if (typeof value === "boolean") {
            return value;
        }
        const text = String(value).trim().toLowerCase();
        if (text === "true") {
            return true;
        }
        if (text === "false") {
            return false;
        }
    }
    return null;
}

function parseStorageValueInGb(value) {
    if (value == null || value === "") return null;

    const text = String(value).trim();
    if (text === "") return null;
    if (/^(unlimited|n\/a|not available|null|none)$/i.test(text)) return null;

    const percentMatch = text.match(/^([-+]?\d+(?:\.\d+)?)\s*%$/i);
    if (percentMatch) {
        return Number(percentMatch[1]);
    }

    const directNumber = Number(text.replace(/[%]/g, ""));
    if (Number.isFinite(directNumber)) {
        const numericValue = Number(text.replace(/[%]/g, "").replace(/,/g, ""));
        const isLikelyByteCount = /^\d{4,}(?:\.\d+)?$/.test(text.replace(/[%]/g, "").replace(/,/g, "")) && Math.abs(numericValue) >= 1_000_000;
        if (isLikelyByteCount) {
            return Number((numericValue / (1024 ** 3)).toFixed(2));
        }
        return Number(directNumber.toFixed(2));
    }

    const bytesMatch = text.match(/\(([^)]+)\s+bytes\)/i) || text.match(/([\d,]+(?:\.\d+)?)\s*(?:bytes|B)\b/i);
    if (bytesMatch) {
        const byteCount = Number((bytesMatch[1] ?? bytesMatch[0]).replace(/,/g, ""));
        if (Number.isFinite(byteCount)) {
            return Number((byteCount / (1024 ** 3)).toFixed(2));
        }
    }

    const unitMatch = text.match(/([\d,]+(?:\.\d+)?)\s*(KB|MB|GB|TB)\b/i);
    if (!unitMatch) return null;

    const amount = Number(unitMatch[1].replace(/,/g, ""));
    if (!Number.isFinite(amount)) return null;

    const unit = unitMatch[2].toUpperCase();
    const multiplier = {
        KB: 1 / (1024 ** 2),
        MB: 1 / 1024,
        GB: 1,
        TB: 1024
    }[unit];

    return multiplier == null ? null : Number((amount * multiplier).toFixed(2));
}

function truncateLabel(text, maxLength) {
    const value = String(text || "");
    return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value;
}

function formatGB(value) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric.toFixed(2) : "0.00";
}

function formatPercent(value) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? `${numeric.toFixed(1)}%` : "0.0%";
}

function safeNumber(value, fallback = 0) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric : fallback;
}

function formatCompactNumber(value) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(numeric) : "0";
}

function formatNumber(value) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric.toLocaleString() : "0";
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

function getChangeAgeLabel(changeHistory) {
    if (!Array.isArray(changeHistory) || changeHistory.length === 0) return "Unknown";
    const latest = changeHistory[changeHistory.length - 1];
    const changedUtc = latest?.timestampUtc;
    if (!changedUtc) return "Unknown";
    const changedDate = new Date(changedUtc);
    if (Number.isNaN(changedDate.getTime())) return "Unknown";
    const days = Math.max(0, Math.floor((Date.now() - changedDate.getTime()) / 86400000));
    return `${days} day${days === 1 ? "" : "s"} ago`;
}

function inferLicenseRequired(recipientTypeDetails, isInactiveMailbox) {
    if (isInactiveMailbox === true) {
        return false;
    }

    const unlicensedTypes = new Set([
        "sharedmailbox",
        "roommailbox",
        "equipmentmailbox",
        "discoverymailbox",
        "publicfoldermailbox",
        "groupmailbox",
        "schedulingmailbox",
        "teammailbox",
        "auditlogmailbox",
        "arbitrationmailbox"
    ]);

    const normalizedType = String(recipientTypeDetails || "").trim().toLowerCase();
    if (!normalizedType) return true;
    return !unlicensedTypes.has(normalizedType);
}

function getDefaultLicenseRequirementReason(recipientTypeDetails, licenseRequired) {
    if (licenseRequired === false) {
        return recipientTypeDetails
            ? `Recipient type '${recipientTypeDetails}' is typically unlicensed.`
            : "Recipient type is typically unlicensed.";
    }
    return recipientTypeDetails
        ? `Recipient type '${recipientTypeDetails}' is expected to require mailbox licensing.`
        : "Mailbox licensing is expected to be required.";
}

function getLicenseStatusLabel(mailbox) {
    if (!mailbox) return "Unknown";
    const required = mailbox.licensing.licenseRequired;
    const hasLicense = mailbox.licensing.hasLicense;
    const type = mailbox.licensing.licenseType;

    if (required === true && hasLicense === true) {
        return type ? `Assigned (${type})` : "Assigned";
    }
    if (required === true && hasLicense !== true) {
        return "Missing required license";
    }
    if (required === false && hasLicense === true) {
        return type ? `Optional (${type})` : "Optional";
    }
    if (required === false) {
        return "Not required";
    }
    return hasLicense === true ? "Assigned" : "Unknown";
}

function licenseBadge(mailbox) {
    const label = getLicenseStatusLabel(mailbox);
    if (label === "Missing required license") {
        return `<span class="badge danger">${escapeHtml(label)}</span>`;
    }
    if (label === "Not required" || label.startsWith("Optional")) {
        return `<span class="badge">${escapeHtml(label)}</span>`;
    }
    if (label === "Assigned" || label.startsWith("Assigned")) {
        return `<span class="badge success">${escapeHtml(label)}</span>`;
    }
    return `<span class="badge warning">${escapeHtml(label)}</span>`;
}

function formatRetentionPolicyProperties(policy) {
    if (!policy) return "";
    const parts = [];
    if (policy.retentionId) parts.push(`ID: ${policy.retentionId}`);
    if (Array.isArray(policy.retentionPolicyTagLinks) && policy.retentionPolicyTagLinks.length > 0) {
        parts.push(`Tags: ${policy.retentionPolicyTagLinks.join(", ")}`);
    }
    if (policy.comment) parts.push(policy.comment);
    if (parts.length === 0) {
        return policy.isKnownPolicy === false ? "Discovered from mailbox assignment only." : "No additional properties returned.";
    }
    return parts.join(" | ");
}

function usageBadge(percent) {
    const value = safeNumber(percent);
    if (value >= CRITICAL_THRESHOLD) return `<span class="badge danger">${formatPercent(value)}</span>`;
    if (value >= WARNING_THRESHOLD) return `<span class="badge warning">${formatPercent(value)}</span>`;
    return formatPercent(value);
}

function formatBooleanState(value) {
    if (value === true) return "Enabled";
    if (value === false) return "Disabled";
    return "Unknown";
}

function isNeverCleaned(mailbox) {
    return !mailbox?.mailboxMaintenance?.lastCleanupSuccessUtc;
}

function isCleanupStale(mailbox) {
    const days = Number(mailbox?.mailboxMaintenance?.daysSinceSuccessfulCleanup);
    return Number.isFinite(days) && days > CLEANUP_WARNING_DAYS;
}

function getCleanupStatusLabel(mailbox) {
    if (!mailbox) return "Unknown";
    const status = String(mailbox.mailboxMaintenance?.cleanupStatus || mailbox.cleanupStatus || "Unknown");
    const days = Number(mailbox.mailboxMaintenance?.daysSinceSuccessfulCleanup ?? mailbox.daysSinceSuccessfulCleanup);
    if (!mailbox.mailboxMaintenance?.lastCleanupSuccessUtc) {
        return "Never Cleaned";
    }
    if (Number.isFinite(days) && days > CLEANUP_WARNING_DAYS) {
        return `Cleanup > ${CLEANUP_WARNING_DAYS} Days`;
    }
    return status;
}

function cleanupBadge(mailbox) {
    const label = getCleanupStatusLabel(mailbox);
    if (label === "Never Cleaned") {
        return `<span class="badge warning">${escapeHtml(label)}</span>`;
    }
    if (label === "Cleanup Failed" || label.toLowerCase() === "failed") {
        return `<span class="badge danger">${escapeHtml(label)}</span>`;
    }
    if (label.startsWith("Cleanup >")) {
        return `<span class="badge warning">${escapeHtml(label)}</span>`;
    }
    return `<span class="badge success">${escapeHtml(label)}</span>`;
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

/* ═══════════════════════════════════════════════════════════════
   MAILBOX SCOPES
═══════════════════════════════════════════════════════════════ */

const SCOPES_URL = "scopes.json";
const ALL_SCOPE = { id: "all", name: "All Mailboxes", description: "Every mailbox in the dataset.", rules: {} };

async function ensureScopesLoaded() {
    if (state.scopes.length) return;

    try {
        const response = await fetch(SCOPES_URL, { cache: "no-store" });
        if (!response.ok) throw new Error(`Could not load ${SCOPES_URL}`);

        const config = await response.json();
        const defined = Array.isArray(config.scopes) ? config.scopes.filter(s => s && s.id) : [];

        state.scopes = defined.length ? defined : [ALL_SCOPE];
        state.activeScopeId = resolveRequestedScopeId(config.defaultScope);
    } catch (err) {
        console.warn("Scope config unavailable, showing all mailboxes:", err.message);
        state.scopes = [ALL_SCOPE];
        state.activeScopeId = ALL_SCOPE.id;
    }

    buildScopeSelector();
}

// A page can pin its scope with <body data-scope="..."> so a site report needs no query string.
function resolveRequestedScopeId(configuredDefault) {
    const pinned = document.body?.dataset?.scope;
    const requested = new URL(window.location.href).searchParams.get("scope");
    const candidates = [pinned, requested, configuredDefault, state.scopes[0]?.id];

    for (const candidate of candidates) {
        if (candidate && state.scopes.some(s => s.id === candidate)) return candidate;
    }
    return state.scopes[0]?.id || ALL_SCOPE.id;
}

function isScopePinned() {
    return Boolean(document.body?.dataset?.scope);
}

function getActiveScope() {
    return state.scopes.find(s => s.id === state.activeScopeId) || ALL_SCOPE;
}

function applyScopeFilter(mailboxes, scope) {
    const rules = scope?.rules;
    if (!rules || !Object.keys(rules).length) return mailboxes;
    return mailboxes.filter(mailbox => matchesScope(mailbox, rules));
}

function matchesScope(mailbox, rules) {
    const smtp = String(mailbox.primarySmtpAddress || "").toLowerCase();
    const name = String(mailbox.displayName || "").toLowerCase();
    const guid = String(mailbox.exchangeGuid || "").toLowerCase();
    const current = mailbox.current || {};
    const totalGb = toNumber(current.totalGB);
    const usagePercent = toNumber(current.usagePercent);

    if (matchesAnyPattern(smtp, rules.excludeSmtp)) return false;
    if (matchesAnyPattern(name, rules.excludeDisplayName)) return false;

    if (Number.isFinite(rules.minSizeGB) && Number.isFinite(totalGb) && totalGb < rules.minSizeGB) return false;
    if (Number.isFinite(rules.minUsagePercent) && Number.isFinite(usagePercent) && usagePercent < rules.minUsagePercent) return false;

    const hasIncludeRules =
        (rules.includeGuids?.length || 0) +
        (rules.includeSmtp?.length || 0) +
        (rules.includeDisplayName?.length || 0) > 0;

    if (!hasIncludeRules) return true;

    if (rules.includeGuids?.some(g => String(g).toLowerCase() === guid)) return true;
    if (matchesAnyPattern(smtp, rules.includeSmtp)) return true;
    if (matchesAnyPattern(name, rules.includeDisplayName)) return true;

    return false;
}

function matchesAnyPattern(value, patterns) {
    if (!Array.isArray(patterns) || !patterns.length || !value) return false;
    return patterns.some(pattern => matchesPattern(value, pattern));
}

function matchesPattern(value, pattern) {
    const raw = String(pattern || "");
    if (!raw) return false;

    if (raw.toLowerCase().startsWith("re:")) {
        try {
            return new RegExp(raw.slice(3), "i").test(value);
        } catch {
            return false;
        }
    }

    const escaped = raw.toLowerCase().replace(/[.+^${}()|[\]\\]/g, "\\$&");
    const expression = `^${escaped.replace(/\*/g, ".*").replace(/\?/g, ".")}$`;
    try {
        return new RegExp(expression).test(value);
    } catch {
        return false;
    }
}

function buildScopeSelector() {
    const host = document.querySelector(".header-actions");
    if (!host || document.getElementById("scopeSelect")) return;
    if (state.scopes.length < 2 || isScopePinned()) return;

    const select = document.createElement("select");
    select.id = "scopeSelect";
    select.className = "theme-select scope-select";
    select.title = "Limit this report to a group of mailboxes";

    state.scopes.forEach(scope => {
        const option = document.createElement("option");
        option.value = scope.id;
        option.textContent = scope.name || scope.id;
        if (scope.description) option.title = scope.description;
        select.appendChild(option);
    });

    select.value = state.activeScopeId;
    select.addEventListener("change", () => {
        state.activeScopeId = select.value;
        clearMailboxSelection();
        updateScopeQueryParam(state.activeScopeId);
        loadDashboard().catch(showError);
    });

    host.insertBefore(select, host.firstChild);
}

function updateScopeQueryParam(scopeId) {
    const url = new URL(window.location.href);
    if (!scopeId || scopeId === ALL_SCOPE.id) {
        url.searchParams.delete("scope");
    } else {
        url.searchParams.set("scope", scopeId);
    }
    window.history.replaceState({}, "", `${url.pathname.split("/").pop()}${url.search}`);
}

function renderScopeIndicator() {
    const banner = document.getElementById("scopeBanner");
    if (!banner) return;

    const scope = getActiveScope();
    const { total, inScope } = state.scopeCounts;
    const isFiltered = inScope !== total;

    banner.hidden = false;
    banner.innerHTML = `
        <div class="scope-banner-main">
            <span class="scope-banner-name">${escapeHtml(scope.name || scope.id)}</span>
            <span class="scope-banner-count">${inScope.toLocaleString()}${isFiltered ? ` of ${total.toLocaleString()}` : ""} mailboxes</span>
        </div>
        ${scope.description ? `<p class="scope-banner-description">${escapeHtml(scope.description)}</p>` : ""}
    `;
}

/* ═══════════════════════════════════════════════════════════════
   THEME SYSTEM
═══════════════════════════════════════════════════════════════ */

function initThemeSelector() {
    const sel = document.getElementById("themeSelect");
    if (!sel) return;

    renderThemeOptions(sel);

    const savedId = localStorage.getItem("dashboardThemeId") || "default-light";
    sel.value = savedId;
    applyThemeById(savedId);

    sel.addEventListener("change", () => applyThemeById(sel.value));

    // Themes from themes.json arrive asynchronously; re-render once they land.
    loadCustomThemes().then(() => {
        const current = sel.value;
        renderThemeOptions(sel);
        sel.value = AVAILABLE_THEMES.some(t => t.id === savedId) ? savedId : current;
        applyThemeById(sel.value);
    });
}

function renderThemeOptions(sel) {
    sel.innerHTML = "";
    AVAILABLE_THEMES.forEach(theme => {
        const opt = document.createElement("option");
        opt.value = theme.id;
        opt.textContent = theme.name;
        sel.appendChild(opt);
    });
}

const CUSTOM_THEMES_URL = "theme/themes.json";
let customThemesPromise = null;

function loadCustomThemes() {
    if (customThemesPromise) return customThemesPromise;

    customThemesPromise = fetch(CUSTOM_THEMES_URL, { cache: "no-store" })
        .then(response => {
            if (!response.ok) throw new Error(`Could not load ${CUSTOM_THEMES_URL}`);
            return response.json();
        })
        .then(config => {
            const themes = Array.isArray(config.themes) ? config.themes : [];
            themes.forEach(theme => {
                if (!theme?.id || !theme.colors) return;
                if (AVAILABLE_THEMES.some(t => t.id === theme.id)) return;
                AVAILABLE_THEMES.push({
                    id: theme.id,
                    name: theme.name || theme.id,
                    file: null,
                    baseTheme: theme.type === "light" ? "light" : "dark",
                    colors: theme.colors
                });
            });
        })
        .catch(err => console.warn("Custom themes unavailable:", err.message));

    return customThemesPromise;
}

// Maps the friendly colour names in themes.json onto the stylesheet variables.
function applyNativeTheme(theme) {
    const root = document.documentElement;
    const c = theme.colors;

    root.setAttribute("data-theme", theme.baseTheme);

    const MAPPING = {
        "--bg-color": c.bg,
        "--panel-bg": c.panel,
        "--panel-alt-bg": c.panelAlt,
        "--text-primary": c.textPrimary,
        "--text-secondary": c.textSecondary,
        "--border-color": c.border,
        "--header-text": c.headerText,
        "--nav-link": c.navLink,
        "--nav-link-hover": c.navLinkHover,
        "--chart-primary": c.chartPrimary,
        "--chart-secondary": c.chartSecondary,
        "--chart-success": c.chartSuccess,
        "--chart-warning": c.chartWarning,
        "--chart-danger": c.chartDanger,
        "--chart-muted": c.chartMuted
    };

    Object.entries(MAPPING).forEach(([cssVar, value]) => {
        if (value) root.style.setProperty(cssVar, value);
    });

    const from = c.headerFrom || c.panel;
    const to = c.headerTo || from;
    if (from) {
        root.style.setProperty("--header-bg", from === to ? from : `linear-gradient(135deg, ${from}, ${to})`);
    }

    root.style.setProperty("--shadow", theme.baseTheme === "dark"
        ? "0 18px 42px rgba(0,0,0,0.45)"
        : "0 18px 42px rgba(14,40,74,0.1)");
}

async function applyThemeById(themeId) {
    const theme = AVAILABLE_THEMES.find(t => t.id === themeId) || AVAILABLE_THEMES[0];

    if (theme.colors) {
        clearAppliedThemeVars();
        applyNativeTheme(theme);
        localStorage.setItem("dashboardThemeId", theme.id);
        localStorage.setItem("dashboardTheme", theme.baseTheme);
        return;
    }

    if (!theme.file) {
        clearAppliedThemeVars();
        document.documentElement.setAttribute("data-theme", theme.baseTheme);
        localStorage.setItem("dashboardThemeId", themeId);
        localStorage.setItem("dashboardTheme", theme.baseTheme);
        applyFilter({ keepPagination: true });
        return;
    }

    try {
        const response = await fetch(theme.file, { cache: "force-cache" });
        if (!response.ok) throw new Error(`Could not load ${theme.file}`);
        const { type, colors } = parseJsoncColors(await response.text());
        applyVSCodeTheme({ type, colors });
        localStorage.setItem("dashboardThemeId", themeId);
        localStorage.setItem("dashboardTheme", type);
        applyFilter({ keepPagination: true });
    } catch (err) {
        console.warn("Theme load failed:", err.message);
    }
}

function clearAppliedThemeVars() {
    ["--bg-color","--panel-bg","--panel-alt-bg","--text-primary","--text-secondary",
     "--border-color","--header-bg","--header-text","--nav-link","--nav-link-hover",
     "--shadow","--chart-primary","--chart-secondary","--chart-success",
     "--chart-warning","--chart-danger","--chart-muted"]
        .forEach(v => document.documentElement.style.removeProperty(v));
}

function parseJsoncColors(text) {
    let result = "";
    let inString = false;
    let i = 0;
    while (i < text.length) {
        if (inString) {
            if (text[i] === "\\" && i + 1 < text.length) { result += text[i] + text[i + 1]; i += 2; continue; }
            if (text[i] === "\"") inString = false;
            result += text[i++];
        } else {
            if (text[i] === "\"") { inString = true; result += text[i++]; continue; }
            if (text[i] === "/" && text[i + 1] === "/") { while (i < text.length && text[i] !== "\n") i++; continue; }
            if (text[i] === "/" && text[i + 1] === "*") { while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i += 2; continue; }
            result += text[i++];
        }
    }
    result = result.replace(/,(\s*[}\]])/g, "$1");
    try {
        const parsed = JSON.parse(result);
        return { type: parsed.type || "dark", colors: parsed.colors || {} };
    } catch {
        return { type: "dark", colors: {} };
    }
}

function applyVSCodeTheme({ type, colors }) {
    document.documentElement.setAttribute("data-theme", type);
    const root = document.documentElement;

    const MAPPING = [
        ["--bg-color",        ["editor.background"]],
        ["--panel-bg",        ["sideBar.background","panel.background","editorWidget.background","breadcrumbPicker.background"]],
        ["--panel-alt-bg",    ["list.hoverBackground","editor.lineHighlightBackground","list.focusBackground"]],
        ["--text-primary",    ["editor.foreground","foreground"]],
        ["--text-secondary",  ["descriptionForeground","activityBar.inactiveForeground","editorLineNumber.foreground","breadcrumb.foreground"]],
        ["--border-color",    ["panel.border","editorGroup.border","activityBar.border","checkbox.border","input.border"]],
        ["--header-text",     ["activityBar.foreground","titleBar.activeForeground"]],
        ["--nav-link",        ["list.highlightForeground","textLink.foreground","focusBorder","activityBarBadge.background"]],
        ["--nav-link-hover",  ["button.hoverBackground","button.background","focusBorder"]],
        ["--chart-primary",   ["badge.background","activityBarBadge.background","focusBorder","button.background"]],
        ["--chart-secondary", ["terminal.ansiBlue","terminal.ansiCyan","editorBracketHighlight.foreground1","editorInfo.foreground"]],
        ["--chart-success",   ["gitDecoration.addedResourceForeground","terminal.ansiGreen","terminal.ansiBrightGreen","debugTokenExpression.boolean"]],
        ["--chart-warning",   ["debugConsole.warningForeground","terminal.ansiYellow","gitDecoration.modifiedResourceForeground","editorWarning.foreground"]],
        ["--chart-danger",    ["errorForeground","debugIcon.breakpointForeground","terminal.ansiRed","gitDecoration.deletedResourceForeground"]],
        ["--chart-muted",     ["editorLineNumber.foreground","activityBar.inactiveForeground","breadcrumb.foreground"]],
    ];

    MAPPING.forEach(([cssVar, keys]) => {
        const value = pickVSCodeColor(colors, keys);
        if (value) root.style.setProperty(cssVar, stripColorAlpha(value));
    });

    // Header gradient from title bar + status bar colors
    const hStart = pickVSCodeColor(colors, ["titleBar.activeBackground","activityBar.background","statusBar.background"]);
    const hEnd   = pickVSCodeColor(colors, ["statusBar.background","activityBar.background","titleBar.activeBackground"]);
    if (hStart) {
        const s = stripColorAlpha(hStart);
        const e = hEnd ? stripColorAlpha(hEnd) : s;
        root.style.setProperty("--header-bg", s === e ? s : `linear-gradient(135deg, ${s}, ${e})`);
    }

    root.style.setProperty("--shadow", type === "dark"
        ? "0 18px 42px rgba(0,0,0,0.4)"
        : "0 18px 42px rgba(14,40,74,0.1)");
}

function pickVSCodeColor(colors, keys) {
    for (const key of keys) {
        const v = colors[key];
        if (v && v.startsWith("#") && v.length >= 4) return v;
    }
    return null;
}

function stripColorAlpha(hex) {
    if (!hex || !hex.startsWith("#")) return hex;
    if (hex.length === 9) return hex.slice(0, 7);
    if (hex.length === 5) return hex.slice(0, 4);
    return hex;
}

/* ═══════════════════════════════════════════════════════════════
   PAGINATION
═══════════════════════════════════════════════════════════════ */

function bindTableControls() {
    document.addEventListener("change", event => {
        const select = event.target.closest(".page-size-select");
        if (!select || !select.dataset.paginationKey) return;
        const key = select.dataset.paginationKey;
        if (!state.pagination[key]) return;
        state.pagination[key].pageSize = Number(select.value);
        state.pagination[key].page = 1;
        applyFilter({ keepPagination: true });
    });

    document.addEventListener("click", event => {
        const btn = event.target.closest("[data-export][data-format]");
        if (!btn) return;
        exportTable(btn.dataset.export, btn.dataset.format);
    });
}

function goToPage(paginationKey, newPage) {
    const pg = state.pagination[paginationKey];
    if (!pg) return;
    const total = (state.tableData[paginationKey] || []).length;
    const totalPages = Math.max(1, Math.ceil(total / pg.pageSize));
    pg.page = Math.max(1, Math.min(Number(newPage), totalPages));
    applyFilter({ keepPagination: true });
}

function renderPaginationBar(containerId, paginationKey) {
    const container = document.getElementById(containerId);
    if (!container) return;

    const pg = state.pagination[paginationKey];
    const data = state.tableData[paginationKey] || [];
    const total = data.length;

    if (total <= pg.pageSize) {
        container.innerHTML = "";
        return;
    }

    const totalPages = Math.ceil(total / pg.pageSize);
    const start = (pg.page - 1) * pg.pageSize + 1;
    const end = Math.min(pg.page * pg.pageSize, total);
    const prevDis = pg.page <= 1 ? "disabled" : "";
    const nextDis = pg.page >= totalPages ? "disabled" : "";

    container.innerHTML = `
        <span class="pg-info">Rows ${formatNumber(start)}–${formatNumber(end)} of ${formatNumber(total)}</span>
        <div class="pg-controls">
            <button class="btn-pg" onclick="goToPage('${paginationKey}',1)" ${prevDis} title="First">«</button>
            <button class="btn-pg" onclick="goToPage('${paginationKey}',${pg.page - 1})" ${prevDis} title="Previous">‹</button>
            <span class="pg-current">Page ${pg.page} of ${totalPages}</span>
            <button class="btn-pg" onclick="goToPage('${paginationKey}',${pg.page + 1})" ${nextDis} title="Next">›</button>
            <button class="btn-pg" onclick="goToPage('${paginationKey}',${totalPages})" ${nextDis} title="Last">»</button>
        </div>
    `;
}

/* ═══════════════════════════════════════════════════════════════
   EXPORT (JSON / CSV / PDF)
═══════════════════════════════════════════════════════════════ */

function exportTable(tableId, format) {
    const data = state.tableData[tableId];
    const config = TABLE_EXPORT_CONFIG[tableId];
    if (!config) return;
    if (!data || data.length === 0) { alert("No data to export."); return; }

    const stamp = new Date().toISOString().slice(0, 10);
    const name = `${tableId}-${stamp}`;

    if (format === "json") {
        downloadBlob(
            new Blob([JSON.stringify(data.map(config.toExportRow), null, 2)], { type: "application/json" }),
            `${name}.json`
        );
    } else if (format === "csv") {
        const cols = config.columns;
        const header = cols.map(c => csvQuote(c.header)).join(",");
        const lines = data.map(row => cols.map(c => csvQuote(c.value(row))).join(","));
        downloadBlob(
            new Blob([[header, ...lines].join("\r\n")], { type: "text/csv;charset=utf-8;" }),
            `${name}.csv`
        );
    } else if (format === "pdf") {
        const tableEl = document.getElementById(tableId);
        if (!tableEl) return;
        const win = window.open("", "_blank", "width=1000,height=720");
        win.document.write(`<!doctype html><html><head>
            <title>${escapeHtml(config.title)}</title>
            <style>
                body{font-family:Arial,sans-serif;padding:20px;color:#111}
                h1{font-size:17px;margin-bottom:12px}
                p{font-size:12px;color:#555;margin-bottom:10px}
                table{border-collapse:collapse;width:100%;font-size:11px}
                th,td{border:1px solid #ccc;padding:5px 9px;text-align:left}
                th{background:#f0f0f0;font-weight:bold}
                tr:nth-child(even){background:#f8f8f8}
                a{color:#000;text-decoration:none}
                @media print{body{padding:0}}
            </style>
        </head><body>
            <h1>${escapeHtml(config.title)}</h1>
            <p>Exported ${new Date().toLocaleString()} — ${formatNumber(data.length)} records</p>
            ${tableEl.outerHTML}
            <script>window.onload=()=>window.print()<\/script>
        </body></html>`);
        win.document.close();
    }
}

function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(url); }, 200);
}

function csvQuote(value) {
    const str = String(value == null ? "" : value);
    return (str.includes(",") || str.includes("\"") || str.includes("\n"))
        ? `"${str.replace(/"/g, '""')}"` : str;
}

