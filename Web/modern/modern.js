"use strict";

const DATA_ROOT = document.body?.dataset.dataRoot ?? "../";
const ASSET_ROOT = document.body?.dataset.assetRoot ?? "";
const PAGE_ROOT = document.body?.dataset.pageRoot ?? "";
const DATA_URL = `${DATA_ROOT}data.json`;
const HISTORY_URL = `${DATA_ROOT}history.json`;
const SCOPES_URL = `${DATA_ROOT}scopes.json`;
const COLLECTION_STATUS_URL = `${DATA_ROOT}collection-status.json`;
const THEMES_URL = `${ASSET_ROOT}themes.json`;
const WARNING_THRESHOLD = 85;
const CRITICAL_THRESHOLD = 94;
const INACTIVE_DAYS = 90;
const PAGE_SIZES = [10, 25, 50, 100];
const DAY_MS = 86400000;

const STATUS = {
    healthy:   { label: "Healthy",    color: "var(--ok)" },
    warning:   { label: "Warning",    color: "var(--warn)" },
    critical:  { label: "Critical",   color: "var(--crit)" },
    over:      { label: "Over quota", color: "var(--over)" },
    unlimited: { label: "Unlimited",  color: "var(--unl)" }
};

const ICONS = {
    logo: '<path d="M4 6h16v12H4z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="m4 7 8 6 8-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>',
    grid: '<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>',
    report: '<path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9 12h7M9 16h7"/>',
    mailbox: '<path d="M4 6h16v12H4z"/><path d="m4 7 8 6 8-6"/>',
    classic: '<path d="M3 12h18M3 6h18M3 18h12"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM18 18h3v3h-3zM14 20h2M20 14v2"/>',
    moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
    users: '<circle cx="9" cy="8" r="4"/><path d="M2 21a7 7 0 0 1 14 0"/><path d="M16 4a4 4 0 0 1 0 8M22 21a7 7 0 0 0-5-6.7"/>',
    db: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4"/>',
    alert: '<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17h.01"/>',
    sleep: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
    login: '<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><path d="m10 17 5-5-5-5M15 12H3"/>',
    sync: '<path d="M4 12a8 8 0 0 1 13.7-5.7L20 9"/><path d="M20 4v5h-5"/><path d="M20 12a8 8 0 0 1-13.7 5.7L4 15"/><path d="M4 20v-5h5"/>',
    check: '<path d="m5 12 5 5 9-9"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-1.8 3.1-.2-.1a1.7 1.7 0 0 0-1.9.2l-.1.1-1.8-1a1.7 1.7 0 0 0-1.7-1.5h-.2l-1.8 1.1-.2-.1a1.7 1.7 0 0 0-.7-1.8l-.1-.1V13.4a1.7 1.7 0 0 0-1.5-1.4H7.8l-.1-.1V8.4h.2a1.7 1.7 0 0 0 1.5-1.7v-.1l1.8-3.1h.2a1.7 1.7 0 0 0 1.8 0l.1-.1 1.8 1 .1.1a1.7 1.7 0 0 0-.2 1.9v.1l1.7 1h.1l1.8 1v3.5z"/>',
    book: '<path d="M4 4h11a3 3 0 0 1 3 3v13H7a3 3 0 0 1-3-3z"/><path d="M7 4v16M10 8h5M10 12h5"/>',
    copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
    download: '<path d="M12 3v12M7 10l5 5 5-5M4 21h16"/>',
    close: '<path d="M6 6l12 12M18 6 6 18"/>'
};

const state = {
    data: null,
    mailboxes: [],
    byKey: new Map(),
    history: new Map(),
    scopes: [],
    collectionStatus: null,
    themes: [],
    meta: { collectorUtc: null, recordUtc: null, historyUtc: null },
    view: readViewFromUrl()
};

// ── Utilities ────────────────────────────────────────────────

function icon(name, extra = "") {
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${ICONS[name] || ""}</svg>`;
}

function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
}

function toNumber(value) {
    if (value === null || value === undefined || value === "") return null;
    const n = typeof value === "number" ? value : Number(String(value).replace(/,/g, ""));
    return Number.isFinite(n) ? n : null;
}

function pick(obj, ...names) {
    if (!obj || typeof obj !== "object") return undefined;
    for (const name of names) {
        if (obj[name] !== undefined && obj[name] !== null) return obj[name];
    }
    return undefined;
}

function parseDate(value) {
    if (!value) return null;
    const d = new Date(value);
    return Number.isNaN(d.getTime()) || d.getUTCFullYear() < 1980 ? null : d;
}

const numberFormat = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
const decimalFormat = new Intl.NumberFormat(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const dateFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" });
const dateTimeFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit" });
const relativeFormat = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

function fmtNumber(n) { return n === null || n === undefined ? "—" : numberFormat.format(n); }

function fmtGB(gb) {
    if (gb === null || gb === undefined) return "—";
    if (gb >= 1024) return `${decimalFormat.format(gb / 1024)} TB`;
    return `${decimalFormat.format(gb)} GB`;
}

function fmtPct(p) { return p === null || p === undefined ? "—" : `${decimalFormat.format(p)}%`; }

function fmtDate(d, withTime = false) {
    const date = d instanceof Date ? d : parseDate(d);
    if (!date) return "—";
    return (withTime ? dateTimeFormat : dateFormat).format(date);
}

function fmtRelative(d) {
    const date = d instanceof Date ? d : parseDate(d);
    if (!date) return "Never";
    const diff = date.getTime() - Date.now();
    const abs = Math.abs(diff);
    const units = [["year", 365 * DAY_MS], ["month", 30 * DAY_MS], ["week", 7 * DAY_MS], ["day", DAY_MS], ["hour", 3600000], ["minute", 60000]];
    for (const [unit, ms] of units) {
        if (abs >= ms) return relativeFormat.format(Math.round(diff / ms), unit);
    }
    return "just now";
}

function daysSince(d) {
    const date = d instanceof Date ? d : parseDate(d);
    return date ? (Date.now() - date.getTime()) / DAY_MS : null;
}

function initials(name) {
    const parts = String(name || "?").replace(/[^\p{L}\p{N} ]/gu, " ").trim().split(/\s+/).filter(Boolean);
    return ((parts[0]?.[0] || "?") + (parts.length > 1 ? parts[parts.length - 1][0] : "")).toUpperCase();
}

function avatarColor(seed) {
    let hash = 0;
    for (const ch of String(seed)) hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
    return `hsl(${hash % 360} 62% 52%)`;
}

function statusOf(m) {
    if (m.quotaGB === null || m.quotaGB <= 0) return "unlimited";
    const usage = m.usagePercent ?? 0;
    if (usage >= 100) return "over";
    if (usage >= CRITICAL_THRESHOLD) return "critical";
    if (usage >= WARNING_THRESHOLD) return "warning";
    return "healthy";
}

function statusChip(status) {
    return `<span class="chip status-${status}">${escapeHtml(STATUS[status].label)}</span>`;
}

function showToast(message) {
    let toast = document.querySelector(".toast");
    if (!toast) {
        toast = document.createElement("div");
        toast.className = "toast";
        toast.setAttribute("role", "status");
        document.body.appendChild(toast);
    }
    toast.textContent = message;
    toast.classList.add("show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => toast.classList.remove("show"), 1800);
}

// ── URL state ────────────────────────────────────────────────

function readViewFromUrl() {
    const params = new URL(window.location.href).searchParams;
    const page = Math.max(1, parseInt(params.get("page") || "1", 10) || 1);
    const size = parseInt(params.get("size") || "25", 10);
    return {
        scope: params.get("scope") || "",
        q: params.get("q") || "",
        sort: params.get("sort") || "usage",
        dir: params.get("dir") === "asc" ? "asc" : "desc",
        status: params.get("status") || "",
        page,
        size: PAGE_SIZES.includes(size) ? size : 25,
        mailbox: params.get("mailbox") || ""
    };
}

function buildUrl(overrides = {}, path = null) {
    const view = { ...state.view, ...overrides };
    const url = new URL(path || window.location.pathname, window.location.href);
    url.search = "";
    const defaults = { scope: state.scopes[0]?.id || "", q: "", sort: "usage", dir: "desc", status: "", page: 1, size: 25, mailbox: "" };
    for (const key of ["scope", "q", "status", "sort", "dir", "page", "size", "mailbox"]) {
        const value = view[key];
        if (value !== "" && value !== null && value !== undefined && String(value) !== String(defaults[key])) {
            url.searchParams.set(key, String(value));
        }
    }
    url.hash = "";
    return url;
}

function pageUrl(page) {
    return `${page === "mailbox" ? PAGE_ROOT : ""}${page}.html`;
}

function setView(changes, { resetPage = false } = {}) {
    state.view = { ...state.view, ...changes };
    if (resetPage) state.view.page = 1;
    window.history.replaceState(null, "", buildUrl());
    render();
}

// ── Data loading ─────────────────────────────────────────────

async function fetchJson(url, { optional = false } = {}) {
    const response = await fetch(`${url}?v=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) {
        if (optional) return null;
        throw new Error(`Could not load ${url} (HTTP ${response.status})`);
    }
    return response.json();
}

function normaliseMailbox(raw) {
    const current = pick(raw, "current", "Current") || {};
    const licensing = pick(raw, "Licensing", "licensing") || {};
    const retentionValue = pick(raw, "Retention", "retention");
    const retention = retentionValue && typeof retentionValue === "object" ? retentionValue : null;
    const availability = pick(raw, "DataAvailability", "dataAvailability");
    const unavailableFields = [].concat(pick(availability, "UnavailableFields", "unavailableFields") || [])
        .map(field => String(field).toLowerCase());
    const isUnavailable = field => unavailableFields.includes(String(field).toLowerCase());
    const permissionValue = pick(raw, "permissions", "Permissions");
    const permissions = isUnavailable("Permissions")
        ? null
        : [].concat(permissionValue || []).filter(p => p && typeof p === "object");
    const quotaGB = toNumber(pick(current, "quotaGB", "QuotaGB"));
    const totalGB = toNumber(pick(current, "totalGB", "TotalGB", "SizeGB")) ?? 0;
    let usagePercent = toNumber(pick(current, "usagePercent", "UsagePercent"));
    if (usagePercent === null && quotaGB > 0) usagePercent = (totalGB / quotaGB) * 100;
    const archiveEnabledValue = pick(current, "archiveEnabled", "ArchiveEnabled");

    const m = {
        guid: String(pick(raw, "ExchangeGuid", "exchangeGuid") || ""),
        smtp: String(pick(raw, "PrimarySmtpAddress", "primarySmtpAddress") || ""),
        name: String(pick(raw, "DisplayName", "displayName") || ""),
        totalGB,
        quotaGB,
        usagePercent,
        items: toNumber(pick(current, "itemCount", "ItemCount")) ?? 0,
        archiveEnabled: archiveEnabledValue === undefined || archiveEnabledValue === null ? null : Boolean(archiveEnabledValue),
        archiveGB: isUnavailable("ArchiveSizeGB") ? null : toNumber(pick(current, "archiveSizeGB", "ArchiveSizeGB")),
        archiveItems: isUnavailable("ArchiveItemCount") ? null : toNumber(pick(current, "archiveItemCount", "ArchiveItemCount")),
        lastLogon: parseDate(pick(current, "lastLogonTime", "LastLogonTime")),
        refreshed: parseDate(pick(current, "sampleTimestamp", "SampleTimestamp")),
        created: parseDate(pick(raw, "WhenCreatedUtc", "whenCreatedUtc", "WhenCreated")),
        type: String(pick(licensing, "RecipientTypeDetails", "recipientTypeDetails") || "Unknown"),
        hasLicense: pick(licensing, "HasLicense", "hasLicense"),
        licenseRequired: pick(licensing, "LicenseRequired", "licenseRequired"),
        licenseType: pick(licensing, "LicenseType", "licenseType") || "",
        retentionPolicy: retention ? (pick(retention, "RetentionPolicy", "retentionPolicy") || "") : null,
        litigationHold: retention ? pick(retention, "LitigationHoldEnabled", "litigationHoldEnabled") : null,
        permissions,
        dataAvailability: availability || null,
        unavailableFields
    };
    if (!m.name) m.name = m.smtp || m.guid || "Unknown mailbox";
    m.key = (m.guid || m.smtp).toLowerCase();
    m.status = statusOf(m);
    return m;
}

function indexHistory(raw) {
    const map = new Map();
    for (const record of [].concat(pick(raw, "MailboxHistory", "mailboxHistory") || [])) {
        const guid = String(pick(record, "ExchangeGuid", "exchangeGuid") || "").toLowerCase();
        if (!guid) continue;
        const samples = [].concat(pick(record, "Samples", "samples") || [])
            .map(s => ({
                t: parseDate(pick(s, "TimestampUtc", "timestampUtc")),
                gb: toNumber(pick(s, "SizeGB", "sizeGB")) ?? 0,
                archiveGB: toNumber(pick(s, "ArchiveSizeGB", "archiveSizeGB")),
                items: toNumber(pick(s, "ItemCount", "itemCount")) ?? 0,
                usage: toNumber(pick(s, "UsagePercent", "usagePercent"))
            }))
            .filter(s => s.t)
            .sort((a, b) => a.t - b.t);
        map.set(guid, samples);
    }
    return map;
}

async function loadData() {
    const [data, history, scopes, collectionStatus, themes] = await Promise.all([
        fetchJson(DATA_URL),
        fetchJson(HISTORY_URL, { optional: true }).catch(() => null),
        fetchJson(SCOPES_URL, { optional: true }).catch(() => null),
        fetchJson(COLLECTION_STATUS_URL, { optional: true }).catch(() => null),
        fetchJson(THEMES_URL, { optional: true }).catch(() => [])
    ]);

    state.data = data;
    state.mailboxes = [].concat(pick(data, "Mailboxes", "mailboxes") || []).map(normaliseMailbox).filter(m => m.key);
    state.byKey = new Map(state.mailboxes.map(m => [m.key, m]));
    state.history = indexHistory(history);
    state.scopes = Array.isArray(scopes?.scopes) && scopes.scopes.length
        ? scopes.scopes.filter(s => s && s.id)
        : [{ id: "all", name: "All Mailboxes", rules: {} }];
    state.collectionStatus = collectionStatus;
    state.themes = Array.isArray(themes) ? themes : [];
    state.meta = {
        collectorUtc: parseDate(pick(data, "CollectorLastCompletedUtc") ?? pick(history, "CollectorLastCompletedUtc")),
        recordUtc: parseDate(pick(data, "GeneratedUtc", "generatedUtc")),
        historyUtc: parseDate(pick(history, "GeneratedUtc"))
    };

    const defaultScope = scopes?.defaultScope && state.scopes.some(s => s.id === scopes.defaultScope) ? scopes.defaultScope : state.scopes[0].id;
    if (!state.scopes.some(s => s.id === state.view.scope)) state.view.scope = defaultScope;
    applyAppearance();
}

// ── Scope / filtering ────────────────────────────────────────

function matchesPattern(value, pattern) {
    const raw = String(pattern || "");
    if (!raw || !value) return false;
    try {
        if (raw.toLowerCase().startsWith("re:")) return new RegExp(raw.slice(3), "i").test(value);
        const escaped = raw.toLowerCase().replace(/[.+^${}()|[\]\\]/g, "\\$&");
        return new RegExp(`^${escaped.replace(/\*/g, ".*").replace(/\?/g, ".")}$`).test(value.toLowerCase());
    } catch {
        return false;
    }
}

function anyPattern(value, patterns) {
    return Array.isArray(patterns) && patterns.some(p => matchesPattern(value, p));
}

function inScope(m, scope) {
    const rules = scope?.rules || {};
    if (anyPattern(m.smtp, rules.excludeSmtp) || anyPattern(m.name, rules.excludeDisplayName)) return false;
    if (Number.isFinite(rules.minSizeGB) && m.totalGB < rules.minSizeGB) return false;
    if (Number.isFinite(rules.minUsagePercent) && (m.usagePercent ?? -1) < rules.minUsagePercent) return false;
    const includes = (rules.includeGuids?.length || 0) + (rules.includeSmtp?.length || 0) + (rules.includeDisplayName?.length || 0);
    if (!includes) return true;
    return Boolean(
        rules.includeGuids?.some(g => String(g).toLowerCase() === m.guid.toLowerCase()) ||
        anyPattern(m.smtp, rules.includeSmtp) ||
        anyPattern(m.name, rules.includeDisplayName)
    );
}

function activeScope() {
    return state.scopes.find(s => s.id === state.view.scope) || state.scopes[0];
}

function scopedMailboxes() {
    const scope = activeScope();
    return state.mailboxes.filter(m => inScope(m, scope));
}

function filteredMailboxes() {
    const q = state.view.q.trim().toLowerCase();
    return scopedMailboxes().filter(m =>
        (!q || m.name.toLowerCase().includes(q) || m.smtp.toLowerCase().includes(q) || m.guid.toLowerCase() === q) &&
        (!state.view.status || m.status === state.view.status)
    );
}

// ── SVG charts ───────────────────────────────────────────────

function donutChart(segments, centerValue, centerLabel) {
    const total = segments.reduce((sum, s) => sum + s.value, 0);
    const r = 70;
    const c = 2 * Math.PI * r;
    let offset = 0;
    const arcs = total === 0
        ? `<circle cx="90" cy="90" r="${r}" fill="none" style="stroke:var(--muted)" stroke-width="22"/>`
        : segments.filter(s => s.value > 0).map(s => {
            const len = (s.value / total) * c;
            const gap = segments.filter(x => x.value > 0).length > 1 ? 2 : 0;
            const arc = `<circle cx="90" cy="90" r="${r}" fill="none" style="stroke:${s.color}" stroke-width="22" stroke-dasharray="${Math.max(0, len - gap)} ${c}" stroke-dashoffset="${-offset}" transform="rotate(-90 90 90)"><title>${escapeHtml(s.label)}: ${fmtNumber(s.value)}</title></circle>`;
            offset += len;
            return arc;
        }).join("");
    return `<svg class="chart" viewBox="0 0 180 180" role="img" aria-label="${escapeHtml(centerLabel)}">${arcs}
        <text x="90" y="88" text-anchor="middle" class="donut-center-value">${escapeHtml(centerValue)}</text>
        <text x="90" y="108" text-anchor="middle" class="donut-center-label">${escapeHtml(centerLabel)}</text></svg>`;
}

function legend(segments) {
    const total = segments.reduce((sum, s) => sum + s.value, 0) || 1;
    return `<ul class="legend">${segments.map(s => `
        <li><span class="swatch" style="background:${s.color}"></span><span>${escapeHtml(s.label)}</span>
        <span class="value">${fmtNumber(s.value)}<span class="pct">${Math.round((s.value / total) * 100)}%</span></span></li>`).join("")}</ul>`;
}

function niceMax(value) {
    if (value <= 0) return 1;
    const exp = Math.pow(10, Math.floor(Math.log10(value)));
    const f = value / exp;
    const step = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].find(s => f <= s);
    return step * exp;
}

// Round in the unit the axis will display so labels read 12 TB rather than 11.7 TB.
function niceMaxGB(gb) {
    const unit = gb >= 1024 ? 1024 : 1;
    return niceMax(gb / unit) * unit;
}

function areaChart(series, { height = 260, yFormat = fmtGB, label = "Trend" } = {}) {
    const all = series.flatMap(s => s.points);
    if (all.length < 2) {
        return `<div class="empty">Trend appears once at least two collection runs are in history.<br>${all.length === 1 ? `Latest sample: ${escapeHtml(fmtDate(all[0].t, true))}` : ""}</div>`;
    }
    const W = 720, H = height, L = 64, R = 16, T = 16, B = 32;
    const tMin = Math.min(...all.map(p => p.t.getTime()));
    const tMax = Math.max(...all.map(p => p.t.getTime()));
    const yMax = (yFormat === fmtGB ? niceMaxGB : niceMax)(Math.max(...all.map(p => p.v)) * 1.05);
    const x = t => L + ((t - tMin) / Math.max(1, tMax - tMin)) * (W - L - R);
    const y = v => T + (1 - v / yMax) * (H - T - B);

    const ticks = [0, 0.25, 0.5, 0.75, 1].map(f => f * yMax);
    const grid = ticks.map(v => `<line class="grid-line" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${escapeHtml(yFormat(v))}</text>`).join("");
    const xTicks = Array.from({ length: 5 }, (_, i) => tMin + (i / 4) * (tMax - tMin))
        .map((t, i) => `<text x="${x(t)}" y="${H - 10}" text-anchor="${i === 0 ? "start" : i === 4 ? "end" : "middle"}">${escapeHtml(fmtDate(new Date(t)))}</text>`).join("");

    const defs = series.map((s, i) => `<linearGradient id="g${label.replace(/\W/g, "")}${i}" x1="0" x2="0" y1="0" y2="1"><stop offset="0" style="stop-color:${s.color};stop-opacity:.35"/><stop offset="1" style="stop-color:${s.color};stop-opacity:0"/></linearGradient>`).join("");
    const paths = series.map((s, i) => {
        if (s.points.length < 1) return "";
        const line = s.points.map((p, j) => `${j ? "L" : "M"}${x(p.t.getTime()).toFixed(1)},${y(p.v).toFixed(1)}`).join("");
        const area = `${line}L${x(s.points[s.points.length - 1].t.getTime()).toFixed(1)},${y(0)}L${x(s.points[0].t.getTime()).toFixed(1)},${y(0)}Z`;
        const dots = s.points.length <= 60 ? s.points.map(p => `<circle class="point" cx="${x(p.t.getTime())}" cy="${y(p.v)}" r="3" style="fill:var(--surface);stroke:${s.color}" stroke-width="2"><title>${escapeHtml(s.name)} · ${escapeHtml(fmtDate(p.t, true))}: ${escapeHtml(yFormat(p.v))}</title></circle>`).join("") : "";
        return `<path d="${area}" fill="url(#g${label.replace(/\W/g, "")}${i})"/><path d="${line}" fill="none" style="stroke:${s.color}" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>${dots}`;
    }).join("");

    const legendHtml = series.length > 1
        ? `<ul class="legend" style="display:flex;gap:16px;margin-top:8px">${series.map(s => `<li style="grid-template-columns:10px auto"><span class="swatch" style="background:${s.color}"></span><span>${escapeHtml(s.name)}</span></li>`).join("")}</ul>`
        : "";
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeHtml(label)}"><defs>${defs}</defs>${grid}${xTicks}${paths}</svg>${legendHtml}`;
}

function columnChart(bins, { height = 240, label = "Distribution" } = {}) {
    const W = 400, H = height, L = 34, R = 6, T = 18, B = 30;
    const max = niceMax(Math.max(1, ...bins.map(b => b.value)));
    const bw = (W - L - R) / bins.length;
    const y = v => T + (1 - v / max) * (H - T - B);
    const grid = [0, 0.5, 1].map(f => `<line class="grid-line" x1="${L}" x2="${W - R}" y1="${y(f * max)}" y2="${y(f * max)}"/><text x="${L - 6}" y="${y(f * max) + 4}" text-anchor="end">${fmtNumber(f * max)}</text>`).join("");
    const bars = bins.map((b, i) => {
        const h = y(0) - y(b.value);
        const bx = L + i * bw + bw * 0.16;
        return `<rect class="bar" x="${bx}" y="${y(b.value)}" width="${bw * 0.68}" height="${Math.max(0, h)}" rx="6" style="fill:${b.color}"><title>${escapeHtml(b.label)}: ${fmtNumber(b.value)}</title></rect>
            <text x="${bx + bw * 0.34}" y="${H - 10}" text-anchor="middle" class="axis-label">${escapeHtml(b.label)}</text>
            ${b.value ? `<text x="${bx + bw * 0.34}" y="${y(b.value) - 6}" text-anchor="middle">${fmtNumber(b.value)}</text>` : ""}`;
    }).join("");
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeHtml(label)}">${grid}${bars}</svg>`;
}

function sparkline(values, color) {
    values = values.filter(value => value !== null && value !== undefined && Number.isFinite(value));
    if (values.length < 2) return "";
    const W = 96, H = 28;
    const min = Math.min(...values), max = Math.max(...values);
    const span = max - min || 1;
    const pts = values.map((v, i) => `${(i / (values.length - 1)) * W},${H - 3 - ((v - min) / span) * (H - 6)}`).join(" ");
    return `<svg class="spark" viewBox="0 0 ${W} ${H}" aria-hidden="true"><polyline points="${pts}" fill="none" style="stroke:${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
}

function gaugeChart(percent, color, label) {
    const p = Math.max(0, Math.min(100, percent ?? 0));
    const r = 80, c = Math.PI * r;
    return `<svg class="chart" viewBox="0 0 200 120" role="img" aria-label="${escapeHtml(label)}">
        <path d="M20 105 A80 80 0 0 1 180 105" fill="none" style="stroke:var(--surface-2)" stroke-width="18" stroke-linecap="round"/>
        <path d="M20 105 A80 80 0 0 1 180 105" fill="none" style="stroke:${color}" stroke-width="18" stroke-linecap="round" stroke-dasharray="${(p / 100) * c} ${c}"/>
        <text x="100" y="92" text-anchor="middle" class="gauge-value">${percent === null || percent === undefined ? "∞" : `${Math.round(percent)}%`}</text>
        <text x="100" y="112" text-anchor="middle" class="gauge-label">${escapeHtml(label)}</text></svg>`;
}

function hbarList(rows, { tone = false } = {}) {
    if (!rows.length) return `<div class="empty">No mailboxes to show.</div>`;
    const max = Math.max(...rows.map(r => r.value), 1);
    return `<ul class="hbars">${rows.map(r => `
        <li class="hbar-row">
            <div class="hbar-meta">${r.href ? `<a href="${escapeHtml(r.href)}" title="${escapeHtml(r.title || r.label)}">${escapeHtml(r.label)}</a>` : `<span>${escapeHtml(r.label)}</span>`}<span class="value">${escapeHtml(r.display)}</span></div>
            <div class="hbar-track"><div class="hbar-fill${tone ? " tone" : ""}" style="width:${(r.value / max) * 100}%;${r.color ? `--tone:${r.color}` : ""}"></div></div>
        </li>`).join("")}</ul>`;
}

// ── Aggregations ─────────────────────────────────────────────

function tenantTrend(mailboxes) {
    const keys = new Set(mailboxes.map(m => m.guid.toLowerCase()));
    const byDay = new Map();
    for (const [guid, samples] of state.history) {
        if (!keys.has(guid)) continue;
        for (const s of samples) {
            const day = Date.UTC(s.t.getUTCFullYear(), s.t.getUTCMonth(), s.t.getUTCDate());
            const bucket = byDay.get(day) || { primary: 0, archive: 0, archiveKnown: false };
            bucket.primary += s.gb;
            if (s.archiveGB !== null) {
                bucket.archive += s.archiveGB;
                bucket.archiveKnown = true;
            }
            byDay.set(day, bucket);
        }
    }
    const days = [...byDay.keys()].sort((a, b) => a - b);
    return {
        primary: days.map(d => ({ t: new Date(d), v: byDay.get(d).primary })),
        archive: days
            .filter(d => byDay.get(d).archiveKnown)
            .map(d => ({ t: new Date(d), v: byDay.get(d).archive }))
    };
}

function statusCounts(mailboxes) {
    const counts = Object.fromEntries(Object.keys(STATUS).map(k => [k, 0]));
    mailboxes.forEach(m => counts[m.status]++);
    return counts;
}

// ── Shared chrome ────────────────────────────────────────────

function currentShareUrl() {
    return buildUrl().href;
}

function qrSvg(text, title) {
    try {
        return window.MailboxQr.toSvg(text, { ecl: "M", border: 2, title });
    } catch (err) {
        return `<div class="empty">QR unavailable: ${escapeHtml(err.message)}</div>`;
    }
}

function describeView() {
    const parts = [activeScope()?.name || "All mailboxes"];
    if (state.view.status) parts.push(STATUS[state.view.status]?.label);
    if (state.view.q) parts.push(`“${state.view.q}”`);
    const m = state.view.mailbox && state.byKey.get(state.view.mailbox.toLowerCase());
    if (m && document.body.dataset.page === "mailbox") return m.name;
    return parts.filter(Boolean).join(" · ");
}

function renderShareCard() {
    const slot = document.getElementById("sidebarQr");
    if (!slot) return;
    const url = currentShareUrl();
    slot.innerHTML = `<button type="button" class="qr-frame" data-open-share aria-label="Enlarge QR code for this view">${qrSvg(url, "QR code linking to this view")}</button>`;
}

function openShareDialog() {
    const dialog = document.getElementById("shareDialog");
    if (!dialog) return;
    const url = currentShareUrl();
    dialog.querySelector("[data-share-title]").textContent = describeView();
    dialog.querySelector("[data-share-qr]").innerHTML = qrSvg(url, `QR code linking to ${describeView()}`);
    dialog.querySelector("[data-share-url]").textContent = url;
    dialog.showModal();
}

async function copyShareUrl() {
    const url = currentShareUrl();
    try {
        await navigator.clipboard.writeText(url);
        showToast("Link copied");
    } catch {
        window.prompt("Copy this link", url);
    }
}

function downloadQr() {
    const svg = window.MailboxQr.toSvg(currentShareUrl(), { ecl: "M", border: 4, title: describeView() });
    const blob = new Blob([svg], { type: "image/svg+xml" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `mailbox-dashboard-qr-${new Date().toISOString().slice(0, 10)}.svg`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

function renderFreshness() {
    const el = document.getElementById("freshness");
    if (!el) return;
    const { collectorUtc, recordUtc } = state.meta;
    const future = [collectorUtc, recordUtc].some(d => d && d.getTime() > Date.now() + DAY_MS);
    const stale = recordUtc && daysSince(recordUtc) > 2;
    el.innerHTML = `
        <span title="${escapeHtml(fmtDate(collectorUtc, true))}">Collector completed <strong>${collectorUtc ? escapeHtml(fmtRelative(collectorUtc)) : "unknown"}</strong></span>
        <span title="${escapeHtml(fmtDate(recordUtc, true))}">Latest record <strong${stale || future ? ' style="color:var(--warn)"' : ""}>${recordUtc ? escapeHtml(future ? fmtDate(recordUtc, true) : fmtRelative(recordUtc)) : "unknown"}</strong></span>
        ${future ? `<span style="color:var(--crit)" title="Timestamps are later than now. Re-run Test-MailboxDashboardJSON.ps1 -Repair with the fixed collector.">⚠ timestamp is in the future</span>` : ""}`;
}

function collectionHealth() {
    const status = state.collectionStatus;
    const stateName = String(pick(status, "status", "Status") || "");
    const completed = parseDate(pick(status, "completedUtc", "CompletedUtc"));
    const staleAfterRaw = pick(status, "staleAfterMinutes", "StaleAfterMinutes");
    const staleAfter = toNumber(staleAfterRaw);
    const valid = status &&
        ["Succeeded", "Partial", "Failed"].includes(stateName) &&
        completed &&
        Number.isInteger(staleAfter) &&
        staleAfter >= 1;
    if (!valid) {
        return {
            tone: "tone-warn",
            label: "Collection status unavailable",
            detail: "The mailbox snapshot loaded, but collection-status.json is missing or invalid.",
            short: "Status unavailable"
        };
    }

    const ageMinutes = Math.floor((Date.now() - completed.getTime()) / 60000);
    const partial = pick(status, "partialCollection", "PartialCollection") === true;
    const testData = pick(status, "testData", "TestData") === true;
    const failed = /failed/i.test(stateName);
    const stale = ageMinutes > staleAfter;
    const tone = failed || partial || stale ? (failed ? "tone-crit" : "tone-warn") : "tone-ok";
    const detail = [
        `${stateName}${partial ? " · partial collection" : ""}`,
        `completed ${fmtRelative(completed)}`,
        testData ? "synthetic test data" : "live or persisted collection data"
    ].join(" · ");
    return { tone, label: failed ? "Collection failed" : partial ? "Partial collection" : stale ? "Collection is stale" : "Collection healthy", detail, short: failed ? "Collection failed" : partial ? "Partial" : stale ? "Stale" : "Operational" };
}

function renderCollectionHealth() {
    const health = collectionHealth();
    const strip = document.getElementById("collectionHealth");
    if (strip) {
        strip.className = `collection-strip ${health.tone}`;
        strip.innerHTML = `<span class="collection-icon">${icon(health.tone === "tone-ok" ? "check" : "alert")}</span>
            <div><strong>${escapeHtml(health.label)}</strong><span>${escapeHtml(health.detail)}</span></div>
            ${document.getElementById("reportsContent") ? "" : `<a class="btn" href="${escapeHtml(buildUrl({}, pageUrl("reports")).href)}">View reports</a>`}`;
    }
    const sidebar = document.getElementById("sidebarCollectionState");
    if (sidebar) {
        sidebar.className = `connection-state ${health.tone}`;
        sidebar.innerHTML = `<i></i>${escapeHtml(health.short)}`;
    }
}

function readinessRows(mailboxes) {
    const reporting = window.MailboxReporting;
    const summary = reporting
        ? reporting.aggregate(mailboxes)
        : {
            warningCount: 0, criticalCount: 0, overQuotaCount: 0, inactive90Count: 0,
            licenseGapCount: 0, noRetentionPolicyCount: 0, delegationCount: 0,
            archiveUnavailableCount: 0, permissionUnavailableCount: 0, retentionUnavailableCount: 0
        };
    return [
        {
            icon: "alert",
            label: "Quota pressure",
            detail: `${fmtNumber(summary.overQuotaCount)} over quota · ${fmtNumber(summary.criticalCount)} critical · ${fmtNumber(summary.warningCount)} warning`,
            tone: summary.overQuotaCount + summary.criticalCount ? "tone-crit" : summary.warningCount ? "tone-warn" : "tone-ok"
        },
        {
            icon: "sleep",
            label: "Mailbox activity",
            detail: `${fmtNumber(summary.inactive90Count)} mailboxes inactive for 90+ days or without a logon date`,
            tone: summary.inactive90Count ? "tone-warn" : "tone-ok"
        },
        {
            icon: "check",
            label: "Licensing coverage",
            detail: `${fmtNumber(summary.licenseGapCount)} known required-license gaps`,
            tone: summary.licenseGapCount ? "tone-warn" : "tone-ok"
        },
        {
            icon: "archive",
            label: "Retention coverage",
            detail: `${fmtNumber(summary.noRetentionPolicyCount)} without a recorded policy · ${fmtNumber(summary.retentionUnavailableCount)} unavailable`,
            tone: summary.noRetentionPolicyCount || summary.retentionUnavailableCount ? "tone-warn" : "tone-ok"
        },
        {
            icon: "users",
            label: "Delegation inventory",
            detail: summary.permissionUnavailableCount
                ? `${fmtNumber(summary.delegationCount)} explicit permissions · ${fmtNumber(summary.permissionUnavailableCount)} unavailable`
                : `${fmtNumber(summary.delegationCount)} explicit permissions across ${fmtNumber(mailboxes.length)} mailboxes`,
            tone: summary.permissionUnavailableCount ? "tone-warn" : "tone-info"
        },
        {
            icon: "archive",
            label: "Archive storage availability",
            detail: summary.archiveUnavailableCount
                ? `${fmtNumber(summary.archiveUnavailableCount)} mailbox records do not include archive metrics`
                : "Archive metrics are available for all mailbox records",
            tone: summary.archiveUnavailableCount ? "tone-warn" : "tone-ok"
        }
    ];
}

function renderReadiness(host, mailboxes) {
    if (!host) return;
    host.innerHTML = readinessRows(mailboxes).map(row => `
        <div class="readiness-item ${row.tone}">
            <span class="readiness-icon">${icon(row.icon)}</span>
            <span><strong>${escapeHtml(row.label)}</strong><small>${escapeHtml(row.detail)}</small></span>
            <i aria-hidden="true"></i>
        </div>`).join("");
}

function renderScopeSelect() {
    const select = document.getElementById("scopeSelect");
    if (!select) return;
    select.innerHTML = state.scopes.map(s => `<option value="${escapeHtml(s.id)}" title="${escapeHtml(s.description || "")}">${escapeHtml(s.name || s.id)}</option>`).join("");
    select.value = state.view.scope;
    const sidebarScope = document.getElementById("sidebarScope");
    if (sidebarScope) sidebarScope.textContent = activeScope()?.name || state.view.scope || "All mailboxes";
}

function luminance(hex) {
    const rgb = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
        .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}

function contrastRatio(left, right) {
    const leftLuminance = luminance(left);
    const rightLuminance = luminance(right);
    return (Math.max(leftLuminance, rightLuminance) + 0.05) /
        (Math.min(leftLuminance, rightLuminance) + 0.05);
}

function accessibleForeground(background, preferred) {
    if (/^#[0-9a-f]{6}$/i.test(preferred || "") && contrastRatio(background, preferred) >= 4.5) {
        return preferred;
    }
    return contrastRatio(background, "#111827") >= contrastRatio(background, "#ffffff")
        ? "#111827"
        : "#ffffff";
}

function blendHex(left, right, amount) {
    const channels = [1, 3, 5].map(index => {
        const a = parseInt(left.slice(index, index + 2), 16);
        const b = parseInt(right.slice(index, index + 2), 16);
        return Math.round(a + (b - a) * amount).toString(16).padStart(2, "0");
    });
    return `#${channels.join("")}`;
}

function readAppearance() {
    const fallback = {
        theme: ["light", "dark"].includes(document.documentElement.dataset.theme) ? document.documentElement.dataset.theme : "light",
        forceDarkest: true,
        density: "comfortable"
    };
    try {
        const saved = JSON.parse(localStorage.getItem("mailboxDashboardAppearance"));
        return { ...fallback, ...(saved && typeof saved === "object" ? saved : {}) };
    } catch {
        return fallback;
    }
}

function saveAppearance(appearance) {
    try {
        localStorage.setItem("mailboxDashboardAppearance", JSON.stringify(appearance));
        localStorage.setItem("modernDashboardTheme", ["light", "dark"].includes(appearance.theme) ? appearance.theme : "dark");
    } catch {
        return false;
    }
    return true;
}

function darkestThemeColor(theme) {
    return Object.values(theme)
        .filter(value => typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value))
        .reduce((darkest, color) => luminance(color) < luminance(darkest) ? color : darkest, theme.background);
}

function clearPaletteStyles() {
    const names = [
        "--bg", "--bg-accent", "--surface", "--surface-2", "--surface-glass", "--border",
        "--text", "--text-2", "--text-3", "--primary", "--primary-2", "--primary-soft",
        "--muted", "--grid", "--shadow", "--shadow-lg"
    ];
    names.forEach(name => document.documentElement.style.removeProperty(name));
}

function applyAppearance(options = {}) {
    const appearance = { ...readAppearance(), ...(options || {}) };
    const theme = state.themes.find(item => item.name === appearance.theme);
    const root = document.documentElement;

    clearPaletteStyles();
    if (theme) {
        const background = appearance.forceDarkest ? darkestThemeColor(theme) : theme.background;
        const dark = luminance(background) < 0.35;
        const foreground = accessibleForeground(background, theme.foreground);
        const surface = blendHex(background, foreground, dark ? 0.07 : 0.035);
        const surface2 = blendHex(background, foreground, dark ? 0.035 : 0.018);
        const primary = theme.blue || "#5b5ce2";
        const primary2 = theme.cyan || theme.purple || blendHex(primary, foreground, 0.24);
        root.style.setProperty("--bg", background);
        root.style.setProperty("--bg-accent", `radial-gradient(1200px 600px at 100% -10%, ${primary}28, transparent 60%)`);
        root.style.setProperty("--surface", surface);
        root.style.setProperty("--surface-2", surface2);
        root.style.setProperty("--surface-glass", `${surface}e8`);
        root.style.setProperty("--border", blendHex(background, foreground, dark ? 0.16 : 0.13));
        root.style.setProperty("--text", foreground);
        root.style.setProperty("--text-2", blendHex(foreground, background, dark ? 0.26 : 0.42));
        root.style.setProperty("--text-3", blendHex(foreground, background, dark ? 0.43 : 0.58));
        root.style.setProperty("--primary", primary);
        root.style.setProperty("--primary-2", primary2);
        root.style.setProperty("--primary-soft", `${primary}24`);
        root.style.setProperty("--muted", blendHex(foreground, background, 0.72));
        root.style.setProperty("--grid", blendHex(background, foreground, dark ? 0.1 : 0.07));
        root.dataset.theme = dark ? "dark" : "light";
        root.dataset.eccTheme = theme.name;
    } else {
        root.dataset.theme = appearance.theme === "dark" ? "dark" : "light";
        delete root.dataset.eccTheme;
    }
    root.style.setProperty("color-scheme", root.dataset.theme);
    root.dataset.density = appearance.density;

    const btn = document.getElementById("themeToggle");
    if (btn) {
        btn.innerHTML = icon(root.dataset.theme === "dark" ? "sun" : "moon");
        btn.setAttribute("aria-label", root.dataset.theme === "dark" ? "Switch to light theme" : "Switch to dark theme");
    }
    return appearance;
}

function applyTheme(theme) {
    const appearance = { ...readAppearance(), theme };
    saveAppearance(appearance);
    applyAppearance(appearance);
    if (document.body.dataset.page === "settings" && typeof window.dashboardRenderSettings === "function") {
        window.dashboardRenderSettings();
    }
}

function wireChrome() {
    document.querySelectorAll("[data-icon]").forEach(el => { el.innerHTML = icon(el.dataset.icon); });

    applyAppearance();
    document.getElementById("themeToggle")?.addEventListener("click", () =>
        applyTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark"));

    document.getElementById("refreshButton")?.addEventListener("click", () => boot());

    document.getElementById("scopeSelect")?.addEventListener("change", e => setView({ scope: e.target.value }, { resetPage: true }));

    const search = document.getElementById("searchInput");
    if (search) {
        search.value = state.view.q;
        let timer;
        search.addEventListener("input", () => {
            clearTimeout(timer);
            const changes = { q: search.value };
            if (document.body.dataset.page === "mailbox") changes.mailbox = "";
            timer = setTimeout(() => setView(changes, { resetPage: true }), 200);
        });
    }

    function downloadText(filename, content, mimeType) {
        const link = document.createElement("a");
        link.href = URL.createObjectURL(new Blob([content], { type: mimeType }));
        link.download = filename;
        link.click();
        setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    }

    function exportReport(type, format = "csv") {
        if (!window.MailboxReporting) {
            showToast("Reporting module is unavailable");
            return;
        }
        const report = window.MailboxReporting.buildReport(type, filteredMailboxes());
        const suffix = new Date().toISOString().slice(0, 10);
        if (format === "json") {
            const rows = report.rows.map(values => Object.fromEntries(report.headers.map((header, index) => [header, values[index]])));
            downloadText(`${type}-mailbox-report-${suffix}.json`, JSON.stringify({ title: report.title, rows }, null, 2), "application/json;charset=utf-8");
        } else {
            downloadText(`${type}-mailbox-report-${suffix}.csv`, window.MailboxReporting.toCsv(report), "text/csv;charset=utf-8");
        }
        showToast(`${report.title} exported`);
    }

    function renderReports() {
        const rows = filteredMailboxes();
        const reporting = window.MailboxReporting;
        if (!reporting) throw new Error("reporting.js did not load.");
        const summary = reporting.aggregate(rows);
        const cards = [
            { type: "capacity", icon: "db", title: "Capacity & quota", text: `${fmtNumber(summary.overQuotaCount + summary.criticalCount + summary.warningCount)} need capacity review${summary.archiveUnavailableCount ? ` · ${fmtNumber(summary.archiveUnavailableCount)} archive records unavailable` : ""}.`, count: rows.length },
            { type: "activity", icon: "sleep", title: "Activity & inactivity", text: `${fmtNumber(summary.inactive90Count)} mailboxes are inactive for 90+ days or unknown.`, count: rows.length },
            { type: "licensing", icon: "check", title: "Licensing", text: `${fmtNumber(summary.licenseGapCount)} confirmed required-license gaps.`, count: rows.filter(m => m.licenseRequired !== null && m.licenseRequired !== undefined).length },
            { type: "permissions", icon: "users", title: "Mailbox permissions", text: `${fmtNumber(summary.delegationCount)} explicit permission records${summary.permissionUnavailableCount ? ` · ${fmtNumber(summary.permissionUnavailableCount)} unavailable` : ""}.`, count: summary.delegationCount },
            { type: "retention", icon: "archive", title: "Retention & holds", text: `${fmtNumber(summary.noRetentionPolicyCount)} lack a policy${summary.retentionUnavailableCount ? ` · ${fmtNumber(summary.retentionUnavailableCount)} unavailable` : ""}.`, count: rows.length }
        ];
        document.getElementById("reportMailboxCount").textContent = `${fmtNumber(rows.length)} mailbox${rows.length === 1 ? "" : "es"}`;
        document.getElementById("reportCards").innerHTML = cards.map(card => `
            <article class="card report-card">
                <span class="report-card-icon">${icon(card.icon)}</span>
                <span class="report-card-count">${fmtNumber(card.count)}</span>
                <h2>${escapeHtml(card.title)}</h2>
                <p>${escapeHtml(card.text)}</p>
                <div class="report-actions">
                    <button type="button" class="btn btn-primary" data-export-report="${card.type}" data-report-format="csv">Export CSV</button>
                    <button type="button" class="btn" data-export-report="${card.type}" data-report-format="json">JSON</button>
                </div>
            </article>`).join("");
        document.getElementById("reportSummary").textContent = `${fmtGB(summary.primaryGB)} primary · ${summary.archiveGB === null ? "archive unavailable" : `${fmtGB(summary.archiveGB)} archive`} · ${fmtNumber(rows.length)} mailboxes`;
        const health = collectionHealth();
        const pill = document.getElementById("reportHealthPill");
        if (pill) {
            pill.className = `chip ${health.tone}`;
            pill.textContent = health.short;
        }
        renderReadiness(document.getElementById("reportReadiness"), rows);
    }

    function renderSettings() {
        const appearance = readAppearance();
        const themeSelect = document.getElementById("appearanceTheme");
        const forceDarkest = document.getElementById("forceDarkestBackground");
        const density = document.getElementById("appearanceDensity");
        if (!themeSelect || !forceDarkest || !density) return;

        themeSelect.innerHTML = [
            `<option value="light">Default light</option>`,
            `<option value="dark">Default dark</option>`,
            ...state.themes.map(theme => `<option value="${escapeHtml(theme.name)}">${escapeHtml(theme.name)}</option>`)
        ].join("");
        themeSelect.value = [...themeSelect.options].some(option => option.value === appearance.theme) ? appearance.theme : "light";
        forceDarkest.checked = appearance.forceDarkest !== false;
        density.value = appearance.density === "compact" ? "compact" : "comfortable";
        document.getElementById("themeSwatches").innerHTML = state.themes.map(theme => {
            const selected = theme.name === appearance.theme;
            return `<button type="button" class="theme-swatch${selected ? " selected" : ""}" data-theme-choice="${escapeHtml(theme.name)}" aria-pressed="${selected}">
                <span style="background:${escapeHtml(theme.background)}"></span>
                <span style="background:${escapeHtml(theme.blue)}"></span>
                <span>${escapeHtml(theme.name)}</span>
            </button>`;
        }).join("");
        document.getElementById("appearanceStatus").textContent = `${themeSelect.value} · ${density.value} · ${forceDarkest.checked ? "darkest available" : "supplied"} background`;
    }

    function updateAppearanceFromSettings() {
        const appearance = {
            theme: document.getElementById("appearanceTheme").value,
            forceDarkest: document.getElementById("forceDarkestBackground").checked,
            density: document.getElementById("appearanceDensity").value
        };
        const persisted = saveAppearance(appearance);
        applyAppearance(appearance);
        window.dashboardRenderSettings();
        document.getElementById("appearanceStatus").textContent = persisted
            ? `Saved: ${appearance.theme} · ${appearance.density}`
            : `Applied: ${appearance.theme} · browser storage unavailable`;
    }

    function wireReportsAndSettings() {
        document.addEventListener("click", event => {
            const exportButton = event.target.closest("[data-export-report]");
            if (exportButton) exportReport(exportButton.dataset.exportReport, exportButton.dataset.reportFormat || "csv");
            const themeChoice = event.target.closest("[data-theme-choice]");
            if (themeChoice && document.getElementById("appearanceTheme")) {
                document.getElementById("appearanceTheme").value = themeChoice.dataset.themeChoice;
                updateAppearanceFromSettings();
            }
            const openReport = event.target.closest("[data-open-report]");
            if (openReport) sessionStorage.setItem("mailboxDashboardPreferredReport", openReport.dataset.openReport);
        });
        ["appearanceTheme", "forceDarkestBackground", "appearanceDensity"].forEach(id => {
            document.getElementById(id)?.addEventListener("change", updateAppearanceFromSettings);
        });
        document.getElementById("resetAppearance")?.addEventListener("click", () => {
            const appearance = { theme: "light", forceDarkest: true, density: "comfortable" };
            saveAppearance(appearance);
            applyAppearance(appearance);
            renderSettings();
            showToast("Appearance reset");
        });
    }

    document.addEventListener("click", e => {
        if (e.target.closest("[data-open-share]")) openShareDialog();
        if (e.target.closest("[data-copy-link]")) copyShareUrl();
        if (e.target.closest("[data-download-qr]")) downloadQr();
        if (e.target.closest("[data-close-share]")) document.getElementById("shareDialog")?.close();
    });

    // Carry scope between pages; the overview drops the mailbox and the classic pages only understand scope/mailbox.
    document.querySelectorAll("[data-nav]").forEach(link => {
        link.addEventListener("click", () => {
            let target = link.getAttribute("href").split("?")[0];
            if (link.dataset.nav === "classic") {
                if (PAGE_ROOT === "" && target === "../index.html" && window.location.pathname.includes("/modern/")) {
                    target = "../classic.html";
                }
                const url = new URL(target, window.location.href);
                if (state.view.scope) url.searchParams.set("scope", state.view.scope);
                if (state.view.mailbox) url.searchParams.set("mailbox", state.view.mailbox);
                link.href = url.href;
            } else {
                link.href = buildUrl({ page: 1, mailbox: link.dataset.nav === "overview" ? "" : state.view.mailbox }, target).href;
            }
        });
    });
    window.dashboardRenderReports = renderReports;
    window.dashboardRenderSettings = renderSettings;
    wireReportsAndSettings();
}

// ── Overview page ────────────────────────────────────────────

const COLUMNS = [
    { key: "name",    label: "Mailbox",        get: m => m.name.toLowerCase() },
    { key: "type",    label: "Type",           get: m => m.type },
    { key: "primary", label: "Primary",        get: m => m.totalGB, num: true },
    { key: "archive", label: "Archive",        get: m => m.archiveGB, num: true },
    { key: "usage",   label: "Quota usage",    get: m => m.usagePercent ?? -1 },
    { key: "status",  label: "Status",         get: m => ["healthy", "unlimited", "warning", "critical", "over"].indexOf(m.status) },
    { key: "logon",   label: "Last logon",     get: m => m.lastLogon?.getTime() ?? 0 },
    { key: "created", label: "Created",        get: m => m.created?.getTime() ?? 0 },
    { key: "refresh", label: "Refreshed",      get: m => m.refreshed?.getTime() ?? 0 }
];

function renderOverview() {
    const scoped = scopedMailboxes();
    const rows = filteredMailboxes();
    const counts = statusCounts(rows);
    const trend = tenantTrend(rows);
    renderReadiness(document.getElementById("readinessList"), rows);

    const primaryTotal = rows.reduce((s, m) => s + m.totalGB, 0);
    const archiveValues = rows.map(m => m.archiveGB).filter(value => value !== null);
    const archiveTotal = archiveValues.length ? archiveValues.reduce((sum, value) => sum + value, 0) : null;
    const archiveUnavailable = rows.filter(m => m.archiveGB === null).length;
    const attention = counts.warning + counts.critical + counts.over;
    const inactive = rows.filter(m => !m.lastLogon || daysSince(m.lastLogon) > INACTIVE_DAYS).length;

    document.getElementById("kpis").innerHTML = [
        { label: "Mailboxes", value: fmtNumber(rows.length), foot: rows.length === scoped.length ? `${escapeHtml(activeScope()?.name || "")}` : `of ${fmtNumber(scoped.length)} in scope`, icon: "users", tone: "tone-info" },
        { label: "Primary storage", value: fmtGB(primaryTotal), foot: `avg ${fmtGB(rows.length ? primaryTotal / rows.length : 0)}`, icon: "db", tone: "", spark: trend.primary.map(p => p.v), color: "var(--primary)" },
        { label: "Archive storage", value: archiveTotal === null ? "Unavailable" : fmtGB(archiveTotal), foot: archiveUnavailable ? `${fmtNumber(archiveUnavailable)} mailbox records unavailable` : `${fmtNumber(rows.filter(m => m.archiveEnabled === true).length)} archives enabled`, icon: "archive", tone: archiveUnavailable ? "tone-warn" : "tone-unl", spark: trend.archive.map(p => p.v), color: "var(--unl)" },
        { label: "Needs attention", value: fmtNumber(attention), foot: `${fmtNumber(counts.over)} over · ${fmtNumber(counts.critical)} critical`, icon: "alert", tone: attention ? "tone-crit" : "tone-ok" },
        { label: `Inactive ${INACTIVE_DAYS}d+`, value: fmtNumber(inactive), foot: `${rows.length ? Math.round((inactive / rows.length) * 100) : 0}% of mailboxes`, icon: "sleep", tone: "tone-warn" }
    ].map(k => `
        <article class="card kpi ${k.tone}">
            <div class="kpi-top"><span class="kpi-label">${escapeHtml(k.label)}</span><span class="kpi-icon">${icon(k.icon)}</span></div>
            <div class="kpi-value">${escapeHtml(k.value)}</div>
            <div class="kpi-foot"><span>${k.foot}</span>${k.spark ? sparkline(k.spark, k.color) : ""}</div>
        </article>`).join("");

    document.getElementById("trendChart").innerHTML = areaChart([
        { name: "Primary", color: "var(--primary)", points: trend.primary },
        ...(trend.archive.length ? [{ name: "Archive", color: "var(--unl)", points: trend.archive }] : [])
    ], { label: "Storage trend" });

    const segments = Object.entries(STATUS).map(([key, s]) => ({ key, label: s.label, color: s.color, value: counts[key] }));
    document.getElementById("healthChart").innerHTML = `<div class="donut-wrap">${donutChart(segments, fmtNumber(rows.length), "mailboxes")}${legend(segments)}</div>
        <p style="margin:12px 0 0;font-size:12px;color:var(--text-3)">Select a status to filter: ${segments.map(s => `<button type="button" class="chip status-${s.key}" data-status="${s.key}" style="border:0;cursor:pointer;margin:2px;${state.view.status === s.key ? "outline:2px solid currentColor" : ""}">${escapeHtml(s.label)}</button>`).join("")}
        ${state.view.status ? `<button type="button" class="chip chip-plain" data-status="" style="border:0;cursor:pointer">Clear</button>` : ""}</p>`;

    const bands = [[0, 25], [25, 50], [50, 70], [70, 85], [85, 94], [94, 100], [100, Infinity]];
    document.getElementById("distributionChart").innerHTML = columnChart(bands.map(([lo, hi]) => ({
        label: hi === Infinity ? "100+" : `${lo}–${hi}`,
        value: rows.filter(m => m.usagePercent !== null && m.quotaGB > 0 && m.usagePercent >= lo && m.usagePercent < hi).length,
        color: lo >= 100 ? "var(--over)" : lo >= CRITICAL_THRESHOLD ? "var(--crit)" : lo >= WARNING_THRESHOLD ? "var(--warn)" : "var(--ok)"
    })), { label: "Usage distribution" });

    document.getElementById("topChart").innerHTML = hbarList([...rows].sort((a, b) => b.totalGB - a.totalGB).slice(0, 8).map(m => ({
        label: m.name, title: m.smtp, value: m.totalGB, display: fmtGB(m.totalGB),
        href: buildUrl({ mailbox: m.guid || m.smtp }, pageUrl("mailbox")).href
    })));

    const activity = [
        { label: "Last 7 days", test: d => d !== null && d <= 7, color: "var(--ok)" },
        { label: "8–30 days", test: d => d !== null && d > 7 && d <= 30, color: "var(--primary-2)" },
        { label: "31–90 days", test: d => d !== null && d > 30 && d <= 90, color: "var(--warn)" },
        { label: "Over 90 days", test: d => d !== null && d > 90, color: "var(--crit)" },
        { label: "Never / unknown", test: d => d === null, color: "var(--muted)" }
    ];
    document.getElementById("activityChart").innerHTML = hbarList(activity.map(a => {
        const value = rows.filter(m => a.test(daysSince(m.lastLogon))).length;
        return { label: a.label, value, display: `${fmtNumber(value)} · ${rows.length ? Math.round((value / rows.length) * 100) : 0}%`, color: a.color };
    }), { tone: true });

    renderTable(rows);
}

function renderTable(rows) {
    const col = COLUMNS.find(c => c.key === state.view.sort) || COLUMNS.find(c => c.key === "usage");
    const dir = state.view.dir === "asc" ? 1 : -1;
    const sorted = [...rows].sort((a, b) => {
        const av = col.get(a), bv = col.get(b);
        return (av < bv ? -1 : av > bv ? 1 : 0) * dir || a.name.localeCompare(b.name);
    });
    const pages = Math.max(1, Math.ceil(sorted.length / state.view.size));
    if (state.view.page > pages) state.view.page = pages;
    const start = (state.view.page - 1) * state.view.size;
    const pageRows = sorted.slice(start, start + state.view.size);

    document.getElementById("tableHead").innerHTML = `<tr>${COLUMNS.map(c => `
        <th scope="col"${c.num ? ' class="num"' : ""} aria-sort="${c.key === col.key ? (dir === 1 ? "ascending" : "descending") : "none"}"><button type="button" data-sort="${c.key}">${escapeHtml(c.label)}</button></th>`).join("")}</tr>`;

    document.getElementById("tableBody").innerHTML = pageRows.length ? pageRows.map(m => {
        const href = buildUrl({ mailbox: m.guid || m.smtp }, pageUrl("mailbox")).href;
        const tone = STATUS[m.status].color;
        return `<tr data-href="${escapeHtml(href)}">
            <td><div class="cell-name"><span class="avatar" style="background:${avatarColor(m.key)}">${escapeHtml(initials(m.name))}</span>
                <div><a href="${escapeHtml(href)}"><strong>${escapeHtml(m.name)}</strong></a><small>${escapeHtml(m.smtp)}</small></div></div></td>
            <td>${escapeHtml(m.type.replace(/Mailbox$/, ""))}</td>
            <td class="num">${escapeHtml(fmtGB(m.totalGB))}</td>
            <td class="num">${m.archiveEnabled === null || m.archiveGB === null
                ? '<span style="color:var(--text-3)">Unavailable</span>'
                : m.archiveEnabled
                    ? escapeHtml(fmtGB(m.archiveGB))
                    : '<span style="color:var(--text-3)">Off</span>'}</td>
            <td><div class="usage-cell" style="--tone:${tone}"><div class="usage-track"><div class="usage-fill" style="width:${Math.min(100, m.usagePercent ?? 0)}%"></div></div><span>${m.quotaGB ? escapeHtml(fmtPct(m.usagePercent)) : "∞"}</span></div></td>
            <td>${statusChip(m.status)}</td>
            <td title="${escapeHtml(fmtDate(m.lastLogon, true))}">${escapeHtml(fmtRelative(m.lastLogon))}</td>
            <td>${escapeHtml(fmtDate(m.created))}</td>
            <td title="${escapeHtml(fmtDate(m.refreshed, true))}">${escapeHtml(fmtRelative(m.refreshed))}</td>
        </tr>`;
    }).join("") : `<tr><td colspan="${COLUMNS.length}"><div class="empty">No mailboxes match this view.</div></td></tr>`;

    document.getElementById("tableMeta").textContent = `${fmtNumber(sorted.length)} mailbox${sorted.length === 1 ? "" : "es"} · sorted by ${col.label.toLowerCase()}`;
    document.getElementById("pager").innerHTML = `
        <span>Showing ${sorted.length ? fmtNumber(start + 1) : 0}–${fmtNumber(Math.min(start + state.view.size, sorted.length))} of ${fmtNumber(sorted.length)}</span>
        <label>Rows <select class="select" data-page-size style="height:34px">${PAGE_SIZES.map(s => `<option${s === state.view.size ? " selected" : ""}>${s}</option>`).join("")}</select></label>
        <div class="pager-buttons">
            <button type="button" class="btn" data-goto-page="${state.view.page - 1}"${state.view.page <= 1 ? " disabled" : ""}>Previous</button>
            <span style="align-self:center;padding:0 6px">Page ${state.view.page} of ${pages}</span>
            <button type="button" class="btn" data-goto-page="${state.view.page + 1}"${state.view.page >= pages ? " disabled" : ""}>Next</button>
        </div>`;
}

function wireOverview() {
    document.addEventListener("click", e => {
        const sortBtn = e.target.closest("[data-sort]");
        if (sortBtn) {
            const key = sortBtn.dataset.sort;
            const dir = state.view.sort === key && state.view.dir === "desc" ? "asc" : "desc";
            return setView({ sort: key, dir }, { resetPage: true });
        }
        const pageBtn = e.target.closest("[data-goto-page]");
        if (pageBtn && !pageBtn.disabled) return setView({ page: Number(pageBtn.dataset.gotoPage) });
        const statusBtn = e.target.closest("[data-status]");
        if (statusBtn) {
            const value = statusBtn.dataset.status;
            return setView({ status: state.view.status === value ? "" : value }, { resetPage: true });
        }
        const row = e.target.closest("tr[data-href]");
        if (row && !e.target.closest("a")) window.location.href = row.dataset.href;
    });
    document.addEventListener("change", e => {
        if (e.target.matches("[data-page-size]")) setView({ size: Number(e.target.value) }, { resetPage: true });
    });
}

// ── Mailbox page ─────────────────────────────────────────────

function renderMailbox() {
    const host = document.getElementById("mailboxContent");
    const key = state.view.mailbox.toLowerCase();
    const m = state.byKey.get(key) || state.mailboxes.find(x => x.smtp.toLowerCase() === key);

    if (!m) {
        const q = state.view.q.trim().toLowerCase();
        const matches = scopedMailboxes()
            .filter(x => !q || x.name.toLowerCase().includes(q) || x.smtp.toLowerCase().includes(q))
            .sort((a, b) => b.totalGB - a.totalGB)
            .slice(0, 12);
        host.innerHTML = `
            ${state.view.mailbox ? `<div class="alert tone-warn">${icon("alert")}<div>No mailbox matches <strong>${escapeHtml(state.view.mailbox)}</strong> in the current data.</div></div>` : ""}
            <section class="card"><div class="card-head"><div><h2>Choose a mailbox</h2><p>${q ? "Matches for your search" : "Largest mailboxes in this scope — search above to find any mailbox"}</p></div></div>
            ${matches.length ? `<ul class="picker">${matches.map(x => `<li><a href="${escapeHtml(buildUrl({ mailbox: x.guid || x.smtp, q: "" }).href)}">
                <span class="cell-name"><span class="avatar" style="background:${avatarColor(x.key)}">${escapeHtml(initials(x.name))}</span><span><strong>${escapeHtml(x.name)}</strong><small>${escapeHtml(x.smtp)}</small></span></span>
                ${statusChip(x.status)}</a></li>`).join("")}</ul>` : `<div class="empty">No mailboxes match.</div>`}</section>`;
        document.title = "Mailbox · Mailbox Dashboard";
        return;
    }

    document.title = `${m.name} · Mailbox Dashboard`;
    const samples = state.history.get(m.guid.toLowerCase()) || [];
    const prev = samples.length > 1 ? samples[samples.length - 2] : null;
    const delta = prev ? m.totalGB - prev.gb : null;
    const shareUrl = buildUrl({ mailbox: m.guid || m.smtp, q: "", status: "", page: 1 }).href;

    const events = [
        { when: m.created, what: "Mailbox created", icon: "calendar", tone: "tone-info" },
        { when: m.lastLogon, what: "Last logon", icon: "login", tone: m.lastLogon && daysSince(m.lastLogon) > INACTIVE_DAYS ? "tone-warn" : "tone-ok" },
        { when: m.refreshed, what: "Record refreshed", icon: "sync", tone: "" },
        { when: state.meta.collectorUtc, what: "Collector last completed", icon: "check", tone: "tone-unl" }
    ];

    host.innerHTML = `
        <section class="card hero">
            <span class="avatar">${escapeHtml(initials(m.name))}</span>
            <div style="min-width:0">
                <h2>${escapeHtml(m.name)}</h2>
                <p>${escapeHtml(m.smtp)}</p>
                <div class="chips">
                    <span class="chip">${escapeHtml(STATUS[m.status].label)}</span>
                    <span class="chip chip-plain">${escapeHtml(m.type)}</span>
                    ${m.licenseType ? `<span class="chip chip-plain">${escapeHtml(m.licenseType)}</span>` : ""}
                    ${m.litigationHold === true ? `<span class="chip chip-plain">Litigation hold</span>` : ""}
                </div>
            </div>
            <button type="button" class="hero-qr" data-open-share aria-label="Enlarge QR code for this mailbox">${qrSvg(shareUrl, `QR code linking to ${m.name}`)}</button>
        </section>

        <section class="grid grid-kpi">
            ${[
                { label: "Primary storage", value: fmtGB(m.totalGB), foot: delta === null ? "No previous sample" : `${delta >= 0 ? "+" : "−"}${fmtGB(Math.abs(delta))} since last sample`, icon: "db", tone: "", spark: samples.map(s => s.gb), color: "var(--primary)" },
                { label: "Archive storage", value: m.archiveGB === null ? "Unavailable" : m.archiveEnabled ? fmtGB(m.archiveGB) : "Disabled", foot: m.archiveGB === null ? "Metrics not provided by the collector" : m.archiveEnabled ? `${m.archiveItems === null ? "Item count unavailable" : `${fmtNumber(m.archiveItems)} items`}` : "No archive", icon: "archive", tone: m.archiveGB === null ? "tone-warn" : "tone-unl", spark: samples.map(s => s.archiveGB), color: "var(--unl)" },
                { label: "Items", value: fmtNumber(m.items), foot: "in primary mailbox", icon: "mailbox", tone: "tone-info", spark: samples.map(s => s.items), color: "var(--primary-2)" },
                { label: "Delegates", value: m.permissions === null ? "Unavailable" : fmtNumber(m.permissions.length), foot: m.permissions === null ? "Metrics not provided by the collector" : "explicit permissions", icon: "users", tone: "tone-warn" }
            ].map(k => `
                <article class="card kpi ${k.tone}">
                    <div class="kpi-top"><span class="kpi-label">${escapeHtml(k.label)}</span><span class="kpi-icon">${icon(k.icon)}</span></div>
                    <div class="kpi-value">${escapeHtml(k.value)}</div>
                    <div class="kpi-foot"><span>${escapeHtml(k.foot)}</span>${k.spark ? sparkline(k.spark, k.color) : ""}</div>
                </article>`).join("")}
        </section>

        <section class="grid grid-wide">
            <article class="card">
                <div class="card-head"><div><h2>Storage history</h2><p>${fmtNumber(samples.length)} sample${samples.length === 1 ? "" : "s"} in history</p></div></div>
                ${areaChart([
                    { name: "Primary", color: "var(--primary)", points: samples.map(s => ({ t: s.t, v: s.gb })) },
                    ...(m.archiveEnabled && samples.some(s => s.archiveGB !== null) ? [{ name: "Archive", color: "var(--unl)", points: samples.filter(s => s.archiveGB !== null).map(s => ({ t: s.t, v: s.archiveGB })) }] : [])
                ], { label: "Mailbox storage history" })}
            </article>
            <article class="card">
                <div class="card-head"><div><h2>Quota</h2><p>${m.quotaGB ? `${escapeHtml(fmtGB(m.totalGB))} of ${escapeHtml(fmtGB(m.quotaGB))}` : "No quota limit"}</p></div></div>
                <div class="gauge-wrap">${gaugeChart(m.quotaGB ? m.usagePercent : null, STATUS[m.status].color, "of quota used")}</div>
                <ul class="legend" style="margin-top:12px">
                    <li><span class="swatch" style="background:var(--warn)"></span><span>Warning</span><span class="value">${WARNING_THRESHOLD}%</span></li>
                    <li><span class="swatch" style="background:var(--crit)"></span><span>Critical</span><span class="value">${CRITICAL_THRESHOLD}%</span></li>
                </ul>
            </article>
        </section>

        <section class="grid grid-2">
            <article class="card">
                <div class="card-head"><div><h2>Key dates</h2><p>Lifecycle and data freshness</p></div></div>
                <ul class="timeline">${events.map(ev => `
                    <li class="${ev.tone}"><span class="dot">${icon(ev.icon)}</span>
                        <div><div class="when">${escapeHtml(ev.what)}</div>
                        <div class="rel">${ev.when ? `${escapeHtml(fmtRelative(ev.when))} · ${escapeHtml(fmtDate(ev.when, true))}` : "Not recorded"}</div></div></li>`).join("")}
                </ul>
            </article>
            <article class="card">
                <div class="card-head"><div><h2>Details</h2><p>Licensing and retention</p></div></div>
                <dl class="facts">
                    <div><dt>Licence required</dt><dd>${m.licenseRequired === true ? "Yes" : m.licenseRequired === false ? "No" : "Unknown"}</dd></div>
                    <div><dt>Licence assigned</dt><dd>${m.hasLicense === true ? "Yes" : m.hasLicense === false ? "No" : "Unknown"}</dd></div>
                    <div><dt>Retention policy</dt><dd>${m.retentionPolicy === null ? "Unavailable" : escapeHtml(m.retentionPolicy || "None")}</dd></div>
                    <div><dt>Litigation hold</dt><dd>${m.litigationHold === true ? "Enabled" : m.litigationHold === false ? "Off" : "Unknown"}</dd></div>
                    <div><dt>Exchange GUID</dt><dd style="font-family:ui-monospace,Consolas,monospace;font-size:12px">${escapeHtml(m.guid || "—")}</dd></div>
                </dl>
            </article>
        </section>

        <section class="card">
            <div class="card-head"><div><h2>Delegates</h2><p>${m.permissions === null ? "Permission data unavailable" : `${fmtNumber(m.permissions.length)} explicit permission${m.permissions.length === 1 ? "" : "s"}`}</p></div></div>
            ${m.permissions === null ? `<div class="empty">Permission data is unavailable from the collector for this mailbox.</div>` : m.permissions.length ? `<div class="table-wrap"><table><thead><tr><th>Delegate</th><th>Access rights</th><th>Inherited</th></tr></thead><tbody>
                ${m.permissions.map(p => `<tr style="cursor:default"><td>${escapeHtml(pick(p, "User", "user") || "—")}</td>
                    <td>${[].concat(pick(p, "AccessRights", "accessRights") || []).map(r => `<span class="chip chip-plain" style="margin:2px">${escapeHtml(r)}</span>`).join("")}</td>
                    <td>${pick(p, "IsInherited", "isInherited") ? "Yes" : "No"}</td></tr>`).join("")}
            </tbody></table></div>` : `<div class="empty">No explicit permissions.</div>`}
        </section>`;
}

// ── Boot ─────────────────────────────────────────────────────

function render() {
    renderFreshness();
    renderScopeSelect();
    renderCollectionHealth();
    if (document.body.dataset.page === "mailbox") renderMailbox();
    else if (document.body.dataset.page === "reports") window.dashboardRenderReports();
    else if (document.body.dataset.page === "settings") window.dashboardRenderSettings();
    else renderOverview();
    renderShareCard();
}

async function boot() {
    try {
        if (document.body.dataset.page === "settings") {
            state.themes = (await fetchJson(THEMES_URL, { optional: true }).catch(() => [])) || [];
            applyAppearance();
            window.dashboardRenderSettings();
            const scope = document.getElementById("sidebarScope");
            if (scope) scope.textContent = "Appearance settings";
            const health = document.getElementById("sidebarCollectionState");
            if (health) health.innerHTML = "<i></i>Browser preferences only";
            return;
        }
        await loadData();
        window.history.replaceState(null, "", buildUrl());
        render();
    } catch (err) {
        const host = document.getElementById("mailboxContent") ||
            document.getElementById("content") ||
            document.getElementById("reportsContent") ||
            document.getElementById("settingsContent") ||
            document.body;
        host.insertAdjacentHTML("afterbegin", `<div class="alert tone-crit">${icon("alert")}<div><strong>Could not load dashboard data.</strong> ${escapeHtml(err.message)}</div></div>`);
        console.error(err);
    }
}

document.addEventListener("DOMContentLoaded", () => {
    wireChrome();
    if (!["mailbox", "reports", "settings"].includes(document.body.dataset.page)) wireOverview();
    boot();
});
