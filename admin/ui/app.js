const endpoints = {
      runtime: "/admin/runtime",
      graph: "/admin/runtime/graph",
      configFiles: "/admin/config/files",
      schema: "/admin/schema",
      drafts: "/admin/drafts",
      events: "/admin/events?limit=80",
      stats: "/admin/stats"
    };
    const state = {
      activeView: "dashboard",
      data: {},
      errors: {},
      history: [],
      activeDraftId: "",
      draftPublishResult: null
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
    async function apiRequest(path, options) {
      const response = await fetch(endpointUrl(path), {
        ...(options || {}),
        headers: { ...authHeaders(), ...((options && options.headers) || {}) }
      });
      const text = await response.text();
      let body = text;
      try { body = text ? JSON.parse(text) : null; } catch (_) {}
      if (!response.ok) {
        const error = body && body.error ? body.error : text || response.status + " " + response.statusText;
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
      recordTelemetrySample();
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
        observability: "Observability",
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
    function nestedNumber(value, path, fallback) {
      const result = path.split(".").reduce((current, key) => current && current[key] !== undefined ? current[key] : undefined, value);
      const number = Number(result);
      return Number.isFinite(number) ? number : fallback;
    }
    function runtimeStats() {
      return state.data.stats || (state.data.runtime && state.data.runtime.stats) || {};
    }
    function httpRequestsTotal() {
      const stats = runtimeStats();
      return nestedNumber(stats, "http.requests_total", Number(stats.requests_total ?? stats.http_requests_total ?? 0));
    }
    function httpErrorsTotal() {
      const stats = runtimeStats();
      return nestedNumber(stats, "http.errors_total", Number(stats.errors_total ?? stats.http_errors_total ?? 0));
    }
    function collectRuntimeRoutes() {
      const runtime = state.data.runtime || {};
      const rows = [];
      for (const listener of asArray(runtime.listeners)) {
        for (const route of asArray(listener.pipelines && listener.pipelines.routes)) {
          rows.push({ ...route, listener_id: listener.listener_id || route.ingress || "" });
        }
      }
      for (const route of asArray(runtime.pipelines && runtime.pipelines.routes)) {
        rows.push(route);
      }
      const seen = {};
      return rows.filter((route) => {
        const key = [route.listener_id, route.pipeline_id, route.egress].join("|");
        if (seen[key]) return false;
        seen[key] = true;
        return true;
      });
    }
    function countBy(items, mapper) {
      const counts = {};
      for (const item of items) {
        const key = mapper(item) || "unknown";
        counts[key] = (counts[key] || 0) + 1;
      }
      return counts;
    }
    function recordTelemetrySample() {
      state.history.push({
        at: Date.now(),
        requests: httpRequestsTotal(),
        errors: httpErrorsTotal(),
        events: asArray(state.data.events).length
      });
      if (state.history.length > 36) {
        state.history = state.history.slice(state.history.length - 36);
      }
    }
    function renderBars(record) {
      const entries = Object.entries(record).filter(([, value]) => Number(value) > 0).sort((a, b) => Number(b[1]) - Number(a[1]));
      if (!entries.length) return '<div class="value-text">No data</div>';
      const max = Math.max(...entries.map(([, value]) => Number(value)), 1);
      return entries.map(([label, value]) => {
        const pct = Math.max(2, Math.round(Number(value) / max * 100));
        return '<div class="bar-row"><div class="bar-meta"><span>' + esc(label) + '</span><strong>' + esc(value) + '</strong></div>' +
          '<div class="bar-track"><div class="bar-fill" style="width:' + pct + '%"></div></div></div>';
      }).join("");
    }
    function renderSparkline(samples, key) {
      const values = samples.map((sample) => Number(sample[key] || 0));
      const width = 520;
      const height = 72;
      if (values.length < 2) {
        return '<svg class="sparkline" viewBox="0 0 ' + width + ' ' + height + '" role="img"><path d=""></path></svg>';
      }
      const min = Math.min(...values);
      const max = Math.max(...values);
      const span = Math.max(max - min, 1);
      const points = values.map((value, index) => {
        const x = values.length === 1 ? 0 : index / (values.length - 1) * (width - 16) + 8;
        const y = height - 10 - ((value - min) / span * (height - 22));
        return [x, y];
      });
      const line = points.map(([x, y], index) => (index ? "L" : "M") + x.toFixed(1) + " " + y.toFixed(1)).join(" ");
      const area = line + " L " + points[points.length - 1][0].toFixed(1) + " " + (height - 8) + " L " + points[0][0].toFixed(1) + " " + (height - 8) + " Z";
      return '<svg class="sparkline" viewBox="0 0 ' + width + ' ' + height + '" role="img">' +
        '<path class="area" d="' + area + '"></path><path d="' + line + '"></path></svg>';
    }
    function renderTopology(limit) {
      const graph = state.data.graph || {};
      const nodes = asArray(graph.nodes);
      const edges = asArray(graph.edges);
      const byRef = {};
      for (const node of nodes) byRef[node.ref] = node;
      const pipelines = nodes.filter((node) => node.domain === "pipeline").slice(0, limit || 14);
      const listenerRefs = unique(edges.filter((edge) => edge.kind === "ingress" && pipelines.some((node) => node.ref === edge.to)).map((edge) => edge.from));
      const egressRefs = unique(edges.filter((edge) => edge.kind === "egress" && pipelines.some((node) => node.ref === edge.from)).map((edge) => edge.to));
      const engineRefs = unique(edges.filter((edge) => edge.kind === "adapter_uses_engine" && egressRefs.includes(edge.from)).map((edge) => edge.to));
      const columns = [
        { domain: "listener", x: 24, refs: listenerRefs },
        { domain: "pipeline", x: 230, refs: pipelines.map((node) => node.ref) },
        { domain: "adapter", x: 520, refs: egressRefs },
        { domain: "engine", x: 720, refs: engineRefs }
      ];
      const width = 900;
      const rowHeight = 42;
      const height = Math.max(260, Math.max(...columns.map((column) => column.refs.length), 1) * rowHeight + 34);
      const positions = {};
      const nodeParts = [];
      for (const column of columns) {
        const refs = column.refs.length ? column.refs : [];
        refs.forEach((ref, index) => {
          const node = byRef[ref] || { ref, label: ref, domain: column.domain, kind: "" };
          const y = 18 + index * rowHeight;
          const w = column.domain === "pipeline" ? 220 : 150;
          positions[ref] = { x: column.x, y, w, h: 30 };
          const label = String(node.label || node.id || ref).slice(0, column.domain === "pipeline" ? 28 : 18);
          const sub = String(node.kind || node.domain || "").slice(0, 18);
          nodeParts.push('<g class="flow-node ' + esc(column.domain) + '" transform="translate(' + column.x + ',' + y + ')">' +
            '<rect width="' + w + '" height="30" rx="6"></rect><text x="9" y="14">' + esc(label) + '</text><text class="sub" x="9" y="25">' + esc(sub) + '</text></g>');
        });
      }
      const linkParts = [];
      function addLink(from, to, kind) {
        const a = positions[from];
        const b = positions[to];
        if (!a || !b) return;
        const x1 = a.x + a.w;
        const y1 = a.y + a.h / 2;
        const x2 = b.x;
        const y2 = b.y + b.h / 2;
        const mx = (x1 + x2) / 2;
        linkParts.push('<path class="flow-link ' + (kind === "ingress" || kind === "egress" ? "hot" : "") + '" d="M' + x1 + ' ' + y1 + ' C' + mx + ' ' + y1 + ' ' + mx + ' ' + y2 + ' ' + x2 + ' ' + y2 + '"></path>');
      }
      for (const edge of edges) {
        if (positions[edge.from] && positions[edge.to]) {
          addLink(edge.from, edge.to, edge.kind);
        }
      }
      if (!nodeParts.length) return '<div class="value-text">No topology data</div>';
      return '<svg class="flow-svg" viewBox="0 0 ' + width + ' ' + height + '" role="img">' + linkParts.join("") + nodeParts.join("") + '</svg>';
    }
    function unique(values) {
      const seen = {};
      return values.filter((value) => {
        if (!value || seen[value]) return false;
        seen[value] = true;
        return true;
      });
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
      $("dashboardTopologyCount").textContent = Math.min(graphPipelines.length, 10) + "/" + graphPipelines.length + " flows";
      $("dashboardTopology").innerHTML = renderTopology(10);
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
    function renderConfigFiles() {
      const files = asArray(state.data.configFiles);
      $("configFileCount").textContent = files.length + " files";
      $("configFiles").innerHTML = table(["Role", "Path", "Bytes", "Actions"], files.map((file) => {
        const editable = file.role !== "main" && file.exists !== false;
        const action = editable
          ? '<button class="button" data-config-draft="' + esc(file.include_path || file.path || "") + '">Edit Draft</button>'
          : '<span class="pill gray">' + esc(file.role === "main" ? "base" : "missing") + '</span>';
        return [
          '<span class="pill ' + (file.role === "main" ? "blue" : "") + '">' + esc(file.role || "include") + '</span>',
          esc(file.include_path || file.path || ""),
          esc(file.bytes || 0),
          action
        ];
      }));
    }
    function renderObservability() {
      const runtime = state.data.runtime || {};
      const stats = runtimeStats();
      const events = asArray(state.data.events);
      const graph = state.data.graph || {};
      const graphPipelines = asArray(graph.nodes).filter((node) => node.domain === "pipeline");
      const routes = collectRuntimeRoutes();
      const requests = httpRequestsTotal();
      const errors = httpErrorsTotal();
      const errorRate = requests > 0 ? (errors / requests * 100).toFixed(2) + "%" : "0%";
      const active = runtime.active || {};
      const relay = runtime.relay || {};
      $("observabilityMetrics").innerHTML = [
        metric("HTTP Requests", requests, "total since start"),
        metric("HTTP Errors", errors, errorRate + " error rate"),
        metric("Runtime Routes", routes.length, "projected HTTP routes"),
        metric("Open Channels", Number(relay.open_channels || 0), "relay channels"),
        metric("WebSockets", Number(active.websockets || runtime.active_websockets || 0), "active sessions"),
        metric("Uptime", formatDuration(Number(stats.uptime_seconds || runtime.uptime_seconds || 0)), "process lifetime")
      ].join("");
      $("observabilityFlowCount").textContent = Math.min(graphPipelines.length, 18) + "/" + graphPipelines.length + " flows";
      $("observabilityFlow").innerHTML = renderTopology(18);
      const executorCounts = countBy(routes, (route) => route.executor || "none");
      $("executorMixCount").textContent = Object.keys(executorCounts).length + " kinds";
      $("executorMix").innerHTML = renderBars(executorCounts);
      $("healthState").textContent = keys(state.errors).length ? "degraded" : "ok";
      $("healthState").className = "pill " + (keys(state.errors).length ? "red" : "");
      $("healthGrid").innerHTML = [
        healthItem(errors, "HTTP errors"),
        healthItem(nestedNumber(stats, "worker.rejected_total", 0), "worker rejects"),
        healthItem(nestedNumber(stats, "worker.timeouts_total", 0), "worker timeouts"),
        healthItem(nestedNumber(stats, "upstream.plan_errors_total", 0), "upstream errors"),
        healthItem(nestedNumber(stats, "mcp.pending_dropped_total", 0), "MCP drops"),
        healthItem(nestedNumber(stats, "feishu.send_errors", 0), "Feishu send errors")
      ].join("");
      $("trafficTrendCount").textContent = state.history.length + " samples";
      $("trafficTrend").innerHTML = renderSparkline(state.history, "requests") + rows({
        "Requests total": requests,
        "Errors total": errors,
        "Last sample": state.history.length ? new Date(state.history[state.history.length - 1].at).toLocaleTimeString() : ""
      });
      const eventCounts = countBy(events, (event) => event.type || event.action || "event");
      $("eventMixCount").textContent = events.length + " events";
      $("eventMix").innerHTML = renderBars(eventCounts);
      $("routeTableCount").textContent = routes.length + " routes";
      $("routeTable").innerHTML = table(["Listener", "Pipeline", "Executor", "Methods", "Paths"], routes.map((route) => [
        '<span class="pill">' + esc(route.listener_id || "") + '</span>',
        '<span class="pill blue">' + esc(route.pipeline_id || "") + '</span>',
        esc(route.executor || "none"),
        esc(asArray(route.methods).join(", ") || "*"),
        esc(asArray(route.paths).join(", ") || "*")
      ]));
    }
    function healthItem(value, label) {
      const number = Number(value || 0);
      return '<div class="health-item"><strong>' + esc(number) + '</strong><span>' + esc(label) + '</span></div>';
    }
    function formatDuration(seconds) {
      if (!Number.isFinite(seconds) || seconds <= 0) return "0s";
      const days = Math.floor(seconds / 86400);
      const hours = Math.floor(seconds % 86400 / 3600);
      const minutes = Math.floor(seconds % 3600 / 60);
      if (days) return days + "d " + hours + "h";
      if (hours) return hours + "h " + minutes + "m";
      return minutes + "m";
    }
    function safeId(raw) {
      return String(raw || "").trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, "_").replace(/^_+|_+$/g, "");
    }
    function quoteToml(value) {
      return JSON.stringify(String(value || ""));
    }
    function csvValues(value) {
      return String(value || "").split(",").map((item) => item.trim()).filter(Boolean);
    }
    function tomlStringArray(values) {
      return "[" + values.map(quoteToml).join(", ") + "]";
    }
    function generateAppToml() {
      const id = safeId($("newAppId").value);
      const kind = $("newAppKind").value;
      const host = $("newAppHost").value.trim() || "127.0.0.1";
      const port = Number.parseInt($("newAppPort").value.trim(), 10) || 20300;
      const entry = $("newAppEntry").value.trim();
      const moduleRoot = $("newAppModuleRoot").value.trim();
      const appId = id || "new_app";
      const pipelineId = $("newPipelineId").value.trim() || appId + ".app";
      const ingressRef = $("newIngressRef").value.trim() || "listener:" + appId;
      const egressRef = $("newEgressRef").value.trim() || "adapter:" + appId;
      const methods = csvValues($("newMatchMethods").value);
      const paths = csvValues($("newMatchPaths").value || "*");
      const hosts = csvValues($("newMatchHosts").value);
      const policies = csvValues($("newPolicyRefs").value);
      const transforms = csvValues($("newTransformRefs").value);
      $("newAppId").value = appId;
      if (!$("newPipelineId").value.trim()) $("newPipelineId").value = pipelineId;
      if (!$("newIngressRef").value.trim()) $("newIngressRef").value = ingressRef;
      if (!$("newEgressRef").value.trim()) $("newEgressRef").value = egressRef;
      if (!$("newAppIncludePath").value.trim()) {
        $("newAppIncludePath").value = "../examples/" + appId + "/" + appId + "-v2.toml";
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
        'id = ' + quoteToml(pipelineId) + '\\n' +
        'group = "' + appId + '"\\n' +
        'ingress = ' + quoteToml(ingressRef) + '\\n';
      if (policies.length) body += 'policies = ' + tomlStringArray(policies) + '\\n';
      if (transforms.length) body += 'transforms = ' + tomlStringArray(transforms) + '\\n';
      if (methods.length) body += 'match.methods = ' + tomlStringArray(methods) + '\\n';
      if (hosts.length) body += 'match.hosts = ' + tomlStringArray(hosts) + '\\n';
      body += 'match.paths = ' + tomlStringArray(paths.length ? paths : ["*"]) + '\\n' +
        'egress = ' + quoteToml(egressRef) + '\\n';
      $("newAppToml").value = body;
      return body;
    }
    async function saveAppDraft() {
      const id = safeId($("newAppId").value) || "new_app";
      const body = $("newAppToml").value.trim() ? $("newAppToml").value : generateAppToml();
      $("appDraftState").textContent = "saving";
      try {
        const draftId = "app." + id + ".toml";
        await fetch("/admin/drafts?id=" + encodeURIComponent(draftId), {
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
        state.activeDraftId = draftId;
        $("draftPublishPath").value = $("newAppIncludePath").value.trim() || defaultPublishPath(draftId);
        await openDraft(draftId);
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
      $("drafts").innerHTML = table(["Id", "Updated", "Bytes", "Actions"], drafts.map((draft) => {
        const id = draft.key || draft.id || "";
        return [
        '<span class="pill blue">' + esc(draft.key || draft.id || "") + '</span>',
        esc(draft.updated_at || draft.updatedAt || ""),
        esc(draft.bytes || draft.size || String(draft.value || "").length),
        '<button class="button" data-draft-open="' + esc(id) + '">Open</button>'
      ];
      }));
    }
    function defaultPublishPath(draftId) {
      let id = safeId(String(draftId || "").replace(/^app[.]/, "").replace(/[.]toml$/, ""));
      if (!id) id = "new_app";
      return "../examples/" + id + "/" + id + "-v2.toml";
    }
    function showDraftResult(value) {
      $("draftResult").textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
    }
    async function openDraft(id) {
      const draft = await apiRequest("/admin/drafts/" + encodeURIComponent(id));
      state.activeDraftId = draft.key || id;
      state.draftPublishResult = null;
      $("draftEditor").classList.remove("hidden");
      $("draftId").value = state.activeDraftId;
      $("draftBody").value = draft.value || "";
      if (!$("draftPublishPath").value.trim() || $("draftPublishPath").dataset.draftId !== state.activeDraftId) {
        $("draftPublishPath").value = defaultPublishPath(state.activeDraftId);
      }
      $("draftPublishPath").dataset.draftId = state.activeDraftId;
      showDraftResult({ draft_id: state.activeDraftId, status: "opened" });
      selectView("drafts");
    }
    async function openConfigFileDraft(path) {
      const result = await apiRequest("/admin/config/files/draft?path=" + encodeURIComponent(path), { method: "POST" });
      state.draftPublishResult = null;
      $("draftPublishPath").value = result.include_path || path;
      await openDraft(result.draft_id);
      $("draftPublishPath").value = result.include_path || path;
      showDraftResult(result);
    }
    async function saveDraftEditor() {
      const id = state.activeDraftId || $("draftId").value.trim();
      if (!id) throw new Error("draft_id_required");
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id), {
        method: "PUT",
        headers: { "content-type": "text/plain; charset=utf-8" },
        body: $("draftBody").value
      });
      showDraftResult(result);
      await refresh();
    }
    async function validateDraftEditor() {
      const id = state.activeDraftId || $("draftId").value.trim();
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/validate", { method: "POST" });
      showDraftResult(result);
    }
    async function diffDraftEditor() {
      const id = state.activeDraftId || $("draftId").value.trim();
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/diff");
      showDraftResult(result);
    }
    async function publishDraftEditor() {
      const id = state.activeDraftId || $("draftId").value.trim();
      const includePath = $("draftPublishPath").value.trim() || defaultPublishPath(id);
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/publish?path=" + encodeURIComponent(includePath), {
        method: "POST"
      });
      state.draftPublishResult = result;
      showDraftResult(result);
      await refresh();
    }
    async function applyPublishedConfig() {
      const configPath = state.draftPublishResult && state.draftPublishResult.config_path ? state.draftPublishResult.config_path : "";
      if (!configPath) throw new Error("publish_first");
      const result = await apiRequest("/admin/runtime/plan/replacement/apply?config=" + encodeURIComponent(configPath), {
        method: "POST"
      });
      showDraftResult(result);
      await refresh();
    }
    async function deleteDraftEditor() {
      const id = state.activeDraftId || $("draftId").value.trim();
      if (!id) throw new Error("draft_id_required");
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id), { method: "DELETE" });
      state.activeDraftId = "";
      state.draftPublishResult = null;
      $("draftEditor").classList.add("hidden");
      showDraftResult(result);
      await refresh();
    }
    async function runDraftAction(action) {
      try {
        showDraftResult({ status: "running", action });
        if (action === "save") await saveDraftEditor();
        if (action === "validate") await validateDraftEditor();
        if (action === "diff") await diffDraftEditor();
        if (action === "publish") await publishDraftEditor();
        if (action === "apply") await applyPublishedConfig();
        if (action === "delete") await deleteDraftEditor();
      } catch (err) {
        showDraftResult({ ok: false, error: err && err.message ? err.message : String(err) });
      }
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
      renderObservability();
      renderApps();
      renderConfigFiles();
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
    $("saveDraft").addEventListener("click", () => runDraftAction("save"));
    $("validateDraft").addEventListener("click", () => runDraftAction("validate"));
    $("diffDraft").addEventListener("click", () => runDraftAction("diff"));
    $("publishDraft").addEventListener("click", () => runDraftAction("publish"));
    $("applyPublishedConfig").addEventListener("click", () => runDraftAction("apply"));
    $("deleteDraft").addEventListener("click", () => runDraftAction("delete"));
    $("drafts").addEventListener("click", (event) => {
      const target = event.target && event.target.closest ? event.target.closest("[data-draft-open]") : null;
      if (target) {
        openDraft(target.getAttribute("data-draft-open")).catch((err) => showDraftResult({ ok: false, error: err && err.message ? err.message : String(err) }));
      }
    });
    $("configFiles").addEventListener("click", (event) => {
      const target = event.target && event.target.closest ? event.target.closest("[data-config-draft]") : null;
      if (target) {
        openConfigFileDraft(target.getAttribute("data-config-draft")).catch((err) => showDraftResult({ ok: false, error: err && err.message ? err.message : String(err) }));
      }
    });
    for (const id of ["newAppId", "newAppKind", "newAppPort", "newAppHost", "newAppEntry", "newAppModuleRoot", "newPipelineId", "newIngressRef", "newMatchMethods", "newMatchPaths", "newMatchHosts", "newPolicyRefs", "newTransformRefs", "newEgressRef"]) {
      $(id).addEventListener("input", generateAppToml);
      $(id).addEventListener("change", generateAppToml);
    }
    for (const button of document.querySelectorAll(".nav button")) {
      button.addEventListener("click", () => selectView(button.dataset.view));
    }
    selectView("dashboard");
    refresh();
  