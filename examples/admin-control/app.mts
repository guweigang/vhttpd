const DEFAULT_ADMIN_BASE = "http://127.0.0.1:20211";

function htmlEscape(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function readConfig(ctx, key, fallbackValue) {
  const value = readConfigValue(ctx, key, fallbackValue);
  return typeof value === "string" ? value : fallbackValue;
}

function readConfigValue(ctx, key, fallbackValue) {
  if (typeof ctx.runtime.getConfig === "function") {
    return ctx.runtime.getConfig(key, fallbackValue);
  }
  const config = ctx.runtime.config({});
  const value = key.split(".").reduce((current, part) => {
    if (!current || typeof current !== "object") {
      return undefined;
    }
    return current[part];
  }, config);
  return value === undefined ? fallbackValue : value;
}

function adminBaseFromConfig(ctx) {
  const explicit = readConfig(ctx, "admin.base_url", "");
  if (explicit) {
    return explicit.replace(/\/$/, "");
  }
  let host = String(readConfigValue(ctx, "admin.host", "127.0.0.1") || "127.0.0.1");
  const port = String(readConfigValue(ctx, "admin.port", "") || "");
  if (host === "0.0.0.0" || host === "::") {
    host = "127.0.0.1";
  }
  return port ? "http://" + host + ":" + port : DEFAULT_ADMIN_BASE;
}

function adminProxy(ctx) {
  const adminBase = adminBaseFromConfig(ctx);
  if (!adminBase) {
    return ctx.problem(503, "Admin proxy unavailable", "admin_base is not configured");
  }
  const target = String(ctx.target || ctx.path || "").replace(/^\/api\/admin/, "/admin");
  const response = ctx.runtime.httpFetch({
    url: adminBase + target,
    method: ctx.method,
    body: ctx.body || "",
    headers: {
      "content-type": ctx.header("content-type") || "",
      "x-vhttpd-admin-token": ctx.header("x-vhttpd-admin-token") || "",
    },
  }, { ok: false, status: 502, body: "", headers: {}, error: "admin_proxy_fetch_failed" });
  if (!response || !response.ok) {
    return ctx.problem(502, "Admin proxy failed", response && response.error ? response.error : "admin_proxy_fetch_failed");
  }
  const contentType = response.headers["content-type"] || response.headers["Content-Type"] || "application/json; charset=utf-8";
  ctx.status(response.status || 200);
  ctx.setHeader("content-type", contentType);
  return ctx.text(response.body || "");
}

function adminControlHtml(ctx) {
  const title = "vhttpd Admin";
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f7f9;
      --surface: #ffffff;
      --surface-2: #eef2f6;
      --line: #d7dde5;
      --line-strong: #b7c2cf;
      --text: #17202a;
      --muted: #627184;
      --accent: #0f766e;
      --accent-2: #1d4ed8;
      --danger: #b42318;
      --ok: #067647;
      --warn: #a15c07;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-width: 320px;
      background: var(--bg);
      color: var(--text);
      font-size: 14px;
    }
    button, input, select {
      font: inherit;
    }
    .shell {
      min-height: 100vh;
      display: grid;
      grid-template-columns: 236px minmax(0, 1fr);
    }
    .sidebar {
      background: #202833;
      color: #dbe4ee;
      padding: 18px 14px;
      display: flex;
      flex-direction: column;
      gap: 18px;
    }
    .brand {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      padding: 0 4px;
    }
    .brand h1 {
      margin: 0;
      font-size: 18px;
      line-height: 1.2;
      font-weight: 700;
      letter-spacing: 0;
    }
    .state-dot {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: var(--warn);
      box-shadow: 0 0 0 3px rgba(255,255,255,.1);
      flex: 0 0 auto;
    }
    .state-dot.ok { background: #38a169; }
    .state-dot.error { background: #e5484d; }
    .nav {
      display: grid;
      gap: 4px;
    }
    .nav button {
      height: 34px;
      border: 0;
      border-radius: 6px;
      padding: 0 10px;
      background: transparent;
      color: #c8d4e0;
      text-align: left;
      cursor: pointer;
    }
    .nav button[aria-selected="true"] {
      background: #344052;
      color: #ffffff;
    }
    .side-form {
      margin-top: auto;
      display: grid;
      gap: 8px;
    }
    .side-actions {
      display: grid;
      grid-template-columns: 1fr 34px;
      gap: 8px;
    }
    label {
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
      text-transform: uppercase;
    }
    .sidebar label { color: #9fb0c4; }
    input {
      width: 100%;
      height: 34px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #ffffff;
      padding: 0 10px;
      color: var(--text);
    }
    select, textarea {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #ffffff;
      padding: 8px 10px;
      color: var(--text);
    }
    textarea {
      min-height: 180px;
      resize: vertical;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 1.45;
    }
    .sidebar input {
      border-color: #445166;
      background: #161d27;
      color: #eef3f8;
    }
    .content {
      min-width: 0;
      display: grid;
      grid-template-rows: auto 1fr;
    }
    .topbar {
      min-height: 62px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 14px;
      padding: 14px 20px;
      border-bottom: 1px solid var(--line);
      background: rgba(255,255,255,.84);
      backdrop-filter: blur(8px);
    }
    .topbar h2 {
      margin: 0;
      font-size: 19px;
      line-height: 1.2;
      letter-spacing: 0;
    }
    .toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      justify-content: flex-end;
    }
    .button {
      height: 34px;
      border: 1px solid var(--line-strong);
      border-radius: 6px;
      background: #ffffff;
      color: var(--text);
      padding: 0 12px;
      cursor: pointer;
      white-space: nowrap;
    }
    .button.primary {
      background: var(--accent);
      border-color: var(--accent);
      color: #ffffff;
    }
    .side-button {
      height: 34px;
      border: 1px solid #4b6476;
      border-radius: 6px;
      background: #dbeafe;
      color: #0f2f47;
      padding: 0 10px;
      cursor: pointer;
      font-weight: 750;
    }
    .side-button.icon {
      padding: 0;
      font-size: 16px;
      line-height: 1;
    }
    .main {
      padding: 18px 20px 26px;
      overflow: auto;
    }
    .status {
      min-height: 26px;
      color: var(--muted);
      font-size: 13px;
      display: flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 14px;
    }
    .grid {
      display: grid;
      gap: 12px;
    }
    .metrics {
      grid-template-columns: repeat(4, minmax(130px, 1fr));
    }
    .panel {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      min-width: 0;
    }
    .panel-header {
      height: 42px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      padding: 0 12px;
      border-bottom: 1px solid var(--line);
    }
    .panel-header h3 {
      margin: 0;
      font-size: 14px;
      line-height: 1.2;
      letter-spacing: 0;
    }
    .panel-body {
      padding: 12px;
      min-width: 0;
    }
    .metric {
      padding: 12px;
      min-height: 86px;
    }
    .metric .label {
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
      text-transform: uppercase;
    }
    .metric .value {
      margin-top: 10px;
      font-size: 28px;
      line-height: 1;
      font-weight: 750;
      letter-spacing: 0;
    }
    .metric .sub {
      margin-top: 8px;
      color: var(--muted);
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .split {
      grid-template-columns: minmax(0, 1.1fr) minmax(320px, .9fr);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }
    th, td {
      border-bottom: 1px solid var(--line);
      padding: 8px 10px;
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
    }
    th {
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      background: var(--surface-2);
    }
    tr:last-child td { border-bottom: 0; }
    .pill {
      display: inline-flex;
      align-items: center;
      min-height: 22px;
      border-radius: 999px;
      padding: 2px 8px;
      background: #edf7f6;
      color: #075e59;
      font-size: 12px;
      font-weight: 650;
      max-width: 100%;
      overflow-wrap: anywhere;
    }
    .pill.blue { background: #eef4ff; color: #1d4ed8; }
    .pill.gray { background: #eef1f5; color: #52616f; }
    .pill.red { background: #fff1f0; color: var(--danger); }
    .list {
      display: grid;
      gap: 8px;
    }
    .form-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
    }
    .form-field {
      display: grid;
      gap: 6px;
      min-width: 0;
    }
    .form-field.full {
      grid-column: 1 / -1;
    }
    .app-list {
      display: grid;
      gap: 10px;
    }
    .app-item {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px;
      background: #ffffff;
    }
    .app-item strong {
      display: block;
      margin-bottom: 8px;
      overflow-wrap: anywhere;
    }
    .row {
      display: grid;
      grid-template-columns: minmax(110px, 180px) minmax(0, 1fr);
      gap: 10px;
      padding: 8px 0;
      border-bottom: 1px solid var(--line);
    }
    .row:last-child { border-bottom: 0; }
    .key {
      color: var(--muted);
      font-weight: 650;
      overflow-wrap: anywhere;
    }
    .value-text {
      overflow-wrap: anywhere;
      white-space: pre-wrap;
    }
    pre {
      margin: 0;
      max-height: 440px;
      overflow: auto;
      border-radius: 6px;
      border: 1px solid var(--line);
      background: #101820;
      color: #ecf5ff;
      padding: 12px;
      font-size: 12px;
      line-height: 1.45;
    }
    .graph-list {
      display: grid;
      gap: 8px;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    }
    .node {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px;
      min-height: 92px;
      background: #ffffff;
    }
    .node strong {
      display: block;
      font-size: 13px;
      margin-bottom: 6px;
      overflow-wrap: anywhere;
    }
    .node span {
      display: inline-flex;
      margin-right: 5px;
      margin-bottom: 5px;
    }
    .hidden { display: none; }
    @media (max-width: 860px) {
      .shell { grid-template-columns: 1fr; }
      .sidebar { position: static; }
      .side-form { margin-top: 0; }
      .metrics, .split { grid-template-columns: 1fr; }
      .topbar { align-items: flex-start; flex-direction: column; }
      .toolbar { justify-content: flex-start; }
      .row { grid-template-columns: 1fr; }
      .form-grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <h1>vhttpd Admin</h1>
        <span id="stateDot" class="state-dot"></span>
      </div>
      <nav class="nav" aria-label="Admin sections">
        <button data-view="dashboard" aria-selected="true">Dashboard</button>
        <button data-view="apps">Applications</button>
        <button data-view="graph">Runtime Graph</button>
        <button data-view="schema">Schema</button>
        <button data-view="drafts">Drafts</button>
        <button data-view="events">Events</button>
        <button data-view="raw">Raw</button>
      </nav>
      <div class="side-form">
        <label for="adminToken">Admin Token</label>
        <div class="side-actions">
          <input id="adminToken" autocomplete="off" type="password" placeholder="x-vhttpd-admin-token">
          <button id="applyToken" class="side-button icon" title="Apply token" aria-label="Apply token">OK</button>
        </div>
      </div>
    </aside>
    <section class="content">
      <header class="topbar">
        <h2 id="viewTitle">Dashboard</h2>
        <div class="toolbar">
          <button id="refresh" class="button primary">Refresh</button>
        </div>
      </header>
      <main class="main">
        <div id="status" class="status">Idle</div>
        <section id="view-dashboard" class="view grid">
          <div class="grid metrics" id="metrics"></div>
          <div class="grid split">
            <div class="panel">
              <div class="panel-header"><h3>Applications</h3><span id="dashboardAppCount" class="pill gray">0</span></div>
              <div class="panel-body"><div id="dashboardApps"></div></div>
            </div>
            <div class="panel">
              <div class="panel-header"><h3>Listening Ports</h3><span id="listenerCount" class="pill gray">0</span></div>
              <div class="panel-body"><div id="listenerPorts"></div></div>
            </div>
          </div>
          <div class="grid split">
            <div class="panel">
              <div class="panel-header"><h3>Pipeline Flow</h3><span id="pipelineCount" class="pill gray">0</span></div>
              <div class="panel-body"><div id="pipelineFlows"></div></div>
            </div>
            <div class="panel">
              <div class="panel-header"><h3>Runtime</h3><span id="runtimeState" class="pill gray">unknown</span></div>
              <div class="panel-body"><div id="runtimeSummary" class="list"></div></div>
            </div>
          </div>
        </section>
        <section id="view-apps" class="view hidden grid">
          <div class="grid split">
            <div class="panel">
              <div class="panel-header"><h3>Applications</h3><span id="appCount" class="pill gray">0</span></div>
              <div class="panel-body"><div id="apps" class="app-list"></div></div>
            </div>
            <div class="panel">
              <div class="panel-header"><h3>New App Config</h3><span id="appDraftState" class="pill gray">draft</span></div>
              <div class="panel-body">
                <div class="form-grid">
                  <div class="form-field">
                    <label for="newAppId">App ID</label>
                    <input id="newAppId" autocomplete="off" placeholder="my_app">
                  </div>
                  <div class="form-field">
                    <label for="newAppKind">Kind</label>
                    <select id="newAppKind">
                      <option value="vjsx">VJSX HTTP</option>
                      <option value="static">Static Files</option>
                      <option value="fixed-response">Fixed Response</option>
                    </select>
                  </div>
                  <div class="form-field">
                    <label for="newAppPort">Listener Port</label>
                    <input id="newAppPort" autocomplete="off" inputmode="numeric" placeholder="20300">
                  </div>
                  <div class="form-field">
                    <label for="newAppHost">Host</label>
                    <input id="newAppHost" autocomplete="off" value="127.0.0.1">
                  </div>
                  <div class="form-field full">
                    <label for="newAppEntry">Entry / Root</label>
                    <input id="newAppEntry" autocomplete="off" placeholder="../my-app/app.mts">
                  </div>
                  <div class="form-field full">
                    <label for="newAppModuleRoot">Module Root</label>
                    <input id="newAppModuleRoot" autocomplete="off" placeholder="../my-app">
                  </div>
                  <div class="form-field full">
                    <label for="newAppIncludePath">Include Path</label>
                    <input id="newAppIncludePath" autocomplete="off" placeholder="../my-app/my-app-v2.toml">
                  </div>
                  <div class="form-field full">
                    <label for="newAppToml">Generated TOML</label>
                    <textarea id="newAppToml" spellcheck="false"></textarea>
                  </div>
                </div>
                <div class="toolbar" style="justify-content:flex-start; margin-top:12px">
                  <button id="generateAppConfig" class="button">Generate</button>
                  <button id="saveAppDraft" class="button primary">Save Draft</button>
                </div>
              </div>
            </div>
          </div>
        </section>
        <section id="view-graph" class="view hidden">
          <div class="panel">
            <div class="panel-header"><h3>Nodes</h3><span id="graphCount" class="pill gray">0</span></div>
            <div class="panel-body"><div id="graphNodes" class="graph-list"></div></div>
          </div>
        </section>
        <section id="view-schema" class="view hidden">
          <div class="panel">
            <div class="panel-header"><h3>Catalog</h3><span id="schemaCount" class="pill gray">0</span></div>
            <div class="panel-body"><div id="schemaCatalog"></div></div>
          </div>
        </section>
        <section id="view-drafts" class="view hidden">
          <div class="panel">
            <div class="panel-header"><h3>Drafts</h3><span id="draftCount" class="pill gray">0</span></div>
            <div class="panel-body"><div id="drafts"></div></div>
          </div>
        </section>
        <section id="view-events" class="view hidden">
          <div class="panel">
            <div class="panel-header"><h3>Events</h3><span id="eventCount" class="pill gray">0</span></div>
            <div class="panel-body"><div id="events"></div></div>
          </div>
        </section>
        <section id="view-raw" class="view hidden">
          <div class="panel">
            <div class="panel-header"><h3>Snapshot</h3><span class="pill gray">json</span></div>
            <div class="panel-body"><pre id="raw"></pre></div>
          </div>
        </section>
      </main>
    </section>
  </div>
  <script>
    const endpoints = {
      runtime: "/api/admin/runtime",
      graph: "/api/admin/runtime/graph",
      schema: "/api/admin/schema",
      drafts: "/api/admin/drafts",
      events: "/api/admin/events?limit=80",
      stats: "/api/admin/stats"
    };
    const state = {
      activeView: "dashboard",
      data: {},
      errors: {}
    };
    const $ = (id) => document.getElementById(id);
    const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (ch) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;"
    })[ch]);
    const asArray = (value) => Array.isArray(value) ? value : [];
    const keys = (value) => value && typeof value === "object" && !Array.isArray(value) ? Object.keys(value) : [];
    const count = (value) => Array.isArray(value) ? value.length : keys(value).length;
    function authHeaders() {
      const token = $("adminToken").value.trim();
      return token ? { "x-vhttpd-admin-token": token } : {};
    }
    function endpointUrl(path) {
      return path;
    }
    async function loadEndpoint(name, path) {
      const response = await fetch(endpointUrl(path), { headers: authHeaders() });
      const text = await response.text();
      let body = text;
      try { body = text ? JSON.parse(text) : null; } catch (_) {}
      if (!response.ok) {
        const error = body && body.error ? body.error : response.status + " " + response.statusText;
        throw new Error(error);
      }
      return body;
    }
    async function refresh() {
      $("status").textContent = "Loading";
      $("stateDot").className = "state-dot";
      state.errors = {};
      const entries = await Promise.all(Object.entries(endpoints).map(async ([name, path]) => {
        try {
          return [name, await loadEndpoint(name, path), null];
        } catch (err) {
          return [name, null, err && err.message ? err.message : String(err)];
        }
      }));
      for (const [name, data, error] of entries) {
        state.data[name] = data;
        if (error) state.errors[name] = error;
      }
      render();
    }
    function selectView(name) {
      state.activeView = name;
      for (const button of document.querySelectorAll(".nav button")) {
        button.setAttribute("aria-selected", button.dataset.view === name ? "true" : "false");
      }
      for (const view of document.querySelectorAll(".view")) {
        view.classList.toggle("hidden", view.id !== "view-" + name);
      }
      $("viewTitle").textContent = {
        dashboard: "Dashboard",
        graph: "Runtime Graph",
        apps: "Applications",
        schema: "Schema",
        drafts: "Drafts",
        events: "Events",
        raw: "Raw"
      }[name] || name;
    }
    function renderStatus() {
      const errors = keys(state.errors);
      if (errors.length) {
        $("status").innerHTML = '<span class="pill red">error</span>' + esc(errors.map((key) => key + ": " + state.errors[key]).join(" | "));
        $("stateDot").className = "state-dot error";
        return;
      }
      $("status").innerHTML = '<span class="pill">connected</span>' + new Date().toLocaleString();
      $("stateDot").className = "state-dot ok";
    }
    function metric(label, value, sub) {
      return '<div class="panel metric"><div class="label">' + esc(label) + '</div><div class="value">' + esc(value) + '</div><div class="sub">' + esc(sub || "") + '</div></div>';
    }
    function table(headers, rows) {
      if (!rows.length) return '<div class="value-text">No rows</div>';
      return '<table><thead><tr>' + headers.map((h) => '<th>' + esc(h) + '</th>').join("") + '</tr></thead><tbody>' +
        rows.map((row) => '<tr>' + row.map((cell) => '<td>' + cell + '</td>').join("") + '</tr>').join("") +
        '</tbody></table>';
    }
    function renderDashboard() {
      const runtime = state.data.runtime || {};
      const stats = state.data.stats || {};
      const appsSnapshot = state.data.apps || {};
      const graph = state.data.graph || {};
      const drafts = asArray(state.data.drafts);
      const events = asArray(state.data.events);
      const apps = asArray(appsSnapshot.apps);
      const listeners = asArray(appsSnapshot.listeners);
      const pipelineFlows = asArray(appsSnapshot.pipelines);
      const counts = appsSnapshot.counts || {};
      const nodes = asArray(graph.nodes);
      const graphPipelines = nodes.filter((node) => node.domain === "pipeline");
      const graphListeners = nodes.filter((node) => node.domain === "listener");
      const graphRelays = nodes.filter((node) => node.domain === "relay");
      const graphGroups = apps.length ? [] : appGroupsFromGraph();
      const appTotal = counts.apps ?? (apps.length || graphGroups.length);
      const pipelineTotal = counts.pipelines ?? (pipelineFlows.length || graphPipelines.length);
      const listenerTotal = counts.listeners ?? (listeners.length || graphListeners.length);
      const typeCounts = appKindCounts(apps);
      $("metrics").innerHTML = [
        metric("Applications", appTotal, typeCounts || "runtime groups"),
        metric("Listeners", listenerTotal, "bound ports"),
        metric("Pipelines", pipelineTotal, "configured flows"),
        metric("Relays", counts.relays ?? graphRelays.length, count(runtime.relay || runtime.relays || {}) + " runtime items"),
        metric("Drafts", drafts.length, "file-backed admin state"),
        metric("Events", events.length, "recent admin events")
      ].join("");
      $("dashboardAppCount").textContent = appTotal + " apps";
      if (apps.length) {
        $("dashboardApps").innerHTML = table(["App", "Type", "Listeners", "Pipelines", "Engines", "Status"], apps.map((app) => [
          '<span class="pill blue">' + esc(app.label || app.id) + '</span>',
          esc(app.kind || "mixed"),
          esc(asArray(app.listeners).map(listenerLabel).join(", ")),
          esc(asArray(app.pipelines).map((pipeline) => pipeline.id).join(", ")),
          esc(asArray(app.engines).map((engine) => engine.id + " (" + (engine.kind || "-") + ")").join(", ")),
          '<span class="pill ' + (app.status === "ok" ? "" : "red") + '">' + esc(app.status || "ok") + '</span>'
        ]));
      } else {
        $("dashboardApps").innerHTML = table(["App", "Listeners", "Pipelines", "Engines", "Status"], graphGroups.map((group) => {
          const byDomain = (domain) => group.nodes.filter((node) => node.domain === domain);
          return [
            '<span class="pill blue">' + esc(group.id) + '</span>',
            esc(byDomain("listener").map((node) => node.label || node.id).join(", ")),
            esc(byDomain("pipeline").map((node) => node.label || node.id).join(", ")),
            esc(byDomain("engine").map((node) => (node.label || node.id) + " (" + (node.kind || "-") + ")").join(", ")),
            '<span class="pill">ok</span>'
          ];
        }));
      }
      $("listenerCount").textContent = listenerTotal + " listeners";
      $("listenerPorts").innerHTML = listeners.length ? table(["Listener", "Protocol", "Address", "Control"], listeners.map((listener) => [
        '<span class="pill">' + esc(listener.id) + '</span>',
        esc([listener.protocol, listener.transport].filter(Boolean).join("/")),
        esc((listener.host || "0.0.0.0") + ":" + (listener.port || "")),
        listener.control ? '<span class="pill blue">admin</span>' : '<span class="pill gray">app</span>'
      ])) : table(["Listener", "Protocol", "Address", "Control"], graphListeners.map((node) => {
        const meta = node.metadata || {};
        return [
          '<span class="pill">' + esc(node.label || node.id) + '</span>',
          esc([node.kind, meta.transport].filter(Boolean).join("/")),
          esc((meta.host || "0.0.0.0") + ":" + (meta.port || "")),
          node.id === "control" ? '<span class="pill blue">admin</span>' : '<span class="pill gray">app</span>'
        ];
      }));
      $("pipelineCount").textContent = pipelineTotal + " flows";
      if (pipelineFlows.length) {
        $("pipelineFlows").innerHTML = table(["Pipeline", "Match", "Flow"], pipelineFlows.map((pipeline) => [
          '<span class="pill blue">' + esc(pipeline.id) + '</span>',
          esc(pipeline.match || "*"),
          esc(asArray(pipeline.flow).join(" -> "))
        ]));
      } else {
        $("pipelineFlows").innerHTML = table(["Id", "Match", "Egress"], graphPipelines.map((node) => [
          '<span class="pill blue">' + esc(node.label || node.id) + '</span>',
          esc((node.metadata && (node.metadata.paths || node.metadata.methods)) || ""),
          esc((asArray(graph.edges).find((edge) => edge.from === node.ref && edge.kind === "egress") || {}).to || "")
        ]));
      }
      $("runtimeState").textContent = errorsLabel();
      $("runtimeSummary").innerHTML = rows({
        "HTTP requests": stats.requests_total ?? stats.http_requests_total ?? "",
        "HTTP errors": stats.errors_total ?? stats.http_errors_total ?? "",
        "Active websockets": runtime.active_websockets ?? runtime.activeWebsockets ?? "",
        "Active upstreams": runtime.active_upstreams ?? runtime.activeUpstreams ?? "",
        "Worker mode": runtime.worker_backend_mode ?? runtime.workerBackendMode ?? ""
      });
    }
    function appKindCounts(apps) {
      const counts = {};
      for (const app of apps) {
        const kind = app.kind || "mixed";
        counts[kind] = (counts[kind] || 0) + 1;
      }
      return Object.entries(counts).map(([kind, value]) => kind + " " + value).join(", ");
    }
    function listenerLabel(listener) {
      return listener.id + " " + (listener.host || "0.0.0.0") + ":" + (listener.port || "");
    }
    function appGroupsFromGraph() {
      const graph = state.data.graph || {};
      const nodes = asArray(graph.nodes);
      const edges = asArray(graph.edges);
      const groups = {};
      const byRef = {};
      for (const node of nodes) {
        byRef[node.ref] = node;
      }
      function pipelineAppId(node) {
        if (node.group && String(node.group).startsWith("site:")) {
          return String(node.group).slice(5) || "default";
        }
        if (node.group) {
          return String(node.group).split(".")[0] || "default";
        }
        return String(node.id || node.label || "default").split(".")[0] || "default";
      }
      function ensureGroup(key) {
        groups[key] = groups[key] || { id: key, nodes: [], edges: [] };
        return groups[key];
      }
      function pushUnique(list, item, key) {
        if (item && !list.some((current) => current[key] === item[key])) {
          list.push(item);
        }
      }
      for (const pipeline of nodes.filter((node) => node.domain === "pipeline")) {
        const key = pipelineAppId(pipeline);
        const group = ensureGroup(key);
        const seen = {};
        const queue = [pipeline.ref];
        while (queue.length) {
          const ref = queue.shift();
          if (!ref || seen[ref]) continue;
          seen[ref] = true;
          const node = byRef[ref];
          if (node) pushUnique(group.nodes, node, "ref");
          for (const edge of edges) {
            if (edge.from !== ref && edge.to !== ref) continue;
            pushUnique(group.edges, edge, "id");
            const nextRef = edge.from === ref ? edge.to : edge.from;
            if (byRef[nextRef] && !seen[nextRef]) {
              queue.push(nextRef);
            }
          }
        }
      }
      for (const node of nodes) {
        const assigned = Object.values(groups).some((group) => group.nodes.some((item) => item.ref === node.ref));
        if (assigned) continue;
        if (node.domain === "listener" && (node.id === "control" || node.id === "admin_ui")) {
          pushUnique(ensureGroup("admin").nodes, node, "ref");
        } else if (node.domain === "relay" || node.domain === "provider") {
          pushUnique(ensureGroup(String(node.id || node.label || "default")).nodes, node, "ref");
        }
      }
      return Object.values(groups).sort((a, b) => a.id.localeCompare(b.id));
    }
    function renderApps() {
      const appsSnapshot = state.data.apps || {};
      const apps = asArray(appsSnapshot.apps);
      if (apps.length) {
        $("appCount").textContent = apps.length + " apps";
        $("apps").innerHTML = apps.map((app) => {
          const listeners = asArray(app.listeners).map(listenerLabel);
          const engines = asArray(app.engines).map((engine) => engine.id + " (" + (engine.kind || "-") + ")");
          const adapters = asArray(app.adapters).map((adapter) => adapter.id + " (" + (adapter.kind || "-") + ")");
          const resources = asArray(app.resources).map((resource) => resource.id + " (" + (resource.kind || "-") + ")");
          const pipelines = asArray(app.pipelines).map((pipeline) => pipeline.id);
          return '<div class="app-item"><strong>' + esc(app.label || app.id) + '</strong>' +
            '<div><span class="pill">' + esc(app.kind || "mixed") + '</span> <span class="pill blue">listeners ' + listeners.length + '</span> <span class="pill gray">pipelines ' + pipelines.length + '</span></div>' +
            rows({
              "Status": app.status || "ok",
              "Listeners": listeners.join(", "),
              "Engines": engines.join(", "),
              "Adapters": adapters.join(", "),
              "Resources": resources.join(", "),
              "Pipelines": pipelines.join(", ")
            }) + '</div>';
        }).join("");
        return;
      }
      const groups = appGroupsFromGraph();
      $("appCount").textContent = groups.length + " apps";
      $("apps").innerHTML = groups.map((group) => {
        const byDomain = (domain) => group.nodes.filter((node) => node.domain === domain);
        const listeners = byDomain("listener").map((node) => {
          const meta = node.metadata || {};
          return node.label + (meta.port ? ":" + meta.port : "");
        });
        const engines = byDomain("engine").map((node) => node.label + " (" + (node.kind || "-") + ")");
        const adapters = byDomain("adapter").map((node) => node.label + " (" + (node.kind || "-") + ")");
        const pipelines = byDomain("pipeline").map((node) => node.label);
        return '<div class="app-item"><strong>' + esc(group.id) + '</strong>' +
          '<div><span class="pill">listeners ' + listeners.length + '</span> <span class="pill blue">engines ' + engines.length + '</span> <span class="pill gray">pipelines ' + pipelines.length + '</span></div>' +
          rows({
            "Listeners": listeners.join(", "),
            "Engines": engines.join(", "),
            "Adapters": adapters.join(", "),
            "Pipelines": pipelines.join(", ")
          }) + '</div>';
      }).join("") || '<div class="value-text">No application groups detected</div>';
    }
    function safeId(raw) {
      return String(raw || "").trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, "_").replace(/^_+|_+$/g, "");
    }
    function quoteToml(value) {
      return JSON.stringify(String(value || ""));
    }
    function generateAppToml() {
      const id = safeId($("newAppId").value);
      const kind = $("newAppKind").value;
      const host = $("newAppHost").value.trim() || "127.0.0.1";
      const port = Number.parseInt($("newAppPort").value.trim(), 10) || 20300;
      const entry = $("newAppEntry").value.trim();
      const moduleRoot = $("newAppModuleRoot").value.trim();
      const appId = id || "new_app";
      $("newAppId").value = appId;
      if (!$("newAppIncludePath").value.trim()) {
        $("newAppIncludePath").value = "../" + appId + "/" + appId + "-v2.toml";
      }
      let body = 'version = 2\\n\\n' +
        '[listeners.' + appId + ']\\n' +
        'protocol = "http"\\n' +
        'transport = "tcp"\\n' +
        'host = ' + quoteToml(host) + '\\n' +
        'port = ' + port + '\\n\\n';
      if (kind === "vjsx") {
        body += '[engines.' + appId + ']\\n' +
          'kind = "vjsx"\\n' +
          'entry = ' + quoteToml(entry || "./app.mts") + '\\n' +
          'module_root = ' + quoteToml(moduleRoot || ".") + '\\n' +
          'runtime_profile = "node"\\n' +
          'thread_count = 2\\n\\n' +
          '[adapters.' + appId + ']\\n' +
          'kind = "http-handler"\\n' +
          'engine = "engine:' + appId + '"\\n\\n';
      } else if (kind === "static") {
        body += '[resources.storage.' + appId + ']\\n' +
          'kind = "filesystem"\\n' +
          'root = ' + quoteToml(entry || "./public") + '\\n\\n' +
          '[adapters.' + appId + ']\\n' +
          'kind = "static"\\n' +
          'storage = "resource:storage/' + appId + '"\\n' +
          'root = ' + quoteToml(entry || "./public") + '\\n\\n';
      } else {
        body += '[adapters.' + appId + ']\\n' +
          'kind = "fixed-response"\\n' +
          'options = { status = "200", body = "ok" }\\n\\n';
      }
      body += '[[pipelines]]\\n' +
        'id = "' + appId + '.app"\\n' +
        'group = "' + appId + '"\\n' +
        'ingress = "listener:' + appId + '"\\n' +
        'match.paths = ["*"]\\n' +
        'egress = "adapter:' + appId + '"\\n';
      $("newAppToml").value = body;
      return body;
    }
    async function saveAppDraft() {
      const id = safeId($("newAppId").value) || "new_app";
      const body = $("newAppToml").value.trim() ? $("newAppToml").value : generateAppToml();
      $("appDraftState").textContent = "saving";
      try {
        const draftId = "app." + id + ".toml";
        await fetch("/api/admin/drafts?id=" + encodeURIComponent(draftId), {
          method: "POST",
          headers: { ...authHeaders(), "content-type": "text/plain; charset=utf-8" },
          body
        }).then(async (response) => {
          if (!response.ok) {
            const text = await response.text();
            throw new Error(text || response.status + " " + response.statusText);
          }
        });
        $("appDraftState").textContent = "saved";
        await refresh();
      } catch (err) {
        $("appDraftState").textContent = "error";
        state.errors.appDraft = err && err.message ? err.message : String(err);
        renderStatus();
      }
    }
    function rows(record) {
      return Object.entries(record).map(([key, value]) =>
        '<div class="row"><div class="key">' + esc(key) + '</div><div class="value-text">' + esc(value) + '</div></div>'
      ).join("");
    }
    function errorsLabel() {
      return keys(state.errors).length ? "degraded" : "ok";
    }
    function renderGraph() {
      const graph = state.data.graph || {};
      const nodes = asArray(graph.nodes);
      $("graphCount").textContent = nodes.length + " nodes";
      $("graphNodes").innerHTML = nodes.map((node) => {
        const meta = node.metadata && typeof node.metadata === "object" ? node.metadata : {};
        return '<div class="node"><strong>' + esc(node.ref || node.id) + '</strong>' +
          '<span class="pill">' + esc(node.domain) + '</span>' +
          '<span class="pill gray">' + esc(node.kind || "-") + '</span>' +
          '<div class="value-text">' + esc(Object.entries(meta).filter(([, value]) => value).map(([key, value]) => key + "=" + value).join("  ")) + '</div></div>';
      }).join("") || '<div class="value-text">No graph nodes</div>';
    }
    function renderSchema() {
      const schema = state.data.schema || {};
      const domains = asArray(schema.domains || schema.items || schema);
      $("schemaCount").textContent = count(domains) + " domains";
      $("schemaCatalog").innerHTML = table(["Domain", "Kinds"], domains.map((domain) => [
        '<span class="pill">' + esc(domain.domain || domain.id || domain.name || "domain") + '</span>',
        esc(asArray(domain.kinds || domain.items).map((item) => item.kind || item.id || item.name || String(item)).join(", "))
      ]));
    }
    function renderDrafts() {
      const drafts = asArray(state.data.drafts);
      $("draftCount").textContent = drafts.length + " drafts";
      $("drafts").innerHTML = table(["Id", "Updated", "Bytes"], drafts.map((draft) => [
        '<span class="pill blue">' + esc(draft.key || draft.id || "") + '</span>',
        esc(draft.updated_at || draft.updatedAt || ""),
        esc(draft.bytes || draft.size || "")
      ]));
    }
    function renderEvents() {
      const events = asArray(state.data.events);
      $("eventCount").textContent = events.length + " events";
      $("events").innerHTML = table(["Time", "Type", "Target"], events.map((event) => [
        esc(event.ts || event.time || event.created_at || ""),
        '<span class="pill gray">' + esc(event.type || event.action || "") + '</span>',
        esc(event.key || event.target || event.draft_id || "")
      ]));
    }
    function renderRaw() {
      $("raw").textContent = JSON.stringify({ data: state.data, errors: state.errors }, null, 2);
    }
    function render() {
      renderStatus();
      renderDashboard();
      renderApps();
      renderGraph();
      renderSchema();
      renderDrafts();
      renderEvents();
      renderRaw();
    }
    localStorage.removeItem("vhttpd.admin.base");
    $("adminToken").value = localStorage.getItem("vhttpd.admin.token") || "";
    function applyToken() {
      localStorage.setItem("vhttpd.admin.token", $("adminToken").value.trim());
      refresh();
    }
    $("applyToken").addEventListener("click", applyToken);
    $("adminToken").addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        applyToken();
      }
    });
    $("refresh").addEventListener("click", refresh);
    $("generateAppConfig").addEventListener("click", generateAppToml);
    $("saveAppDraft").addEventListener("click", saveAppDraft);
    for (const id of ["newAppId", "newAppKind", "newAppPort", "newAppHost", "newAppEntry", "newAppModuleRoot"]) {
      $(id).addEventListener("input", generateAppToml);
      $(id).addEventListener("change", generateAppToml);
    }
    for (const button of document.querySelectorAll(".nav button")) {
      button.addEventListener("click", () => selectView(button.dataset.view));
    }
    selectView("dashboard");
    refresh();
  </script>
</body>
</html>`;
}

function handle(ctx) {
  if (String(ctx.path || "").startsWith("/api/admin/")) {
    return adminProxy(ctx);
  }
  return ctx.html(adminControlHtml(ctx), 200);
}

export default handle;
