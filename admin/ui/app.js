const endpoints = {
      runtime: "/admin/runtime",
      graph: "/admin/runtime/graph",
      configFiles: "/admin/config/files",
      sourceFiles: "/admin/source/files",
      schema: "/admin/schema",
      drafts: "/admin/drafts",
      events: "/admin/events?limit=80",
      executorLoads: "/admin/http/executors",
      stats: "/admin/stats"
    };
    const state = {
      activeView: "dashboard",
      authRequired: false,
      data: {},
      errors: {},
      history: [],
      activeDraftId: "",
      activeSourceDraftId: "",
      activeSourcePath: "",
      activeSourceLanguage: "",
      draftPublishResult: null,
      configDraft: false,
      draftBusy: false,
      validatedDraft: "",
      refreshing: false,
      trafficListener: "",
      trafficPipeline: null,
      trafficWindow: 60,
      trafficStatus: 'all',
      trafficSort: 'errors',
      trafficSlowMs: 500,
      trafficSequence: 0,
      trafficSamples: null,
      trafficSampleError: null,
      trafficSampleSequence: 0,
      trafficLogFocus: null,
      trafficFocus: null,
      refreshedAt: null
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
      const response = await fetch(endpointUrl(path), { headers: authHeaders(), cache: "no-store", signal: AbortSignal.timeout(8000) });
      const text = await response.text();
      let body = text;
      try { body = text ? JSON.parse(text) : null; } catch (_) {}
      if (!response.ok) {
        const error = body && body.error ? body.error : response.status + " " + response.statusText;
        const failure = new Error(error);
        failure.status = response.status;
        throw failure;
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
    async function refresh(background = false) {
      if (state.refreshing) return;
      state.refreshing = true;
      $("refresh").disabled = true;
      if (!background) $("status").textContent = "正在更新项目状态…";
      $("stateDot").className = "state-dot";
      const authenticated = await checkBrowserSession();
      if (!authenticated && !$("adminToken").value.trim()) {
        state.data = {}; state.errors = {}; state.authRequired = true;
        state.refreshing = false; $("refresh").disabled = false;
        render(); return;
      }
      if (!background) state.errors = {};
      state.authRequired = false;
      const entries = await Promise.all(Object.entries(endpoints).filter(([name]) => !background || ["runtime", "graph", "stats", "events", "configFiles", "executorLoads"].includes(name)).map(async ([name, path]) => {
        try {
          return [name, await loadEndpoint(name, path), null];
        } catch (err) {
          return [name, null, err && err.message ? err.message : String(err), err && err.status];
        }
      }));
      for (const [name, data, error, status] of entries) {
        if (status === 403) state.authRequired = true;
        delete state.errors[name];
        state.data[name] = data;
        if (error) state.errors[name] = error;
      }
      const main = asArray(state.data.configFiles).find(file => file.role === "main");
      state.data.plan = null;
      delete state.errors.plan;
      if (main && main.path && !state.authRequired) {
        try { state.data.plan = await loadEndpoint("plan", "/admin/runtime/plan/replacement?config=" + encodeURIComponent(main.path)); }
        catch (error) { state.errors.plan = "整项目生效检查暂不可用"; }
      }
      if (!state.authRequired) await loadTrafficWindow(false);
      state.refreshedAt = new Date();
      state.refreshing = false;
      $("refresh").disabled = false;
      recordTelemetrySample();
      render();
      window.dispatchEvent(new Event("vhttpd:refreshed"));
    }
    async function loadTrafficWindow(renderAfter = true) {
      const sequence=++state.trafficSequence;
      state.data.traffic=null; delete state.errors.traffic;
      if(renderAfter)renderDashboard();
      const query=new URLSearchParams({window:String(state.trafficWindow),listener:state.trafficListener});
      if(state.trafficPipeline!==null){query.set('route','1');query.set('pipeline',state.trafficPipeline);}
      try { const data=await loadEndpoint('traffic','/admin/http/traffic?'+query);if(sequence===state.trafficSequence)state.data.traffic=data; }
      catch(error){if(sequence===state.trafficSequence)state.errors.traffic='近期窗口读取失败，请刷新重试';}
      if(sequence===state.trafficSequence && state.trafficFocus)await loadTrafficDetails(false);
      if(sequence===state.trafficSequence && renderAfter)renderDashboard();
    }
    async function loadTrafficDetails(renderAfter=true) {
      const sequence=++state.trafficSampleSequence;
      state.trafficSamples=null;state.trafficSampleError=null;
      if(!state.trafficFocus)return;
      if(renderAfter)renderDashboard();
      const [listener,pipeline]=state.trafficFocus;
      const query=new URLSearchParams({listener,pipeline,window:String(state.trafficWindow),min_ms:'1'});
      try { const data=await loadEndpoint('requestDetails','/admin/http/requests?'+query);if(sequence===state.trafficSampleSequence)state.trafficSamples=data; }
      catch(error){if(sequence===state.trafficSampleSequence)state.trafficSampleError='慢请求明细读取失败，请重试。';}
      if(sequence===state.trafficSampleSequence && renderAfter)renderDashboard();
    }
    function renderRequestStages(model) {
      if(!model.available)return '<p>'+esc(model.bottleneck)+'</p>';
      return '<p><strong>'+esc(model.bottleneck)+'</strong></p><div class="request-stages">'+model.rows.map(row=>'<div><span>'+esc(row.label)+'</span><strong>'+esc(row.measured?row.ms.toFixed(2)+' ms':'未经过或未采集')+'</strong><div class="stage-track"><span style="width:'+row.share.toFixed(2)+'%"></span></div></div>').join('')+'</div>';
    }
    function renderSlowRequests(route) {
      const model=TrafficRequests.select(state.trafficSamples,[route.listener,route.id],state.trafficWindow,state.trafficSlowMs);
      const heading='<h4>最近慢请求（≥ '+esc(state.trafficSlowMs)+' ms）</h4><details class="stage-definition"><summary>分阶段耗时口径</summary><p>排队：等待内嵌 vjsx 执行槽；vjsx：HTTP JS 入口、Promise 解析、结果归一化及清理，包含 JS 内部等待；出口：终端交付、响应处理及上游 / 流等待。其他处理包含路由、初始化和未细分部分。各阶段不是 CPU 耗时；不支持的阶段显示未采集。</p></details>';
      if(!model.available)return heading+'<p>'+esc(state.trafficSampleError || '慢请求明细正在读取或已过期。')+'</p><button class="button" data-traffic-reload>刷新明细</button><span id="trafficCopyStatus" role="status"></span>';
      return heading+'<p>最近 '+state.trafficWindow/60+' 分钟，找到 '+model.requests.length+' 条保留的慢请求。每路由保留最近 50 条处理耗时 ≥ 1 ms 的已完成请求，明细不是全量记录；重启后清空。明细按完成时间精确筛选，趋势按 10 秒桶聚合。'+(model.retained>=50?'已达保留上限，较早请求可能已被淘汰。':'')+'</p>'+
        (model.requests.length?model.requests.map(item=>'<article class="request-sample"><div><strong>'+esc(new Date(item.at_unix*1000).toLocaleString())+'</strong><span>'+esc(item.method)+' · HTTP '+esc(item.status)+' · <strong>'+esc(item.duration_ms)+' ms</strong></span></div>'+renderRequestStages(item.stages)+'<p>定位编号：<button class="button" data-traffic-locate="'+esc(item.observation_id)+'" title="在宿主工作台筛选此请求日志">'+esc(item.observation_id)+'</button> <button class="button" data-traffic-copy="'+esc(item.observation_id)+'">复制编号</button></p><details '+(state.trafficLogFocus===item.observation_id?'open':'')+'><summary data-traffic-log="'+esc(item.observation_id)+'">查看关联完成日志</summary><pre>'+esc(item.log_line)+'</pre><small>此处只展示已采集的请求完成日志。可在宿主日志中搜索相同编号。</small></details></article>').join(''):'<p>保留的请求中没有符合当前时间和阈值的样本；这不表示未发生过慢请求。</p>')+'<button class="button" data-traffic-reload>刷新明细</button><span id="trafficCopyStatus" role="status"></span>';
    }
    function selectView(name) {
      state.activeView = name;
      if (["editor", "graph", "schema", "drafts", "raw"].includes(name)) $("advancedNav").open = true;
      for (const button of document.querySelectorAll(".nav button")) {
        button.setAttribute("aria-selected", button.dataset.view === name ? "true" : "false");
      }
      for (const view of document.querySelectorAll(".view")) {
        view.classList.toggle("hidden", view.id !== "view-" + name);
      }
      $("viewTitle").textContent = {
        dashboard: "运行总览",
        observability: "流量与指标",
        graph: "运行计划图",
        relay: "Relay",
        apps: "项目配置",
        editor: "源码编辑",
        schema: "配置参考",
        drafts: "配置草稿",
        events: "操作记录",
        raw: "原始快照"
      }[name] || name;
    }
    function renderStatus() {
      const runtimeOK = !!state.data.runtime && !state.errors.runtime && !state.authRequired;
      $("status").textContent = state.authRequired ? "登录已失效，请从工作台重新打开管理界面。" :
        (runtimeOK ? "管理接口已连接" : "管理接口未连接，以下状态无法确认") +
        (state.refreshedAt ? " · 最近检查 " + state.refreshedAt.toLocaleTimeString() : "");
      $("stateDot").className = "state-dot " + (runtimeOK ? "ok" : "error");
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
      if (state.errors.runtime || state.errors.stats || !state.data.runtime || !runtimeStats().http) return;
      const started = state.data.runtime.started_at_unix;
      if (state.history.length && state.history[state.history.length - 1].started !== started) state.history = [];
      state.history.push({
        started,
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
          nodeParts.push('<g class="flow-node ' + esc(column.domain) + '" data-node-ref="' + esc(ref) + '" tabindex="0" role="button" transform="translate(' + column.x + ',' + y + ')">' +
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
      const model = AdminOverview.build(state.data, state.errors, state.authRequired);
      $("overviewProject").textContent = model.project;
      $("overviewPath").textContent = model.path;
      $("overviewStates").innerHTML = model.states.map(item => '<article class="state-card ' + esc(item.tone) + '"><span>' + esc(item.label) + '</span><strong>' + esc(item.title) + '</strong><p>' + esc(item.detail) + '</p></article>').join("");
      $("overviewAttention").innerHTML = model.notices.map(item => '<div class="attention-item ' + esc(item.tone) + '"><div><strong>' + esc(item.title) + '</strong><p>' + esc(item.detail) + '</p></div>' + (item.view ? '<button class="button" data-overview-view="' + esc(item.view) + '">' + esc(item.action) + '</button>' : '') + '</div>').join("");
      $("metrics").innerHTML = model.metrics.map(item => metric(item.label, item.value, item.detail)).join("");
      renderExecutorOverview();
      renderBusinessTraffic(model.business);
      $("overviewChains").innerHTML = model.chains.length ? model.chains.map(chain => '<article class="request-chain"><div class="chain-heading"><strong>' + esc(chain.label) + '</strong><span class="value-text">' + esc(chain.match) + '</span></div><div class="chain-steps">' + chain.steps.map(step => '<button class="chain-step" data-node-ref="' + esc(step.ref) + '"><small>' + esc(step.label) + '</small><strong>' + esc(step.name) + '</strong><span>' + esc(step.detail) + '</span></button>').join('<span class="chain-arrow" aria-hidden="true">→</span>') + '</div></article>').join("") : '<p class="value-text">' + esc(model.graphAvailable ? '尚无请求链路，前往项目配置添加监听和路由。' : '无法读取运行计划，恢复管理连接后重试。') + '</p>';
      $("overviewEvents").innerHTML = model.events.length ? table(["时间", "操作", "对象"], model.events.map(event => [esc(event.time), esc(event.type), esc(event.target)])) : '<p class="value-text">' + (state.errors.events ? '操作记录暂不可用。' : '暂无操作记录。此处记录配置操作，不是业务请求日志。') + '</p>';
      $("overviewSources").innerHTML = model.sources.length ? model.sources.map(file => '<div class="overview-source"><span class="pill gray">' + esc(file.role === 'main' ? '主配置' : 'Include') + '</span><span title="' + esc(file.path) + '">' + esc(file.label) + '</span><button class="button" data-overview-source="' + esc(file.path) + '">编辑</button></div>').join('') : '<p class="value-text">配置来源暂不可用。</p>';
    }
    function executorModel(){return ExecutorOverview.build(state.authRequired || state.errors.executorLoads?null:state.data.executorLoads,asArray(state.data.configFiles));}
    function executorSourceButton(path,id,type,label){return '<button class="button" data-executor-source="'+esc(path)+'" data-executor-id="'+esc(id)+'" data-executor-type="'+esc(type)+'">'+esc(label)+'</button>';}
    function executorCard(item){
      const load=item.load;
      const concurrency=item.concurrency?load.occupied+' / '+load.capacity+' 槽 · 槽内任务 '+load.inflight:'—';
      const limits=item.known?'排队期限 '+load.queue_timeout_ms+' ms；'+(load.embedded?'独立执行超时：未采集':'后端读取期限 '+load.execution_timeout_ms+' ms'):'限制未确认';
      const routes=item.routes.map(route=>'<div class="executor-binding"><strong>'+esc(route.pipeline_id || '默认处理')+'</strong> → '+esc(route.adapter_id || '默认出口')+' '+route.sources.map(path=>executorSourceButton(path,route.pipeline_id,'route','编辑路由来源')).join('')+route.adapterSources.map(path=>executorSourceButton(path,route.adapter_id,'adapter','编辑出口来源')).join('')+'</div>').join('');
      return '<article class="executor-card"><h4>'+esc(item.listener_id+' / '+(item.primary?'默认池':item.pool))+' · '+esc(item.kind)+'</h4><p><strong>'+esc(item.status)+'</strong> · 占用 '+esc(concurrency)+' · HTTP 排队 '+(item.known?esc(load.waiting):'—')+' 人</p><p>累计排队等待 '+(item.known?esc(load.queue_waits_total):'—')+' 次 · 累计排队超时 '+(item.known?esc(load.queue_timeouts_total):'—')+' 次'+(item.recentTimeout?' · 最近 1 分钟出现过排队超时':'')+'</p><p class="value-text">'+esc(limits)+'；历史超时不代表当前仍阻塞。</p><p>'+item.engineSources.map(source=>executorSourceButton(source.path,source.id,'engine','编辑执行器 '+source.id)).join(' ')+'</p>'+(routes || '<p class="value-text">没有显式 HTTP 路由绑定；默认池可能服务未匹配请求或其他共享任务。</p>')+'</article>';
    }
    function renderExecutorOverview(){
      const model=executorModel();
      $('executorStatus').textContent=model.available?'截至 '+new Date(model.at*1000).toLocaleTimeString()+' · '+model.instances.length+' 个执行器实例':'执行器负载未确认；连接恢复后自动重试。';
      const routed=model.instances.filter(item=>item.routes.length),other=model.instances.filter(item=>!item.routes.length);
      $('executorInstances').innerHTML=model.available?routed.map(executorCard).join('')+(other.length?'<details><summary>其他执行器与默认池（'+other.length+'）</summary>'+other.map(executorCard).join('')+'</details>':'') || '<p>没有已登记的执行器实例。</p>':'';
    }
    function renderRouteExecutor(route){
      const model=executorModel();
      const instances=ExecutorOverview.forRoute(model,route.listener,route.id);
      return '<h4>对应执行器当前状态</h4><p class="value-text">此处为当前采样'+(model.available?'（截至 '+esc(new Date(model.at*1000).toLocaleTimeString())+'）':'')+'，不是该历史请求发生时的负载快照。</p>'+(model.available?instances.map(executorCard).join('') || '<p>此路由没有已确认的执行器绑定（终端出口或已移除的历史路由不会推断绑定）。</p>':'<p>执行器负载未确认。</p>');
    }
    function renderTrafficChart(title,points,key,unit,secondKey) {
      const valid=points.filter(point=>point[key]!==null);
      if(!valid.length)return '<article class="traffic-chart"><h4>'+esc(title)+'</h4><p class="value-text">暂无已完成请求的样本</p></article>';
      const max=Math.max(1,...valid.map(point=>point[key]),...(secondKey?points.map(point=>point[secondKey] || 0):[]));
      const x=i=>20+i*280/Math.max(1,points.length-1),y=value=>92-value/max*68;
      const line=field=>points.map((point,i)=>point[field]===null?'':(i===0 || points[i-1][field]===null?'M':'L')+x(i).toFixed(1)+' '+y(point[field]).toFixed(1)).join(' ');
      const circles=points.map((point,i)=>point[key]===null?'':'<circle cx="'+x(i)+'" cy="'+y(point[key])+'" r="2"><title>'+esc(new Date(point.at*1000).toLocaleTimeString()+' · '+point[key].toFixed(2)+' '+unit+' · '+point.count+' 次 / '+point.span+' 秒')+'</title></circle>').join('');
      return '<article class="traffic-chart"><h4>'+esc(title)+'</h4><svg viewBox="0 0 320 125" role="img" aria-label="'+esc(title+'，最多 '+max.toFixed(1)+' '+unit)+'"><text x="20" y="15">'+esc(max.toFixed(1)+' '+unit)+'</text><path class="trend-line" d="'+line(key)+'"/>'+(secondKey?'<path class="trend-max" d="'+line(secondKey)+'"/>':'')+circles+'<text x="20" y="117">'+esc(new Date(points[0].at*1000).toLocaleTimeString())+'</text><text x="300" y="117" text-anchor="end">'+esc(new Date(points[points.length-1].at*1000).toLocaleTimeString())+'</text></svg>'+(secondKey?'<small>实线：平均 · 虚线：最大；空白表示无请求</small>':'<small>悬停采样点查看时间与请求数</small>')+'</article>';
    }
    function renderBusinessTraffic(business) {
      if (business.available && state.trafficListener && !business.listeners.some(listener=>listener.id===state.trafficListener)) state.trafficListener='';
      const options='<option value="">全部监听</option>'+business.listeners.map(listener=>'<option value="'+esc(listener.id)+'">'+esc(listener.id)+' · '+esc(listener.address)+'</option>').join('');
      if (business.available && $('trafficListener').innerHTML !== options) $('trafficListener').innerHTML=options;
      $('trafficListener').value=state.trafficListener;
      const candidates=business.routes.filter(route=>!state.trafficListener || route.listener===state.trafficListener);
      const routeIds=[...new Set(candidates.map(route=>route.id))];
      if(business.available && state.trafficPipeline!==null && !routeIds.includes(state.trafficPipeline))state.trafficPipeline=null;
      const routeOptions='<option value="">全部路由</option>'+routeIds.map(id=>'<option value="'+esc(JSON.stringify(id))+'">'+esc(candidates.find(route=>route.id===id).label)+'</option>').join('');
      if(business.available && $('trafficPipeline').innerHTML!==routeOptions)$('trafficPipeline').innerHTML=routeOptions;
      $('trafficPipeline').value=state.trafficPipeline===null?'':JSON.stringify(state.trafficPipeline);
      const model=TrafficTrends.build(state.data.traffic,business,{listener:state.trafficListener,pipeline:state.trafficPipeline,seconds:state.trafficWindow,status:state.trafficStatus,sort:state.trafficSort,slowMs:state.trafficSlowMs});
      const number=value=>value===null?'—':value.toFixed(2);
      $('trafficWindowStatus').textContent=model.available?'截至 '+new Date(model.at*1000).toLocaleTimeString()+' · 最近 '+state.trafficWindow/60+' 分钟（10 秒桶） · 实际覆盖 '+model.span+' 秒'+(model.warmup?'，启动后尚未覆盖完整窗口':'')+(!$('autoRefresh').checked?' · 自动刷新已暂停':''):(state.errors.traffic || '近期窗口未确认或已过期；不将未知状态显示为零。');
      $('trafficWindowMetrics').innerHTML=[metric('近期请求速率',number(model.rps)+' req/s','已完成请求 / 实际覆盖秒数'),metric('近期错误率',number(model.errorRate)+'%',model.metrics?model.metrics.errors_total+' / '+model.metrics.requests_total+' 次（4xx + 5xx）':'暂无有效请求样本'),metric('近期平均 / P95',model.latency.average,'P95 '+model.latency.p95+' · 分桶估计')].join('');
      $('trafficCharts').innerHTML=model.available?[renderTrafficChart('请求速率',model.points,'requests','req/s'),renderTrafficChart('错误率',model.points,'errorRate','%'),renderTrafficChart('处理耗时',model.points,'average','ms','maximum')].join(''):'<p class="value-text">趋势暂不可用；恢复连接后自动读取服务端保留的窗口。</p>';
      $('trafficCoverage').textContent=model.available?'近期错误 '+model.recentIssues+' 条 · 仅历史错误 '+model.historicalIssues+' 条 · 慢路由 '+model.slowRoutes+' 条':'近期状态未确认；历史累计仍保留。';
      const value=(metrics,key)=>metrics?esc(metrics[key] ?? '—'):'—';
      const latencyCell=metrics=>{const v=AdminOverview.latency(metrics);return '<strong>'+esc(v.average)+'</strong><small>P95 '+esc(v.p95)+' · 最大 '+esc(v.max)+'</small>';};
      $('trafficListeners').innerHTML=table(['监听 / 地址','近期请求','近期 4xx / 5xx','历史累计错误','近期处理耗时','窗口状态','操作'],model.listeners.map(listener=>[
        '<strong>'+esc(listener.id)+'</strong><br><small>'+esc(listener.address)+'</small>',value(listener.recent,'requests_total'),value(listener.recent,'client_errors_total')+' / '+value(listener.recent,'server_errors_total'),value(listener.historical,'errors_total'),latencyCell(listener.recent),esc(listener.status),'<button class="button" data-traffic-listener="'+esc(listener.id)+'">查看路由</button>'
      ]));
      $('trafficRoutes').innerHTML=model.rows.length?table(['路由 / 匹配','监听','近期请求','近期 / 累计错误','近期处理耗时','窗口状态','定位'],model.rows.map(route=>[
        '<strong>'+esc(route.label)+'</strong><br><small>'+esc(route.match || (route.id?'历史路由 / 已移除':'无编译路由'))+'</small>',esc(route.listener),value(route.recent,'requests_total'),value(route.recent,'errors_total')+' / '+value(route.metrics,'errors_total'),latencyCell(route.recent),esc(route.status),'<button class="button" data-traffic-route="'+esc(JSON.stringify([route.listener,route.id]))+'">'+(route.slow?'查看慢请求':route.recentIssue || route.historicalIssue?'定位异常':'查看详情')+'</button>'
      ])):'<p class="value-text">此范围没有符合条件的路由。没有请求或读取失败不表示故障已恢复。</p>';
      const focus=state.trafficFocus,route=focus && model.allRows.find(route=>route.listener===focus[0] && route.id===focus[1]);
      $('trafficDetails').classList.toggle('hidden',!route);if(!route)return;
      const failures=business.failures.filter(error=>error.listener===route.listener && error.pipeline_id===route.id);
      $('trafficDetails').innerHTML='<div class="panel-header"><h4>'+esc(route.listener+' → '+route.label)+'</h4><button class="button" data-traffic-close>关闭详情</button></div><p>'+esc(route.status)+'；近期错误 '+value(route.recent,'errors_total')+' 次，历史累计 '+value(route.metrics,'errors_total')+' 次。</p>'+
        (route.source?'<p class="value-text">配置来源：'+esc(route.source)+'</p><button class="button" data-traffic-source="'+esc(route.source)+'" data-traffic-pipeline="'+esc(route.id)+'">编辑此路由来源</button>':'<p class="value-text">未找到当前配置来源，请检查默认处理或历史路由。</p>')+
        renderRouteExecutor(route)+renderSlowRequests(route)+'<details><summary>最近错误样本（每监听最多 20 条）</summary>'+
        (failures.length?table(['时间','范围','状态码','处理耗时','日志定位编号'],failures.map(error=>[esc(new Date(error.at_unix*1000).toLocaleString()),model.available && error.at_unix>=state.data.traffic.start_unix && error.at_unix<=state.data.traffic.at_unix?'所选近期窗口':'历史样本',esc(error.status),esc(error.duration_ms)+' ms','<button class="button" data-traffic-locate="'+esc(error.observation_id)+'" title="在宿主工作台筛选此请求日志">'+esc(error.observation_id)+'</button>'])):'<p class="value-text">没有保留的错误样本，可能已超出最近 20 条的范围。</p>')+'</details><p class="value-text">在工作台日志搜索定位编号；响应头 x-vhttpd-observation-id 也包含该编号。延迟以已完成请求为准，进行中的长请求尚未计入。</p>';
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
        const editable = file.exists !== false;
        const action = editable
          ? '<button class="button" data-config-draft="' + esc(file.include_path || file.path || "") + '">编辑 TOML</button>'
          : '<span class="pill gray">' + esc(file.role === "main" ? "base" : "missing") + '</span>';
        return [
          '<span class="pill ' + (file.role === "main" ? "blue" : "") + '">' + esc(file.role || "include") + '</span>',
          esc(file.include_path || file.path || ""),
          esc(file.bytes || 0),
          action
        ];
      }));
    }
    function renderSourceFiles() {
      const files = asArray(state.data.sourceFiles);
      $("sourceFileCount").textContent = files.length + " files";
      $("sourceFiles").innerHTML = table(["Type", "Path", "Bytes", "Actions"], files.map((file) => {
        const path = file.include_path || file.path || "";
        const editable = file.exists !== false && file.language;
        return [
          '<span class="pill ' + (file.language === "toml" ? "blue" : "") + '">' + esc(file.language || file.role || "source") + '</span>',
          esc(path),
          esc(file.bytes || 0),
          editable
            ? '<button class="button" data-source-open="' + esc(path) + '">Open</button>'
            : '<span class="pill gray">missing</span>'
        ];
      }));
    }
    function sourceLanguageFromPath(path) {
      const ext = String(path || "").split(".").pop().toLowerCase();
      if (ext === "toml") return "toml";
      if (["ts", "mts", "cts"].includes(ext)) return "typescript";
      if (["js", "mjs", "cjs"].includes(ext)) return "javascript";
      return "text";
    }
    function highlightSource(text, language) {
      const source = String(text || "");
      if (language === "toml") return highlightToml(source);
      if (language === "typescript" || language === "javascript") return highlightTypescript(source);
      if (language === "json") return highlightJson(source);
      return esc(source);
    }
    function lineNumbers(text) {
      const lines = String(text || "").split("\n").length;
      let out = "";
      for (let i = 1; i <= Math.max(lines, 1); i++) out += i + "\n";
      return out;
    }
    function highlightToml(text) {
      return text.split("\n").map((line) => {
        const match = line.match(/^(\s*)(\[[^\]]+\])/);
        if (match) {
          return esc(match[1]) + '<span class="tok-section">' + esc(match[2]) + '</span>' + esc(line.slice(match[0].length));
        }
        const commentIndex = line.indexOf("#");
        const code = commentIndex >= 0 ? line.slice(0, commentIndex) : line;
        const comment = commentIndex >= 0 ? line.slice(commentIndex) : "";
        const rendered = esc(code)
          .replace(/^(\s*)([A-Za-z0-9_.-]+)(\s*=)/, '$1<span class="tok-key">$2</span>$3')
          .replace(/(&quot;[^&]*?&quot;)/g, '<span class="tok-string">$1</span>')
          .replace(/\b(true|false)\b/g, '<span class="tok-bool">$1</span>')
          .replace(/\b(\d+(?:\.\d+)?)\b/g, '<span class="tok-number">$1</span>');
        return rendered + (comment ? '<span class="tok-comment">' + esc(comment) + '</span>' : "");
      }).join("\n");
    }
    function highlightTypescript(text) {
      const keywords = "as|async|await|break|case|catch|class|const|continue|default|delete|do|else|export|extends|false|finally|for|from|function|if|import|in|interface|let|new|null|of|return|switch|throw|true|try|type|undefined|var|while";
      const pattern = new RegExp("(//.*$|/\\*[\\s\\S]*?\\*/|'(?:\\\\.|[^'])*'|\"(?:\\\\.|[^\"])*\"|`(?:\\\\.|[^`])*`|\\b(?:" + keywords + ")\\b|\\b\\d+(?:\\.\\d+)?\\b)", "gm");
      let out = "";
      let last = 0;
      text.replace(pattern, (token, _match, offset) => {
        out += esc(text.slice(last, offset));
        const safe = esc(token);
        if (token.startsWith("//") || token.startsWith("/*")) out += '<span class="tok-comment">' + safe + '</span>';
        else if (token.startsWith("'") || token.startsWith('"') || token.startsWith("`")) out += '<span class="tok-string">' + safe + '</span>';
        else if (/^\d/.test(token)) out += '<span class="tok-number">' + safe + '</span>';
        else if (token === "true" || token === "false" || token === "null" || token === "undefined") out += '<span class="tok-bool">' + safe + '</span>';
        else out += '<span class="tok-keyword">' + safe + '</span>';
        last = offset + token.length;
        return token;
      });
      return out + esc(text.slice(last));
    }
    function highlightJson(text) {
      const pattern = /("(?:\\.|[^"\\])*"(?=\s*:)|"(?:\\.|[^"\\])*"|\btrue\b|\bfalse\b|\bnull\b|-?\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b)/gi;
      let out = "";
      let last = 0;
      text.replace(pattern, (token, _match, offset) => {
        out += esc(text.slice(last, offset));
        const safe = esc(token);
        if (token[0] === '"' && /"\s*$/.test(token)) out += '<span class="tok-key">' + safe + '</span>';
        else if (token[0] === '"') out += '<span class="tok-string">' + safe + '</span>';
        else if (token === "true" || token === "false" || token === "null") out += '<span class="tok-bool">' + safe + '</span>';
        else out += '<span class="tok-number">' + safe + '</span>';
        last = offset + token.length;
        return token;
      });
      return out + esc(text.slice(last));
    }
    function editorParts(prefix) {
      return {
        input: $(prefix + "Input") || $(prefix),
        highlight: $(prefix + "Highlight"),
        lines: $(prefix + "Lines")
      };
    }
    function updateEditorHighlight(prefix, language) {
      const parts = editorParts(prefix);
      if (!parts.input || !parts.highlight) return;
      resizeEditor(prefix);
      parts.highlight.innerHTML = highlightSource(parts.input.value, language) + "\n";
      if (parts.lines) parts.lines.textContent = lineNumbers(parts.input.value);
    }
    function syncEditorScroll(prefix) {
      const parts = editorParts(prefix);
      if (!parts.input || !parts.highlight) return;
      const editor = parts.input.closest(".code-editor");
      if (editor && editor.classList.contains("readonly")) {
        if (parts.lines) parts.lines.scrollTop = parts.highlight.scrollTop;
        return;
      }
      parts.highlight.scrollTop = parts.input.scrollTop;
      parts.highlight.scrollLeft = parts.input.scrollLeft;
      if (parts.lines) parts.lines.scrollTop = parts.input.scrollTop;
    }
    function resizeEditor(prefix) {
      const parts = editorParts(prefix);
      if (!parts.input) return;
      const editor = parts.input.closest(".code-editor");
      if (!editor) return;
      const lines = Math.max(String(parts.input.value || "").split("\n").length, 1);
      const lineHeight = 20.15;
      const chrome = 30;
      if (editor.classList.contains("readonly")) {
        const min = editor.classList.contains("modal-code") ? 180 : 220;
        const max = editor.id === "rawCodeEditor"
          ? Math.max(260, window.innerHeight - 170)
          : Math.max(240, Math.min(520, Math.round(window.innerHeight * 0.56)));
        const height = Math.max(min, Math.min(max, Math.ceil(lines * lineHeight + chrome)));
        editor.style.setProperty("--viewer-height", height + "px");
        return;
      }
      const min = editor.id === "rawCodeEditor" ? 220 : editor.classList.contains("modal-code") ? 180 : 220;
      const max = editor.id === "rawCodeEditor"
        ? Math.max(260, window.innerHeight - 170)
        : editor.classList.contains("modal-code")
          ? Math.max(240, Math.min(520, Math.round(window.innerHeight * 0.56)))
          : Math.max(280, Math.min(620, Math.round(window.innerHeight * 0.62)));
      const height = Math.max(min, Math.min(max, Math.ceil(lines * lineHeight + chrome)));
      editor.style.setProperty("--editor-height", height + "px");
    }
    function setEditorValue(prefix, value, language) {
      const parts = editorParts(prefix);
      if (!parts.input) return;
      parts.input.value = value || "";
      resizeEditor(prefix);
      updateEditorHighlight(prefix, language || "text");
      syncEditorScroll(prefix);
    }
    function updateSourceHighlight() {
      updateEditorHighlight("sourceEditor", state.activeSourceLanguage);
    }
    function syncSourceEditorScroll() {
      syncEditorScroll("sourceEditor");
    }
    function setSourceEditorValue(value, language) {
      state.activeSourceLanguage = language || state.activeSourceLanguage || "text";
      setEditorValue("sourceEditor", value, state.activeSourceLanguage);
    }
    function renderObservability() {
      const runtime = state.data.runtime || {};
      const stats = runtimeStats();
      const available = !!state.data.runtime && !state.errors.runtime && !state.errors.stats && !!stats.http;
      const stat = path => available ? nestedNumber(stats, path, null) : null;
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
        metric("管理 HTTP 请求", available ? requests : "—", "当前管理监听累计"),
        metric("管理 HTTP 错误", available ? errors : "—", available ? errorRate + " 累计错误率" : "统计暂不可用"),
        metric("已登记路由", state.data.runtime ? routes.length : "—", "运行时 HTTP 路由"),
        metric("Relay 通道", state.data.runtime ? (relay.open_channels ?? "—") : "—", "当前打开的通道"),
        metric("WebSocket", state.data.runtime ? (active.websockets ?? "—") : "—", "当前管理实例中的会话"),
        metric("运行时长", state.data.runtime ? formatDuration(Number(runtime.uptime_seconds)) : "—", "当前进程")
      ].join("");
      $("observabilityFlowCount").textContent = Math.min(graphPipelines.length, 18) + "/" + graphPipelines.length + " flows";
      $("observabilityFlow").innerHTML = renderTopology(18);
      const executorCounts = countBy(routes, (route) => route.executor || "none");
      $("executorMixCount").textContent = Object.keys(executorCounts).length + " kinds";
      $("executorMix").innerHTML = renderBars(executorCounts);
      $("healthState").textContent = available ? "本次进程累计" : "统计未确认";
      $("healthState").className = "pill gray";
      $("healthGrid").innerHTML = [
        healthItem(stat("http.errors_total"), "管理 HTTP 错误"),
        healthItem(stat("worker.rejected_total"), "worker rejects"),
        healthItem(stat("worker.timeouts_total"), "worker timeouts"),
        healthItem(stat("upstream.plan_errors_total"), "upstream errors"),
        healthItem(stat("mcp.pending_dropped_total"), "MCP drops"),
        healthItem(stat("feishu.send_errors"), "Feishu send errors")
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
      const number = value == null ? "—" : Number(value);
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
        return '<div class="node clickable-node" data-node-ref="' + esc(node.ref || node.id) + '"><strong>' + esc(node.ref || node.id) + '</strong>' +
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
      if (state.draftBusy) return;
      state.configDraft = false;
      state.validatedDraft = "";
      $("draftEditorHome").appendChild($("draftEditor"));
      $("draftPublishPath").readOnly = false;
      $("draftStage").textContent = "修改后保存并校验，再发布配置。";
      updateDraftButtons();
      $("applyPublishedConfig").classList.add("hidden");
      $("configDraftNote").classList.remove("hidden");
      const draft = await apiRequest("/admin/drafts/" + encodeURIComponent(id));
      state.activeDraftId = draft.key || id;
      state.draftPublishResult = null;
      $("draftEditor").classList.remove("hidden");
      $("draftId").value = state.activeDraftId;
      setEditorValue("draftEditor", draft.value || "", "toml");
      if (!$("draftPublishPath").value.trim() || $("draftPublishPath").dataset.draftId !== state.activeDraftId) {
        $("draftPublishPath").value = defaultPublishPath(state.activeDraftId);
      }
      $("draftPublishPath").dataset.draftId = state.activeDraftId;
      showDraftResult({ draft_id: state.activeDraftId, status: "opened" });
      selectView("drafts");
    }
    async function openConfigFileDraft(path) {
      if (state.draftBusy) return;
      const result = await apiRequest("/admin/config/files/draft?path=" + encodeURIComponent(path), { method: "POST" });
      if (!result.ok) throw new Error(result.error || "无法打开配置来源");
      state.draftPublishResult = null;
      $("draftPublishPath").value = result.include_path || path;
      await openDraft(result.draft_id);
      $("draftPublishPath").value = result.include_path || path;
      $("applyPublishedConfig").classList.add("hidden");
      $("configDraftNote").classList.remove("hidden");
      state.configDraft = true;
      $("draftPublishPath").readOnly = true;
      $("draftStage").textContent = "配置来源：" + (result.include_path || path) + "。修改后按整个项目校验。";
      $("configEditorSlot").classList.remove("hidden");
      $("configEditorSlot").appendChild($("draftEditor"));
      selectView("apps");
      $("draftEditor").scrollIntoView({block: "start"});
      updateDraftButtons();
      showDraftResult(result);
    }
    function showSourceResult(value) {
      $("sourceResult").textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
    }
    async function openSourceFileDraft(path) {
      const result = await apiRequest("/admin/source/files/draft?path=" + encodeURIComponent(path), { method: "POST" });
      if (!result.ok) throw new Error(result.error || "source_open_failed");
      state.activeSourceDraftId = result.draft_id;
      state.activeSourcePath = result.include_path || path;
      state.activeSourceLanguage = result.language || sourceLanguageFromPath(state.activeSourcePath);
      $("sourceEditorPanel").classList.remove("hidden");
      $("sourcePath").value = state.activeSourcePath;
      $("sourceLanguage").value = state.activeSourceLanguage;
      $("sourceDraftId").value = state.activeSourceDraftId;
      $("sourceEditorState").textContent = "opened";
      setSourceEditorValue(result.entry && result.entry.value ? result.entry.value : "", state.activeSourceLanguage);
      showSourceResult(result);
      selectView("editor");
    }
    async function saveSourceDraftEditor() {
      const id = state.activeSourceDraftId || $("sourceDraftId").value.trim();
      if (!id) throw new Error("source_draft_id_required");
      $("sourceEditorState").textContent = "saving";
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id), {
        method: "PUT",
        headers: { "content-type": "text/plain; charset=utf-8" },
        body: $("sourceEditorInput").value
      });
      $("sourceEditorState").textContent = "saved";
      showSourceResult(result);
      await refresh();
    }
    async function publishSourceDraftEditor() {
      const id = state.activeSourceDraftId || $("sourceDraftId").value.trim();
      const path = state.activeSourcePath || $("sourcePath").value.trim();
      if (!id || !path) throw new Error("source_publish_target_required");
      $("sourceEditorState").textContent = "publishing";
      const result = await apiRequest("/admin/source/drafts/" + encodeURIComponent(id) + "/publish?path=" + encodeURIComponent(path), {
        method: "POST"
      });
      $("sourceEditorState").textContent = result.ok ? "published" : "error";
      showSourceResult(result);
      await refresh();
    }
    async function validateSourceDraftEditor() {
      if (state.activeSourceLanguage !== "toml") {
        showSourceResult({ ok: false, error: "validate_only_supports_toml" });
        return;
      }
      const id = state.activeSourceDraftId || $("sourceDraftId").value.trim();
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/validate", { method: "POST" });
      showSourceResult(result);
    }
    async function runSourceAction(action) {
      try {
        showSourceResult({ status: "running", action });
        if (action === "save") await saveSourceDraftEditor();
        if (action === "publish") await publishSourceDraftEditor();
        if (action === "validate") await validateSourceDraftEditor();
      } catch (err) {
        $("sourceEditorState").textContent = "error";
        showSourceResult({ ok: false, error: err && err.message ? err.message : String(err) });
      }
    }
    async function saveDraftEditor() {
      const id = state.activeDraftId || $("draftId").value.trim();
      if (!id) throw new Error("draft_id_required");
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id), {
        method: "PUT",
        headers: { "content-type": "text/plain; charset=utf-8" },
        body: $("draftEditorInput").value
      });
      showDraftResult(result);
      await refresh();
    }
    async function validateDraftEditor() {
      state.validatedDraft = "";
      $("draftStage").textContent = "正在保存草稿并校验整个项目…";
      await saveDraftEditor();
      const candidate = draftFingerprint();
      const id = state.activeDraftId || $("draftId").value.trim();
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/validate", { method: "POST" });
      showDraftResult(result);
      state.validatedDraft = result.ok ? candidate : "";
      $("draftStage").textContent = result.ok ? "整个项目校验通过，可以发布配置。" : "校验失败：" + (result.error || "请查看技术详情并修正配置。");
    }
    async function diffDraftEditor() {
      await validateDraftEditor();
      if (state.validatedDraft !== draftFingerprint()) return;
      $("draftTechnical").open = true;
      const id = state.activeDraftId || $("draftId").value.trim();
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/diff");
      showDraftResult(result);
    }
    async function publishDraftEditor() {
      if (state.validatedDraft !== draftFingerprint()) throw new Error("配置已修改，请先保存并校验。");
      const id = state.activeDraftId || $("draftId").value.trim();
      const includePath = $("draftPublishPath").value.trim() || defaultPublishPath(id);
      const result = await apiRequest("/admin/drafts/" + encodeURIComponent(id) + "/publish?path=" + encodeURIComponent(includePath), {
        method: "POST"
      });
      if (!result.ok) throw new Error(result.error || "发布失败");
      state.validatedDraft = "";
      state.draftPublishResult = result;
      $("draftStage").textContent = "已发布到项目文件。回到工作台，点击‘重启并生效’，工作台会自动检查整个项目。";
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
    function draftFingerprint() {
      return JSON.stringify([state.activeDraftId, $("draftPublishPath").value, $("draftEditorInput").value]);
    }
    function updateDraftButtons() {
      for (const id of ["saveDraft", "validateDraft", "diffDraft", "deleteDraft", "applyPublishedConfig"]) $(id).disabled = state.draftBusy;
      $("publishDraft").disabled = state.draftBusy || !state.validatedDraft || state.validatedDraft !== draftFingerprint();
      $("draftEditorInput").readOnly = state.draftBusy;
      $("draftPublishPath").readOnly = state.draftBusy || state.configDraft;
      $("saveDraft").classList.toggle("hidden", state.configDraft);
      $("draftId").parentElement.classList.toggle("hidden", state.configDraft);
      document.querySelector('label[for="draftPublishPath"]').textContent = state.configDraft ? "配置来源（发布写回此文件）" : "Publish Include Path";
    }
    function invalidateDraft() {
      state.validatedDraft = "";
      $("draftStage").textContent = "有未发布修改，请保存并校验整个项目。";
      updateDraftButtons();
    }
    async function runDraftAction(action) {
      if (state.draftBusy) return;
      state.draftBusy = true;
      updateDraftButtons();
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
        const message = err.message || String(err);
        $("draftStage").textContent = message.startsWith("runtime_plan_unresolved_ref:")
          ? "校验失败：配置引用不存在（" + message.slice("runtime_plan_unresolved_ref:".length) + "），请检查 Pipeline 引用并重新校验。"
          : (action === "validate" ? "项目校验失败：" : "操作失败：") + message;
      } finally { state.draftBusy = false; updateDraftButtons(); }
    }
    function renderEvents() {
      const events = AdminOverview.eventRows(state.data.events);
      $("eventCount").textContent = events.length + " 条记录";
      $("events").innerHTML = table(["时间", "操作", "对象"], events.map(event => [esc(event.time),esc(event.type),esc(event.target)]));
    }
    function renderRaw() {
      setEditorValue("rawEditor", JSON.stringify({ data: state.data, errors: state.errors }, null, 2), "json");
    }
    function graphNodeByRef(ref) {
      const graph = state.data.graph || {};
      return asArray(graph.nodes).find((node) => node.ref === ref || node.id === ref);
    }
    function graphEdgesForRef(ref) {
      const graph = state.data.graph || {};
      return asArray(graph.edges).filter((edge) => edge.from === ref || edge.to === ref);
    }
    function showNodeDetails(ref) {
      const node = graphNodeByRef(ref);
      if (!node) return;
      const edges = graphEdgesForRef(node.ref || ref);
      $("nodeModalTitle").textContent = node.label || node.id || node.ref || "Node";
      $("nodeModalSubtitle").textContent = [node.ref, node.domain, node.kind].filter(Boolean).join(" / ");
      $("nodeModalSummary").innerHTML = rows({
        "Ref": node.ref || "",
        "Domain": node.domain || "",
        "Kind": node.kind || "",
        "Group": node.group || "",
        "Incoming": edges.filter((edge) => edge.to === node.ref).map((edge) => edge.from + " (" + edge.kind + ")").join(", "),
        "Outgoing": edges.filter((edge) => edge.from === node.ref).map((edge) => edge.to + " (" + edge.kind + ")").join(", ")
      });
      setEditorValue("nodeEditor", JSON.stringify({ node, edges }, null, 2), "json");
      $("nodeModal").classList.remove("hidden");
    }
    function closeNodeDetails() {
      $("nodeModal").classList.add("hidden");
    }
    function renderRelay() {
      const runtime = state.data.runtime;
      const relay = runtime && runtime.relay;
      const available = !!relay && !state.errors.runtime;
      $("relayAvailability").textContent = available
        ? "Runtime snapshot. Refresh to read the latest connection and channel state."
        : "Relay runtime unavailable. Start the instance and sign in to read its state.";
      $("relayMetrics").innerHTML = available ? [
        metric("Configured Relays", relay.descriptor_count ?? "—", "this instance"),
        metric("Agents", relay.agent_count ?? "—", "runtime agents"),
        metric("Carriers", relay.carrier_count ?? "—", "registered carriers"),
        metric("Open Channels", relay.open_channels ?? "—", "runtime channels"),
        metric("Sessions", relay.session_count ?? "—", "runtime sessions"),
        metric("Pending Frames", relay.pending_frames ?? "—", "buffered frames")
      ].join("") : "";
      $("relayAgents").innerHTML = table(["Relay", "Node", "State", "Attempts", "Next attempt", "Last error"], asArray(relay && relay.agents).map(agent => [
        esc(agent.relay_id), esc(agent.node_id), esc(agent.state), esc(agent.attempt),
        esc(agent.state === "backoff" && agent.next_attempt_at_ms > 0 ? new Date(agent.next_attempt_at_ms).toLocaleString() : "—"), esc(agent.last_error || "—")
      ]));
      $("relayCarriers").innerHTML = table(["Relay", "Carrier"], asArray(relay && relay.carriers).map(carrier => [esc(carrier.relay_id), esc(carrier.carrier_id)]));
      $("relayChannels").innerHTML = table(["Channel", "Node", "Route", "State", "Buffered", "Returned"], asArray(relay && relay.channels).map(channel => [
        esc(channel.id), esc(channel.node_id), esc(channel.route), channel.open ? "open" : "closed", esc(channel.buffered_len), esc(channel.returned_len)
      ]));
      $("relaySessions").innerHTML = table(["Session", "Endpoints", "Links", "Pending frames"], asArray(relay && relay.sessions).map(session => [
        esc(session.id), esc(session.endpoint_count), esc(session.link_count), esc(session.pending_frames)
      ]));
    }
    function render() {
      renderStatus();
      renderDashboard();
      renderObservability();
      renderRelay();
      renderApps();
      renderConfigFiles();
      renderSourceFiles();
      renderGraph();
      renderSchema();
      renderDrafts();
      renderEvents();
      renderRaw();
    }
    localStorage.removeItem("vhttpd.admin.base");
    // Remove legacy persistence. Manual tokens remain only in this page's memory.
    localStorage.removeItem("vhttpd.admin.token");
    $("adminToken").value = "";
    async function checkBrowserSession() {
      let authenticated = false;
      try {
        const response = await fetch("/admin/auth/session", { cache: "no-store", credentials: "same-origin", signal: AbortSignal.timeout(8000) });
        if (response.ok) authenticated = (await response.json()).authenticated === true;
      } catch (_) {}
      $("authStatus").textContent = authenticated ? "已通过工作台登录" : "从工作台打开可自动登录；也可手动填写 token。";
      $("logout").hidden = !authenticated;
      $("tokenLabel").hidden = authenticated;
      $("tokenActions").style.display = authenticated ? "none" : "";
      if (authenticated) $("adminToken").value = "";
      return authenticated;
    }
    $("logout").addEventListener("click", async () => {
      try {
        await apiRequest("/admin/auth/logout", { method: "POST" });
        $("adminToken").value = "";
        await refresh();
      } catch (error) { $("authStatus").textContent = error.message; }
    });
    function applyToken() {
      refresh();
    }
    $("applyToken").addEventListener("click", applyToken);
    $("adminToken").addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        applyToken();
      }
    });
    $("refresh").addEventListener("click", () => refresh());
    $("generateAppConfig").addEventListener("click", generateAppToml);
    $("saveAppDraft").addEventListener("click", saveAppDraft);
    $("saveSourceDraft").addEventListener("click", () => runSourceAction("save"));
    $("publishSourceDraft").addEventListener("click", () => runSourceAction("publish"));
    $("validateSourceDraft").addEventListener("click", () => runSourceAction("validate"));
    $("sourceEditorInput").addEventListener("input", updateSourceHighlight);
    $("sourceEditorInput").addEventListener("scroll", syncSourceEditorScroll);
    $("sourceEditorInput").addEventListener("keydown", (event) => {
      if (event.key === "Tab") {
        event.preventDefault();
        const input = event.currentTarget;
        const start = input.selectionStart;
        const end = input.selectionEnd;
        input.value = input.value.slice(0, start) + "  " + input.value.slice(end);
        input.selectionStart = input.selectionEnd = start + 2;
        updateSourceHighlight();
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        runSourceAction("save");
      }
    });
    $("saveDraft").addEventListener("click", () => runDraftAction("save"));
    $("validateDraft").addEventListener("click", () => runDraftAction("validate"));
    $("diffDraft").addEventListener("click", () => runDraftAction("diff"));
    $("publishDraft").addEventListener("click", () => runDraftAction("publish"));
    $("applyPublishedConfig").addEventListener("click", () => runDraftAction("apply"));
    $("deleteDraft").addEventListener("click", () => runDraftAction("delete"));
    $("draftEditorInput").addEventListener("input", () => { updateEditorHighlight("draftEditor", "toml"); invalidateDraft(); });
    $("draftPublishPath").addEventListener("input", invalidateDraft);
    $("configureProject").addEventListener("click", () => {
      if (state.draftBusy) return;
      if (window.CommonConfigUI) { CommonConfigUI.open(); return; }
      if (state.configDraft && state.activeDraftId) { selectView("apps"); $("draftEditor").scrollIntoView({block:"start"}); return; }
      const main = asArray(state.data.configFiles).find(file => file.role === "main");
      if (main) openConfigFileDraft(main.path).catch(err => { $("status").textContent = err.message; });
    });
    $("draftEditorInput").addEventListener("scroll", () => syncEditorScroll("draftEditor"));
    $("rawEditorHighlight").addEventListener("scroll", () => syncEditorScroll("rawEditor"));
    $("nodeEditorHighlight").addEventListener("scroll", () => syncEditorScroll("nodeEditor"));
    $("draftEditorInput").addEventListener("keydown", (event) => {
      if (event.key === "Tab") {
        event.preventDefault();
        const input = event.currentTarget;
        const start = input.selectionStart;
        const end = input.selectionEnd;
        input.value = input.value.slice(0, start) + "  " + input.value.slice(end);
        input.selectionStart = input.selectionEnd = start + 2;
        updateEditorHighlight("draftEditor", "toml");
        invalidateDraft();
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        runDraftAction(state.configDraft ? "validate" : "save");
      }
    });
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
    function openNodeFromEvent(event) {
      const target = event.target && event.target.closest ? event.target.closest("[data-node-ref]") : null;
      if (!target) return;
      showNodeDetails(target.getAttribute("data-node-ref"));
    }
    for (const id of ["overviewChains", "observabilityFlow", "graphNodes"]) {
      $(id).addEventListener("click", openNodeFromEvent);
      $(id).addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          openNodeFromEvent(event);
        }
      });
    }
    $("closeNodeModal").addEventListener("click", closeNodeDetails);
    $("nodeModal").addEventListener("click", (event) => {
      if (event.target && event.target.getAttribute && event.target.getAttribute("data-modal-close") === "node") {
        closeNodeDetails();
      }
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !$("nodeModal").classList.contains("hidden")) {
        closeNodeDetails();
      }
    });
    window.addEventListener("resize", () => {
      resizeEditor("sourceEditor");
      resizeEditor("draftEditor");
      resizeEditor("rawEditor");
      resizeEditor("nodeEditor");
      syncEditorScroll("sourceEditor");
      syncEditorScroll("draftEditor");
      syncEditorScroll("rawEditor");
      syncEditorScroll("nodeEditor");
    });
    $("sourceFiles").addEventListener("click", (event) => {
      const target = event.target && event.target.closest ? event.target.closest("[data-source-open]") : null;
      if (target) {
        openSourceFileDraft(target.getAttribute("data-source-open")).catch((err) => showSourceResult({ ok: false, error: err && err.message ? err.message : String(err) }));
      }
    });
    for (const id of ["newAppId", "newAppKind", "newAppPort", "newAppHost", "newAppEntry", "newAppModuleRoot", "newPipelineId", "newIngressRef", "newMatchMethods", "newMatchPaths", "newMatchHosts", "newPolicyRefs", "newTransformRefs", "newEgressRef"]) {
      $(id).addEventListener("input", generateAppToml);
      $(id).addEventListener("change", generateAppToml);
    }
    for (const button of document.querySelectorAll(".nav button")) {
      button.addEventListener("click", () => selectView(button.dataset.view));
    }
    $('trafficListener').addEventListener('change',()=>{state.trafficListener=$('trafficListener').value;state.trafficPipeline=null;loadTrafficWindow();});
    $('trafficPipeline').addEventListener('change',()=>{state.trafficPipeline=$('trafficPipeline').value?JSON.parse($('trafficPipeline').value):null;loadTrafficWindow();});
    $('trafficWindow').addEventListener('change',()=>{state.trafficWindow=Number($('trafficWindow').value);loadTrafficWindow();});
    $('trafficStatus').addEventListener('change',()=>{state.trafficStatus=$('trafficStatus').value;renderDashboard();});
    $('trafficSort').addEventListener('change',()=>{state.trafficSort=$('trafficSort').value;renderDashboard();});
    $('trafficSlowMs').addEventListener('change',()=>{state.trafficSlowMs=Math.min(3600000,Math.max(1,Number($('trafficSlowMs').value)||500));$('trafficSlowMs').value=state.trafficSlowMs;renderDashboard();});
    $('trafficSlowMs').addEventListener('input',()=>{const value=Number($('trafficSlowMs').value);if(value>0){state.trafficSlowMs=Math.min(3600000,value);renderDashboard();}});
    $('findSlowRoutes').addEventListener('click',()=>{state.trafficSlowMs=Math.min(3600000,Math.max(1,Number($('trafficSlowMs').value)||500));$('trafficSlowMs').value=state.trafficSlowMs;state.trafficStatus='slow';state.trafficSort='slow';$('trafficStatus').value='slow';$('trafficSort').value='slow';renderDashboard();});
    $('autoRefresh').addEventListener('change',()=>renderDashboard());
    $('trafficPanel').addEventListener('click', event=> {
      const target=event.target.closest('[data-traffic-listener],[data-traffic-route],[data-traffic-close],[data-traffic-source],[data-traffic-reload],[data-traffic-copy],[data-traffic-log],[data-traffic-locate]');
      if(!target)return;
      if(target.hasAttribute('data-traffic-locate')) {
        const focus=state.trafficFocus;if(!focus)return;
        apiRequest('/admin/workbench/log-focus',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({listener:focus[0],pipeline:focus[1],observation_id:target.dataset.trafficLocate})}).then(()=>{const status=$('trafficCopyStatus');if(status)status.textContent='已发送到工作台，将自动筛选此请求日志。';}).catch(()=>{const status=$('trafficCopyStatus');if(status)status.textContent='无法连接工作台或记录已过期，请从工作台重新打开此项目并刷新明细。';});return;
      }
      if(target.hasAttribute('data-traffic-log')) {state.trafficLogFocus=target.parentElement.open?null:target.dataset.trafficLog;return;}
      if(target.hasAttribute('data-traffic-reload')) { loadTrafficDetails();return; }
      if(target.hasAttribute('data-traffic-copy')) { navigator.clipboard.writeText(target.dataset.trafficCopy).then(()=>{$('trafficCopyStatus').textContent='定位编号已复制';}).catch(()=>{$('trafficCopyStatus').textContent='无法自动复制，请选中编号复制。';});return; }
      if(target.hasAttribute('data-traffic-source')) {
        selectView('apps');
        CommonConfigUI.openSource(target.dataset.trafficSource,target.dataset.trafficPipeline).then(opened=>{if(!opened)return openConfigFileDraft(target.dataset.trafficSource);}).catch(error=>{$('commonStage').textContent=error.message;});return;
      }
      if(target.hasAttribute('data-traffic-close')) {state.trafficFocus=null;++state.trafficSampleSequence;state.trafficSamples=null;}
      if(target.hasAttribute('data-traffic-listener')) { state.trafficListener=target.dataset.trafficListener;state.trafficPipeline=null;loadTrafficWindow();return; }
      if(target.hasAttribute('data-traffic-route')) {state.trafficFocus=JSON.parse(target.dataset.trafficRoute);loadTrafficDetails();}
      renderDashboard();
      if(state.trafficFocus)$('trafficDetails').scrollIntoView({block:'nearest'});
    });
    $('view-dashboard').addEventListener('click',event=>{
      const button=event.target.closest('[data-executor-source]');if(!button)return;
      selectView('apps');
      CommonConfigUI.openSource(button.dataset.executorSource,button.dataset.executorId,button.dataset.executorType).then(opened=>{if(!opened)return openConfigFileDraft(button.dataset.executorSource);}).catch(error=>{$('commonStage').textContent=error.message;});
    });
    $("view-dashboard").addEventListener("click", event => {
      const action = event.target.closest("[data-overview-view],[data-overview-source]");
      if (!action) return;
      if (action.dataset.overviewSource) {
        selectView("apps");
        CommonConfigUI.openSource(action.dataset.overviewSource).then(opened => { if (!opened) return openConfigFileDraft(action.dataset.overviewSource); }).catch(error => { $("commonStage").textContent = error.message; });
      } else if (action.dataset.overviewView === "traffic") {
        state.trafficStatus="recent"; $("trafficStatus").value="recent"; renderDashboard(); $("trafficPanel").scrollIntoView({block:"start"});
      } else if (action.dataset.overviewView === "apps") {
        $("configureProject").click();
      } else { selectView(action.dataset.overviewView); }
    });
    setInterval(() => {
      if ($("autoRefresh").checked && !state.authRequired && !document.hidden) refresh(true);
    }, 5000);
    selectView("dashboard");
    refresh();
  
