module main

import json
import os
import sync
import hash.fnv1a
import vjsx
import vjsx.runtimejs

pub struct VjsxRuntimeFacadeConfig {
pub:
	app_entry       string
	module_root     string
	runtime_profile string
	thread_count    int
	max_requests    int
	enable_fs       bool
	enable_process  bool
	enable_network  bool
}

pub struct VjsxRuntimeFacade {
pub mut:
	config       VjsxRuntimeFacadeConfig
	bootstrapped bool
	last_error   string
}

pub struct VjsxExecutionLane {
pub:
	id string
mut:
	served_requests i64
	healthy         bool = true
	inflight        int
	last_error      string
}

pub struct VjsxExecutorState {
mut:
	mu       sync.Mutex
	facade   VjsxRuntimeFacade
	lanes    []VjsxExecutionLane
	hosts    []VjsxLaneHost
	rr_index int
}

struct VjsxLaneHost {
mut:
	initialized bool
	rt          &vjsx.Runtime = unsafe { nil }
	ctx         &vjsx.Context = unsafe { nil }
	request_ctx InProcVjsxRequestContext
}

pub struct InProcVjsxExecutor {
pub:
	provider_name string = 'vjsx'
	kind_name     string = 'vjsx'
pub mut:
	state &VjsxExecutorState = unsafe { nil }
}

struct InProcVjsxRuntimeMeta {
	provider        string
	executor        string
	lane_id         string @[json: 'laneId']
	request_id      string @[json: 'requestId']
	trace_id        string @[json: 'traceId']
	app_entry       string @[json: 'appEntry']
	module_root     string @[json: 'moduleRoot']
	runtime_profile string @[json: 'runtimeProfile']
	thread_count    int    @[json: 'threadCount']
	enable_fs       bool   @[json: 'enableFs']
	enable_process  bool   @[json: 'enableProcess']
	enable_network  bool   @[json: 'enableNetwork']
	request_scheme  string @[json: 'requestScheme']
	request_host    string @[json: 'requestHost']
	request_port    string @[json: 'requestPort']
	request_target  string @[json: 'requestTarget']
	request_protocol_version string @[json: 'requestProtocolVersion']
	request_remote_addr string @[json: 'requestRemoteAddr']
	request_server  map[string]string @[json: 'requestServer']
	method          string
	path            string
}

struct InProcVjsxRequestContext {
mut:
	active     bool
	app        &App = unsafe { nil }
	lane_id    string
	request_id string
	trace_id   string
	method     string
	path       string
}

pub fn new_inproc_vjsx_executor(config VjsxRuntimeFacadeConfig) InProcVjsxExecutor {
	mut lanes := []VjsxExecutionLane{}
	if config.thread_count > 0 {
		for i in 0 .. config.thread_count {
			lanes << VjsxExecutionLane{
				id: 'lane_${i}'
			}
		}
	}
	return InProcVjsxExecutor{
		state: &VjsxExecutorState{
			facade: VjsxRuntimeFacade{
				config: config
			}
			lanes:  lanes
			hosts:  []VjsxLaneHost{len: lanes.len}
		}
	}
}

pub fn (e InProcVjsxExecutor) kind() string {
	return e.kind_name
}

pub fn (e InProcVjsxExecutor) provider() string {
	return e.provider_name
}

pub fn (e InProcVjsxExecutor) lane_count() int {
	if isnil(e.state) {
		return 0
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	return state.lanes.len
}

pub fn (e InProcVjsxExecutor) facade_snapshot() VjsxRuntimeFacade {
	if isnil(e.state) {
		return VjsxRuntimeFacade{}
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	return state.facade
}

pub fn (e InProcVjsxExecutor) lane_snapshot() []VjsxExecutionLane {
	if isnil(e.state) {
		return []VjsxExecutionLane{}
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	return state.lanes.clone()
}

pub fn (e InProcVjsxExecutor) bootstrap_placeholder() ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if state.facade.bootstrapped {
		return
	}
	if state.lanes.len == 0 {
		state.facade.last_error = 'inproc_vjsx_executor_no_lanes'
		return error(state.facade.last_error)
	}
	if state.facade.config.app_entry.trim_space() == '' {
		state.facade.last_error = 'inproc_vjsx_executor_missing_app_entry'
		return error(state.facade.last_error)
	}
	state.facade.bootstrapped = true
	state.facade.last_error = ''
}

pub fn (e InProcVjsxExecutor) select_next_lane() !VjsxExecutionLane {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if state.lanes.len == 0 {
		return error('inproc_vjsx_executor_no_lanes')
	}
	for offset in 0 .. state.lanes.len {
		idx := (state.rr_index + offset) % state.lanes.len
		if !state.lanes[idx].healthy || state.lanes[idx].inflight > 0 {
			continue
		}
		state.lanes[idx].inflight++
		state.rr_index = (idx + 1) % state.lanes.len
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_no_available_lane')
}

pub fn (e InProcVjsxExecutor) release_lane(lane_id string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		if state.lanes[i].inflight > 0 {
			state.lanes[i].inflight--
		}
		break
	}
}

pub fn (e InProcVjsxExecutor) record_lane_success(lane_id string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[i].served_requests++
		state.lanes[i].healthy = true
		state.lanes[i].last_error = ''
		break
	}
}

pub fn (e InProcVjsxExecutor) record_lane_error(lane_id string, err_msg string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[i].healthy = false
		state.lanes[i].last_error = err_msg
		break
	}
}

fn (e InProcVjsxExecutor) lane_index_by_id(lane_id string) int {
	if isnil(e.state) || lane_id == '' {
		return -1
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id == lane_id {
			return i
		}
	}
	return -1
}

fn vjsx_entry_runs_as_module(app_entry string) !bool {
	if vjsx.is_typescript_file(app_entry) {
		return true
	}
	if app_entry.ends_with('.mjs') || app_entry.ends_with('.cjs') || app_entry.ends_with('.mts')
		|| app_entry.ends_with('.cts') {
		return true
	}
	if app_entry.ends_with('.js') {
		return false
	}
	return error('inproc_vjsx_executor_unsupported_entry:${app_entry}')
}

fn vjsx_fs_roots(config VjsxRuntimeFacadeConfig) []string {
	mut roots := []string{}
	if config.module_root.trim_space() != '' {
		roots << config.module_root
	}
	if config.app_entry.trim_space() != '' {
		roots << os.dir(config.app_entry)
	}
	roots << os.getwd()
	return roots.filter(it.trim_space() != '')
}

fn runtime_relative_path(from string, to string) string {
	from_abs := os.abs_path(from)
	to_abs := os.abs_path(to)
	sep := os.path_separator.str()
	from_parts := from_abs.split(sep).filter(it.len > 0)
	to_parts := to_abs.split(sep).filter(it.len > 0)
	mut common := 0
	for common < from_parts.len && common < to_parts.len && from_parts[common] == to_parts[common] {
		common++
	}
	mut parts := []string{}
	for _ in common .. from_parts.len {
		parts << '..'
	}
	for part in to_parts[common..] {
		parts << part
	}
	if parts.len == 0 {
		return '.'
	}
	return parts.join(sep)
}

fn runtime_import_specifier(from_path string, to_path string) string {
	mut rel := runtime_relative_path(os.dir(from_path), to_path)
	if !rel.starts_with('.') {
		rel = './' + rel
	}
	return rel.replace('\\', '/')
}

fn vjsx_lane_temp_root(app_entry string, idx int) string {
	entry_abs := os.abs_path(app_entry)
	entry_name := os.base(entry_abs).trim_space().replace(' ', '_')
	entry_hash := fnv1a.sum64_string(entry_abs).hex()
	cache_root := os.join_path(os.temp_dir(), 'vhttpd_vjsx')
	return os.join_path(cache_root, '${entry_name}.${entry_hash}.lane_${idx}.vjsbuild')
}

fn normalize_vjsx_runtime_event_kind(raw string) string {
	mut kind := raw.trim_space().replace(' ', '_')
	if kind == '' {
		return ''
	}
	if !kind.starts_with('vjsx.') {
		kind = 'vjsx.' + kind
	}
	return kind
}

fn runtime_event_fields_from_js_value(val vjsx.Value) map[string]string {
	if val.is_undefined() || val.is_null() {
		return map[string]string{}
	}
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return map[string]string{}
	}
	return json.decode(map[string]string, raw) or {
		map[string]string{}
	}
}

fn install_inproc_http_facade(mut ctx vjsx.Context) ! {
	ctx.eval('
globalThis.__vhttpd_create_runtime = function(meta) {
  const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "http";
  const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
  const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
  const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : meta.path;
  const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
  const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
  const capabilities = Object.freeze({
    http: true,
    stream: false,
    websocket: false,
    fs: !!meta.enableFs,
    process: !!meta.enableProcess,
    network: !!meta.enableNetwork
  });
  const request = Object.freeze({
    id: meta.requestId,
    traceId: meta.traceId,
    method: meta.method,
    path: meta.path,
    url: meta.path,
    target: requestTarget,
    href: requestHref,
    origin: requestOrigin,
    scheme: requestScheme,
    host: requestHost,
    port: requestPort,
    protocolVersion: meta.requestProtocolVersion,
    remoteAddr: meta.requestRemoteAddr,
    ip: meta.requestRemoteAddr,
    server: Object.freeze(meta.requestServer || {})
  });
  const runtime = {
    provider: meta.provider,
    executor: meta.executor,
    laneId: meta.laneId,
    requestId: meta.requestId,
    traceId: meta.traceId,
    appEntry: meta.appEntry,
    moduleRoot: meta.moduleRoot,
    runtimeProfile: meta.runtimeProfile,
    threadCount: meta.threadCount,
    capabilities,
    request,
    method: meta.method,
    path: meta.path,
    now() {
      return Date.now();
    },
    log(...args) {
      if (typeof console !== "undefined" && console && typeof console.log === "function") {
        console.log("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
      }
    },
    warn(...args) {
      if (typeof console !== "undefined" && console && typeof console.warn === "function") {
        console.warn("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
      } else {
        this.log(...args);
      }
    },
    error(...args) {
      if (typeof console !== "undefined" && console && typeof console.error === "function") {
        console.error("[vhttpd]", this.laneId, this.requestId || "", this.traceId || "", ...args);
      } else {
        this.log(...args);
      }
    },
    emit(kind, fields) {
      if (typeof globalThis.__vhttpd_host_emit !== "function") {
        return false;
      }
      const normalizedFields = {};
      if (fields && typeof fields === "object") {
        for (const [key, value] of Object.entries(fields)) {
          normalizedFields[String(key)] = value == null ? "" : String(value);
        }
      }
      return !!globalThis.__vhttpd_host_emit(String(kind), normalizedFields);
    },
    snapshot() {
      if (typeof globalThis.__vhttpd_host_snapshot !== "function") {
        return undefined;
      }
      const raw = globalThis.__vhttpd_host_snapshot();
      if (raw === undefined || raw === null || raw === "") {
        return undefined;
      }
      try {
        const snapshot = JSON.parse(String(raw));
        if (snapshot && typeof snapshot === "object") {
          return Object.freeze(snapshot);
        }
        return snapshot;
      } catch (_) {
        return undefined;
      }
    },
    toJSON() {
      return {
        provider: this.provider,
        executor: this.executor,
        laneId: this.laneId,
        requestId: this.requestId,
        traceId: this.traceId,
        appEntry: this.appEntry,
        moduleRoot: this.moduleRoot,
        runtimeProfile: this.runtimeProfile,
        threadCount: this.threadCount,
        method: this.method,
        path: this.path
      };
    }
  };
  return Object.freeze(runtime);
};
globalThis.__vhttpd_create_ctx = function(req, runtime) {
  const response = { status: 200, headers: {}, body: "" };
  const target = typeof req.server?.url === "string" && req.server.url ? req.server.url : req.path;
  const scheme = typeof req.scheme === "string" && req.scheme ? req.scheme : "http";
  const host = typeof req.host === "string" ? req.host : "";
  const port = typeof req.port === "string" ? req.port : "";
  const origin = host ? scheme + "://" + host + (port ? ":" + port : "") : "";
  const href = origin ? origin + target : target;
  const normalizeMime = (raw) => {
    if (raw === undefined || raw === null) {
      return "";
    }
    return String(raw).split(";")[0].trim().toLowerCase();
  };
  const mimeMatches = (accepted, candidate) => {
    if (!accepted || !candidate) {
      return false;
    }
    if (accepted === "*/*" || candidate === "*/*") {
      return true;
    }
    if (accepted === candidate) {
      return true;
    }
    if (accepted.endsWith("/*")) {
      return candidate.startsWith(accepted.slice(0, accepted.length - 1));
    }
    if (candidate.endsWith("/*")) {
      return accepted.startsWith(candidate.slice(0, candidate.length - 1));
    }
    return false;
  };
  const parseAccepts = (raw) => {
    if (raw === undefined || raw === null || String(raw).trim() === "") {
      return [];
    }
    return String(raw)
      .split(",")
      .map((part) => normalizeMime(part))
      .filter(Boolean);
  };
  return {
    req: req,
    res: response,
    request: req,
    response,
    runtime,
    requestId: runtime.requestId,
    traceId: runtime.traceId,
    method: req.method,
    path: req.path,
    url: req.path,
    target,
    href,
    origin,
    scheme,
    host,
    port,
    protocolVersion: req.protocol_version,
    remoteAddr: req.remote_addr,
    ip: req.remote_addr,
    server: req.server,
    body: req.body,
    headers: req.headers,
    query: req.query,
    cookies: req.cookies,
    status(code) {
      if (typeof code === "number") response.status = code;
      return this;
    },
    code(code) {
      return this.status(code);
    },
    setHeader(name, value) {
      response.headers[String(name).toLowerCase()] = String(value);
      return this;
    },
    getHeader(name) {
      const key = String(name).toLowerCase();
      return response.headers[key] ?? req.headers[key];
    },
    hasHeader(name) {
      const key = String(name).toLowerCase();
      return Object.prototype.hasOwnProperty.call(response.headers, key) || Object.prototype.hasOwnProperty.call(req.headers, key);
    },
    removeHeader(name) {
      const key = String(name).toLowerCase();
      delete response.headers[key];
      return this;
    },
    header(name, value) {
      if (arguments.length >= 2) {
        return this.setHeader(name, value);
      }
      return this.getHeader(name);
    },
    type(contentType) {
      return this.setHeader("content-type", contentType);
    },
    queryParam(name, fallbackValue) {
      const key = String(name);
      return this.query[key] ?? fallbackValue;
    },
    queryInt(name, fallbackValue) {
      const raw = this.queryParam(name, undefined);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const parsed = Number.parseInt(String(raw), 10);
      return Number.isNaN(parsed) ? fallbackValue : parsed;
    },
    queryBool(name, fallbackValue) {
      const raw = this.queryParam(name, undefined);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const normalized = String(raw).trim().toLowerCase();
      if (["1", "true", "yes", "on"].includes(normalized)) {
        return true;
      }
      if (["0", "false", "no", "off"].includes(normalized)) {
        return false;
      }
      return fallbackValue;
    },
    cookie(name, fallbackValue) {
      const key = String(name);
      return this.cookies[key] ?? fallbackValue;
    },
    is(method) {
      return String(this.method).toUpperCase() === String(method).toUpperCase();
    },
    headerInt(name, fallbackValue) {
      const raw = this.getHeader(name);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const parsed = Number.parseInt(String(raw), 10);
      return Number.isNaN(parsed) ? fallbackValue : parsed;
    },
    headerBool(name, fallbackValue) {
      const raw = this.getHeader(name);
      if (raw === undefined || raw === null || raw === "") {
        return fallbackValue;
      }
      const normalized = String(raw).trim().toLowerCase();
      if (["1", "true", "yes", "on"].includes(normalized)) {
        return true;
      }
      if (["0", "false", "no", "off"].includes(normalized)) {
        return false;
      }
      return fallbackValue;
    },
    contentType() {
      return normalizeMime(req.headers["content-type"]);
    },
    accepts(...types) {
      const requestedTypes = types.length === 1 && Array.isArray(types[0]) ? types[0] : types;
      if (requestedTypes.length === 0) {
        return parseAccepts(this.getHeader("accept"));
      }
      const accepted = parseAccepts(this.getHeader("accept"));
      if (accepted.length === 0 || accepted.includes("*/*")) {
        return requestedTypes[0] ?? false;
      }
      for (const candidate of requestedTypes.map((value) => normalizeMime(value)).filter(Boolean)) {
        if (accepted.some((value) => mimeMatches(value, candidate))) {
          return candidate;
        }
      }
      return false;
    },
    isJson() {
      const mime = this.contentType();
      return mime === "application/json" || mime.endsWith("+json");
    },
    isHtml() {
      return this.contentType() === "text/html";
    },
    wantsJson() {
      return !!this.accepts("application/json", "application/*", "*/*");
    },
    wantsHtml() {
      return !!this.accepts("text/html", "application/xhtml+xml", "*/*");
    },
    bodyText(fallbackValue) {
      if (req.body == null) {
        return fallbackValue;
      }
      const text = String(req.body);
      return text === "" ? fallbackValue : text;
    },
    jsonBody(fallbackValue) {
      if (req.body == null || String(req.body).trim() === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(req.body));
      } catch (_) {
        return fallbackValue;
      }
    },
    text(body, status) {
      if (typeof status === "number") response.status = status;
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "text/plain; charset=utf-8";
      }
      response.body = body == null ? "" : String(body);
      return response;
    },
    json(value, status) {
      if (typeof status === "number") response.status = status;
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "application/json; charset=utf-8";
      }
      response.body = JSON.stringify(value);
      return response;
    },
    html(body, status) {
      if (typeof status === "number") response.status = status;
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "text/html; charset=utf-8";
      }
      response.body = body == null ? "" : String(body);
      return response;
    },
    send(body, status) {
      return this.text(body, status);
    },
    ok(value) {
      if (typeof value === "string") {
        return this.text(value, 200);
      }
      return this.json(value, 200);
    },
    created(value) {
      if (value === undefined) {
        response.status = 201;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 201);
      }
      return this.json(value, 201);
    },
    accepted(value) {
      if (value === undefined) {
        response.status = 202;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 202);
      }
      return this.json(value, 202);
    },
    noContent() {
      response.status = 204;
      delete response.headers["content-type"];
      response.body = "";
      return response;
    },
    badRequest(value) {
      if (value === undefined) {
        response.status = 400;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 400);
      }
      return this.json(value, 400);
    },
    unprocessableEntity(value) {
      if (value === undefined) {
        response.status = 422;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 422);
      }
      return this.json(value, 422);
    },
    notFound(value) {
      if (value === undefined) {
        response.status = 404;
        return response;
      }
      if (typeof value === "string") {
        return this.text(value, 404);
      }
      return this.json(value, 404);
    },
    problem(status, title, detail, extra) {
      const problemStatus = typeof status === "number" ? status : 500;
      const problemTitle = title == null || String(title).trim() === "" ? "Error" : String(title);
      const payload = {
        status: problemStatus,
        title: problemTitle
      };
      if (detail !== undefined && detail !== null && String(detail) !== "") {
        payload.detail = String(detail);
      }
      if (extra && typeof extra === "object" && !Array.isArray(extra)) {
        for (const [key, value] of Object.entries(extra)) {
          if (key === "status" || key === "title" || key === "detail") {
            continue;
          }
          payload[String(key)] = value;
        }
      }
      response.status = problemStatus;
      response.headers["content-type"] = "application/problem+json; charset=utf-8";
      response.body = JSON.stringify(payload);
      return response;
    },
    redirect(location, status) {
      response.status = typeof status === "number" ? status : 302;
      response.headers["location"] = String(location);
      if (!response.headers["content-type"]) {
        response.headers["content-type"] = "text/plain; charset=utf-8";
      }
      response.body = "";
      return response;
    },
    reply(body, status) {
      return this.text(body, status);
    }
  };
};
globalThis.__vhttpd_normalize_result = function(ctx, result) {
  if (result === undefined || result === null) {
    return ctx.response;
  }
  return result;
};
globalThis.__vhttpd_resolve_handler = function(exportsValue) {
  if (exportsValue && typeof exportsValue === "object") {
    if (typeof exportsValue.default === "function") {
      return exportsValue.default;
    }
    if (typeof exportsValue.handle === "function") {
      return exportsValue.handle;
    }
  }
  if (typeof globalThis.__vhttpd_handle === "function") {
    return globalThis.__vhttpd_handle;
  }
  return undefined;
};
globalThis.__vhttpd_bind_handler = function(exportsValue) {
  const handler = globalThis.__vhttpd_resolve_handler(exportsValue);
  if (typeof handler === "function") {
    globalThis.__vhttpd_handle = handler;
  }
  return handler;
};
globalThis.__vhttpd_register_exports = function(exportsValue) {
  if (!exportsValue || typeof exportsValue !== "object") {
    return globalThis.__vhttpd_bind_handler(undefined);
  }
  return globalThis.__vhttpd_bind_handler(exportsValue);
};
')!
	ctx.end()
}

fn load_inproc_vjsx_entry(mut ctx vjsx.Context, config VjsxRuntimeFacadeConfig, idx int, as_module bool) !vjsx.Value {
	temp_root := vjsx_lane_temp_root(config.app_entry, idx)
	if !as_module {
		return runtimejs.run_runtime_entry(ctx, config.app_entry, false, temp_root)
	}
	if vjsx.is_typescript_file(config.app_entry) || vjsx.is_runtime_module_file(config.app_entry) {
		runtimejs.install_typescript_runtime(ctx)!
	}
	entry_path := runtimejs.build_runtime_module_entry(ctx, config.app_entry, true, temp_root)!
	loader_path := os.join_path(temp_root, '__vhttpd_loader__.mjs')
	loader_source :=
		'import * as __vhttpd_exports from "${runtime_import_specifier(loader_path, entry_path)}";\n' +
		'globalThis.__vhttpd_module_exports = __vhttpd_exports;\n' +
		'export default __vhttpd_exports.default;\n'
	os.write_file(loader_path, loader_source)!
	mut entry_result := ctx.run_file(loader_path, vjsx.type_module)!
	entry_result.free()
	return ctx.js_global('__vhttpd_module_exports')
}

fn install_inproc_runtime_host_bridge(mut ctx vjsx.Context, mut state VjsxExecutorState, idx int) {
	global := ctx.js_global()
	mut host_emit := ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
		if args.len == 0 {
			return ctx.js_bool(false)
		}
		kind := normalize_vjsx_runtime_event_kind(args[0].to_string())
		if kind == '' {
			return ctx.js_bool(false)
		}
		fields := if args.len > 1 {
			runtime_event_fields_from_js_value(args[1])
		} else {
			map[string]string{}
		}
		mut app_ref := &App(unsafe { nil })
		mut lane_id := ''
		mut request_id := ''
		mut trace_id := ''
		mut method := ''
		mut path := ''
		state.mu.@lock()
		if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
			request_ctx := state.hosts[idx].request_ctx
			app_ref = request_ctx.app
			lane_id = request_ctx.lane_id
			request_id = request_ctx.request_id
			trace_id = request_ctx.trace_id
			method = request_ctx.method
			path = request_ctx.path
		}
		state.mu.unlock()
		if isnil(app_ref) {
			return ctx.js_bool(false)
		}
		mut row := map[string]string{}
		row['lane_id'] = lane_id
		row['request_id'] = request_id
		row['trace_id'] = trace_id
		row['method'] = method
		row['path'] = path
		row['executor'] = 'vjsx'
		row['provider'] = 'vjsx'
		for key, value in fields {
			row[key] = value
		}
		mut app := app_ref
		app.emit(kind, row)
		return ctx.js_bool(true)
	})
	mut host_snapshot := ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
		_ = args
		mut app_ref := &App(unsafe { nil })
		state.mu.@lock()
		if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
			app_ref = state.hosts[idx].request_ctx.app
		}
		state.mu.unlock()
		if isnil(app_ref) {
			return ctx.js_undefined()
		}
		mut app := app_ref
		return ctx.js_string(json.encode(app.admin_runtime_snapshot()))
	})
	global.set('__vhttpd_host_emit', host_emit)
	global.set('__vhttpd_host_snapshot', host_snapshot)
	host_emit.free()
	host_snapshot.free()
	global.free()
}

fn (e InProcVjsxExecutor) ensure_lane_host(idx int) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len || idx >= state.lanes.len {
		state.mu.unlock()
		return error('inproc_vjsx_executor_invalid_lane')
	}
	if state.hosts[idx].initialized {
		state.mu.unlock()
		return
	}
	config := state.facade.config
	state.mu.unlock()

	as_module := vjsx_entry_runs_as_module(config.app_entry)!
	mut rt_value := vjsx.new_runtime()
	rt := &rt_value
	mut ctx := rt.new_context()
	match config.runtime_profile {
		'', 'script' {
			ctx.install_script_runtime(
				fs_roots:     vjsx_fs_roots(config)
				process_args: [config.app_entry]
			)
		}
		'node' {
			ctx.install_node_runtime(
				fs_roots:     vjsx_fs_roots(config)
				process_args: [config.app_entry]
			)
		}
		else {
			ctx.free()
			rt.free()
			return error('inproc_vjsx_executor_unsupported_runtime_profile:${config.runtime_profile}')
		}
	}
	install_inproc_http_facade(mut ctx)!
	install_inproc_runtime_host_bridge(mut ctx, mut state, idx)
	mut entry_exports := load_inproc_vjsx_entry(mut ctx, config, idx, as_module) or {
		ctx.free()
		rt.free()
		return error('inproc_vjsx_executor_bootstrap_failed:${err.msg()}')
	}
	defer {
		entry_exports.free()
	}
	bind_handler := ctx.js_global('__vhttpd_bind_handler')
	defer {
		bind_handler.free()
	}
	if !bind_handler.is_undefined() && bind_handler.is_function() {
		mut bound := ctx.call(bind_handler, entry_exports) or {
			ctx.free()
			rt.free()
			return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
		}
		defer {
			bound.free()
		}
	}
	handler := ctx.js_global('__vhttpd_handle')
	if handler.is_undefined() || !handler.is_function() {
		handler.free()
		ctx.free()
		rt.free()
		return error('inproc_vjsx_executor_missing_handler')
	}
	handler.free()

	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	state.hosts[idx] = VjsxLaneHost{
		initialized: true
		rt:          rt
		ctx:         ctx
	}
}

fn (e InProcVjsxExecutor) activate_lane_request_context(idx int, mut app App, lane_id string, req HttpLogicDispatchRequest) {
	if isnil(e.state) || idx < 0 {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if idx >= state.hosts.len {
		return
	}
	normalized_path, _ := normalize_request_target(req.path)
	state.hosts[idx].request_ctx = InProcVjsxRequestContext{
		active:     true
		app:        app
		lane_id:    lane_id
		request_id: req.request_id
		trace_id:   req.trace_id
		method:     req.method.to_upper()
		path:       normalized_path
	}
}

fn (e InProcVjsxExecutor) clear_lane_request_context(idx int) {
	if isnil(e.state) || idx < 0 {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if idx >= state.hosts.len {
		return
	}
	state.hosts[idx].request_ctx = InProcVjsxRequestContext{}
}

fn build_inproc_request_payload(req HttpLogicDispatchRequest) string {
	return encode_worker_request(req.method, req.path, req.req, req.remote_addr, req.trace_id,
		req.request_id)
}

fn (e InProcVjsxExecutor) build_runtime_payload(lane VjsxExecutionLane, req HttpLogicDispatchRequest) string {
	normalized_path, _ := normalize_request_target(req.path)
	config := e.facade_snapshot().config
	server := server_map_from_request(req.req, req.remote_addr)
	host := server['host'] or { req.req.host }
	port := server['port'] or { '' }
	scheme := req.req.header.get(.x_forwarded_proto) or { 'http' }
	target := server['url'] or { req.path }
	return json.encode(InProcVjsxRuntimeMeta{
		provider:        e.provider()
		executor:        e.kind()
		lane_id:         lane.id
		request_id:      req.request_id
		trace_id:        req.trace_id
		app_entry:       config.app_entry
		module_root:     config.module_root
		runtime_profile: config.runtime_profile
		thread_count:    config.thread_count
		enable_fs:       config.enable_fs
		enable_process:  config.enable_process
		enable_network:  config.enable_network
		request_scheme:  scheme
		request_host:    host
		request_port:    port
		request_target:  target
		request_protocol_version: req.req.version.str().trim_left('HTTP/')
		request_remote_addr: req.remote_addr
		request_server:  server
		method:          req.method.to_upper()
		path:            normalized_path
	})
}

fn response_headers_from_js_value(val vjsx.Value) map[string]string {
	mut out := map[string]string{}
	if val.is_undefined() || val.is_null() {
		return out
	}
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return out
	}
	return json.decode(map[string]string, raw) or {
		map[string]string{}
	}
}

fn response_from_js_value(val vjsx.Value, req_id string) WorkerResponse {
	if val.is_string() {
		return WorkerResponse{
			id:      req_id
			status:  200
			body:    val.to_string()
			headers: {
				'content-type': 'text/plain; charset=utf-8'
			}
		}
	}
	mut status := 200
	mut body := ''
	mut headers := map[string]string{}
	status_val := val.get('status')
	defer {
		status_val.free()
	}
	if !status_val.is_undefined() {
		status = status_val.to_int()
	}
	body_val := val.get('body')
	defer {
		body_val.free()
	}
	if !body_val.is_undefined() && !body_val.is_null() {
		body = body_val.to_string()
	}
	headers_val := val.get('headers')
	defer {
		headers_val.free()
	}
	headers = response_headers_from_js_value(headers_val)
	if headers['content-type'] == '' && status !in [204, 304] {
		headers['content-type'] = 'text/plain; charset=utf-8'
	}
	return WorkerResponse{
		id:      req_id
		status:  status
		body:    body
		headers: headers
	}
}

fn inproc_vjsx_not_ready_error(op string) IError {
	return error('inproc_vjsx_executor_not_ready:${op}')
}

pub fn (e InProcVjsxExecutor) dispatch_http(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	e.bootstrap_placeholder()!
	lane := e.select_next_lane()!
	defer {
		e.release_lane(lane.id)
	}
	idx := e.lane_index_by_id(lane.id)
	if idx < 0 {
		e.record_lane_error(lane.id, 'inproc_vjsx_executor_lane_not_found')
		return error('inproc_vjsx_executor_lane_not_found')
	}
	e.ensure_lane_host(idx) or {
		e.record_lane_error(lane.id, err.msg())
		return error(err.msg())
	}
	e.activate_lane_request_context(idx, mut app, lane.id, req)
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	request_obj := host.ctx.json_parse(build_inproc_request_payload(req))
	defer {
		request_obj.free()
	}
	runtime_obj := host.ctx.json_parse(e.build_runtime_payload(lane, req))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := host.ctx.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	mut js_runtime := host.ctx.call(create_runtime_fn, runtime_obj) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	create_ctx_fn := host.ctx.js_global('__vhttpd_create_ctx')
	defer {
		create_ctx_fn.free()
	}
	mut js_ctx := host.ctx.call(create_ctx_fn, request_obj, js_runtime) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_ctx_create_failed:${err.msg()}')
	}
	defer {
		js_ctx.free()
	}
	handler := host.ctx.js_global('__vhttpd_handle')
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		e.record_lane_error(lane.id, 'inproc_vjsx_executor_missing_handler')
		return error('inproc_vjsx_executor_missing_handler')
	}
	mut result := host.ctx.call(handler, js_ctx) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_handler_failed:${err.msg()}')
	}
	defer {
		result.free()
	}
	normalize_fn := host.ctx.js_global('__vhttpd_normalize_result')
	defer {
		normalize_fn.free()
	}
	if result.instanceof('Promise') {
		mut awaited := result.await()
		defer {
			awaited.free()
		}
		mut normalized := host.ctx.call(normalize_fn, js_ctx, awaited) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_normalize_failed:${err.msg()}')
		}
		defer {
			normalized.free()
		}
		e.record_lane_success(lane.id)
		return HttpLogicDispatchOutcome{
			kind:     .response
			response: response_from_js_value(normalized, req.request_id)
		}
	}
	mut normalized := host.ctx.call(normalize_fn, js_ctx, result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_normalize_failed:${err.msg()}')
	}
	defer {
		normalized.free()
	}
	e.record_lane_success(lane.id)
	return HttpLogicDispatchOutcome{
		kind:     .response
		response: response_from_js_value(normalized, req.request_id)
	}
}

pub fn (e InProcVjsxExecutor) open_websocket_session(mut app App, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = app
	_ = req
	return inproc_vjsx_not_ready_error('open_websocket_session')
}

pub fn (e InProcVjsxExecutor) dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse {
	_ = app
	_ = req
	return inproc_vjsx_not_ready_error('dispatch_stream')
}

pub fn (e InProcVjsxExecutor) dispatch_mcp(mut app App, req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	_ = app
	_ = req
	return inproc_vjsx_not_ready_error('dispatch_mcp')
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_upstream(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	_ = app
	_ = req
	return inproc_vjsx_not_ready_error('dispatch_websocket_upstream')
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return inproc_vjsx_not_ready_error('dispatch_websocket_event')
}
