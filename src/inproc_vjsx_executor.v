module main

import json
import os
import sync
import time
import hash.fnv1a
import vjsx
import vjsx.runtimejs

const inproc_vjsx_lane_wait_timeout_ms = 1000
const inproc_vjsx_lane_wait_poll_ms = 5
const inproc_vjsx_dispatch_retry_attempts = 2
const vjsx_default_signature_excludes = [
	'.git/**',
	'.hg/**',
	'.svn/**',
	'node_modules/**',
	'dist/**',
	'build/**',
	'coverage/**',
	'.next/**',
	'.nuxt/**',
	'.turbo/**',
	'tmp/**',
	'temp/**',
	'vendor/**',
]
const vjsx_signature_source_exts = ['.js', '.mjs', '.cjs', '.ts', '.mts', '.cts', '.json']

fn inproc_vjsx_codex_sessions_root() string {
	override_root := os.getenv('VHTTPD_CODEX_SESSIONS_ROOT').trim_space()
	if override_root != '' {
		return override_root
	}
	codex_home := os.getenv('CODEX_HOME').trim_space()
	if codex_home != '' {
		return os.join_path(codex_home, 'sessions')
	}
	home := os.home_dir()
	if home.trim_space() == '' {
		return ''
	}
	return os.join_path(home, '.codex', 'sessions')
}

fn inproc_vjsx_find_codex_session_file_in_dir(dir string, thread_id string) string {
	if dir.trim_space() == '' || thread_id.trim_space() == '' || !os.exists(dir) {
		return ''
	}
	items := os.ls(dir) or { return '' }
	mut names := items.clone()
	names.sort(a > b)
	for name in names {
		path := os.join_path(dir, name)
		if os.is_dir(path) {
			found := inproc_vjsx_find_codex_session_file_in_dir(path, thread_id)
			if found != '' {
				return found
			}
			continue
		}
		if !name.ends_with('.jsonl') {
			continue
		}
		if name.contains(thread_id) {
			return path
		}
	}
	return ''
}

fn inproc_vjsx_find_codex_session_file(thread_id string) string {
	root := inproc_vjsx_codex_sessions_root()
	if root == '' {
		return ''
	}
	return inproc_vjsx_find_codex_session_file_in_dir(root, thread_id)
}

pub struct VjsxRuntimeFacadeConfig {
pub:
	app_entry         string
	module_root       string
	signature_root    string
	signature_include []string
	signature_exclude []string
	runtime_profile   string
	thread_count      int
	max_requests      int
	enable_fs         bool
	enable_process    bool
	enable_network    bool
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
	dirty           bool
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
	initialized      bool
	dirty            bool
	source_signature string
	rt               &vjsx.Runtime = unsafe { nil }
	ctx              &vjsx.Context = unsafe { nil }
	request_ctx      InProcVjsxRequestContext
}

pub struct InProcVjsxExecutor {
pub:
	provider_name string = 'vjsx'
	kind_name     string = 'vjsx'
pub mut:
	state &VjsxExecutorState = unsafe { nil }
}

struct InProcVjsxRuntimeMeta {
	provider                 string
	executor                 string
	dispatch_kind            string            @[json: 'dispatchKind']
	lane_id                  string            @[json: 'laneId']
	request_id               string            @[json: 'requestId']
	trace_id                 string            @[json: 'traceId']
	app_entry                string            @[json: 'appEntry']
	module_root              string            @[json: 'moduleRoot']
	runtime_profile          string            @[json: 'runtimeProfile']
	thread_count             int               @[json: 'threadCount']
	enable_fs                bool              @[json: 'enableFs']
	enable_process           bool              @[json: 'enableProcess']
	enable_network           bool              @[json: 'enableNetwork']
	request_scheme           string            @[json: 'requestScheme']
	request_host             string            @[json: 'requestHost']
	request_port             string            @[json: 'requestPort']
	request_target           string            @[json: 'requestTarget']
	request_protocol_version string            @[json: 'requestProtocolVersion']
	request_remote_addr      string            @[json: 'requestRemoteAddr']
	request_server           map[string]string @[json: 'requestServer']
	upstream_provider        string            @[json: 'upstreamProvider']
	upstream_instance        string            @[json: 'upstreamInstance']
	upstream_event           string            @[json: 'upstreamEvent']
	upstream_event_type      string            @[json: 'upstreamEventType']
	upstream_message_id      string            @[json: 'upstreamMessageId']
	upstream_target          string            @[json: 'upstreamTarget']
	upstream_target_type     string            @[json: 'upstreamTargetType']
	upstream_received_at     i64               @[json: 'upstreamReceivedAt']
	upstream_metadata        map[string]string @[json: 'upstreamMetadata']
	method                   string
	path                     string
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

pub fn (e InProcVjsxExecutor) model() LogicExecutorModel {
	_ = e
	return .embedded
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
		if state.lanes[idx].inflight > 0 {
			continue
		}
		if !state.lanes[idx].healthy && !state.lanes[idx].dirty {
			continue
		}
		state.lanes[idx].inflight++
		state.rr_index = (idx + 1) % state.lanes.len
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_no_available_lane')
}

fn (e InProcVjsxExecutor) acquire_next_lane(timeout_ms int) !VjsxExecutionLane {
	mut remaining_ms := if timeout_ms > 0 { timeout_ms } else { 0 }
	deadline := time.now().add(time.millisecond * remaining_ms)
	for {
		lane := e.select_next_lane() or {
			if err.msg() != 'inproc_vjsx_executor_no_available_lane' {
				return error(err.msg())
			}
			if remaining_ms <= 0 || time.now() >= deadline {
				return error(err.msg())
			}
			time.sleep(time.millisecond * inproc_vjsx_lane_wait_poll_ms)
			remaining_ms -= inproc_vjsx_lane_wait_poll_ms
			continue
		}
		return lane
	}
	return error('inproc_vjsx_executor_no_available_lane')
}

fn inproc_vjsx_should_retry_dispatch(err_msg string) bool {
	return err_msg.starts_with('inproc_vjsx_executor_runtime_create_failed:')
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
		state.lanes[i].dirty = false
		state.lanes[i].last_error = ''
		if i < state.hosts.len {
			state.hosts[i].dirty = false
		}
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
		state.lanes[i].dirty = true
		state.lanes[i].last_error = err_msg
		if i < state.hosts.len {
			state.hosts[i].dirty = true
		}
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

fn normalize_vjsx_signature_glob(raw string) string {
	return raw.trim_space().replace('\\', '/').trim_left('/')
}

fn normalize_vjsx_signature_rel_path(raw string) string {
	mut rel := raw.trim_space().replace('\\', '/')
	if rel == '.' {
		return ''
	}
	rel = rel.trim_left('/')
	for rel.starts_with('./') {
		rel = rel[2..]
	}
	return rel
}

fn vjsx_signature_root_for_config(config VjsxRuntimeFacadeConfig) string {
	if config.signature_root.trim_space() != '' {
		return os.abs_path(config.signature_root)
	}
	if config.module_root.trim_space() != '' {
		return os.abs_path(config.module_root)
	}
	if config.app_entry.trim_space() != '' {
		return os.dir(os.abs_path(config.app_entry))
	}
	return ''
}

fn vjsx_signature_include_globs(config VjsxRuntimeFacadeConfig) []string {
	return config.signature_include.map(normalize_vjsx_signature_glob).filter(it != '')
}

fn vjsx_signature_exclude_globs(config VjsxRuntimeFacadeConfig) []string {
	mut out := []string{}
	for pattern in vjsx_default_signature_excludes {
		normalized := normalize_vjsx_signature_glob(pattern)
		if normalized != '' {
			out << normalized
		}
	}
	for pattern in config.signature_exclude {
		normalized := normalize_vjsx_signature_glob(pattern)
		if normalized != '' {
			out << normalized
		}
	}
	return out
}

fn vjsx_signature_glob_patterns(include_globs []string) []string {
	if include_globs.len > 0 {
		return include_globs
	}
	mut patterns := []string{}
	for ext in vjsx_signature_source_exts {
		patterns << '*${ext}'
		patterns << '**/*${ext}'
	}
	return patterns
}

fn vjsx_signature_expand_globs(root string, globs []string) []string {
	if root.trim_space() == '' || !os.exists(root) {
		return []string{}
	}
	mut matches := map[string]bool{}
	for pattern in globs {
		normalized := normalize_vjsx_signature_glob(pattern)
		if normalized == '' {
			continue
		}
		abs_pattern := os.join_path(root, normalized)
		expanded := os.glob(abs_pattern) or { continue }
		for raw_path in expanded {
			path := os.abs_path(raw_path)
			if !os.exists(path) || os.is_dir(path) {
				continue
			}
			matches[path] = true
		}
	}
	mut out := matches.keys()
	out.sort()
	return out
}

fn vjsx_source_signature_collect(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	include_matches := vjsx_signature_expand_globs(root, vjsx_signature_glob_patterns(include_globs))
	exclude_matches := vjsx_signature_expand_globs(root, exclude_globs)
	mut exclude_set := map[string]bool{}
	for path in exclude_matches {
		exclude_set[path] = true
	}
	for path in include_matches {
		if path in exclude_set {
			continue
		}
		rel := normalize_vjsx_signature_rel_path(runtime_relative_path(root, path))
		if rel == '' {
			continue
		}
		content := os.read_file(path) or { '' }
		rows << '${rel}:${fnv1a.sum64_string(content).hex()}'
	}
}

fn vjsx_source_signature_for_config(config VjsxRuntimeFacadeConfig) string {
	entry_abs := os.abs_path(config.app_entry)
	mut signature_rows := ['entry:${entry_abs}']
	entry_content := os.read_file(entry_abs) or { '' }
	signature_rows << 'entry_content:${fnv1a.sum64_string(entry_content).hex()}'
	signature_root := vjsx_signature_root_for_config(config)
	include_globs := vjsx_signature_include_globs(config)
	exclude_globs := vjsx_signature_exclude_globs(config)
	signature_rows << 'signature_root:${signature_root}'
	signature_rows << 'signature_include:${include_globs.join(',')}'
	signature_rows << 'signature_exclude:${exclude_globs.join(',')}'
	if signature_root != '' {
		vjsx_source_signature_collect(signature_root, include_globs, exclude_globs, mut
			signature_rows)
	}
	return fnv1a.sum64_string(signature_rows.join('|')).hex()
}

fn vjsx_lane_temp_root_for_signature(config VjsxRuntimeFacadeConfig, idx int, source_signature string) string {
	entry_abs := os.abs_path(config.app_entry)
	entry_name := os.base(entry_abs).trim_space().replace(' ', '_')
	cache_root := os.join_path(os.temp_dir(), 'vhttpd_vjsx')
	return os.join_path(cache_root, '${entry_name}.${source_signature}.lane_${idx}.vjsbuild')
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
  meta = meta && typeof meta === "object" ? meta : {};
  const freezeValue = (value) => {
    try {
      return Object.freeze(value);
    } catch (_) {
      return value;
    }
  };
  try {
    const dispatchKind = typeof meta.dispatchKind === "string" && meta.dispatchKind ? meta.dispatchKind : "http";
    const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "http";
    const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
    const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : requestPath;
    const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
    const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
    const hostEmit = typeof globalThis.__vhttpd_host_emit === "function" ? globalThis.__vhttpd_host_emit : undefined;
    const hostSnapshot = typeof globalThis.__vhttpd_host_snapshot === "function" ? globalThis.__vhttpd_host_snapshot : undefined;
    const hostReadFile = typeof globalThis.__vhttpd_host_read_file === "function" ? globalThis.__vhttpd_host_read_file : undefined;
    const hostFindCodexSession = typeof globalThis.__vhttpd_host_find_codex_session === "function" ? globalThis.__vhttpd_host_find_codex_session : undefined;
    const capabilities = freezeValue({
      http: dispatchKind === "http",
      stream: false,
      websocket: false,
      websocketUpstream: dispatchKind === "websocket_upstream",
      fs: !!meta.enableFs,
      process: !!meta.enableProcess,
      network: !!meta.enableNetwork
    });
    const request = freezeValue({
      id: meta.requestId,
      traceId: meta.traceId,
      method: meta.method,
      path: requestPath,
      url: requestPath,
      target: requestTarget,
      href: requestHref,
      origin: requestOrigin,
      scheme: requestScheme,
      host: requestHost,
      port: requestPort,
      protocolVersion: meta.requestProtocolVersion,
      remoteAddr: meta.requestRemoteAddr,
      ip: meta.requestRemoteAddr,
      server: freezeValue(meta.requestServer || {})
    });
    const upstream = dispatchKind === "websocket_upstream"
      ? freezeValue({
          provider: typeof meta.upstreamProvider === "string" ? meta.upstreamProvider : "",
          instance: typeof meta.upstreamInstance === "string" ? meta.upstreamInstance : "",
          event: typeof meta.upstreamEvent === "string" ? meta.upstreamEvent : "message",
          eventType: typeof meta.upstreamEventType === "string" ? meta.upstreamEventType : "",
          messageId: typeof meta.upstreamMessageId === "string" ? meta.upstreamMessageId : "",
          target: typeof meta.upstreamTarget === "string" ? meta.upstreamTarget : "",
          targetType: typeof meta.upstreamTargetType === "string" ? meta.upstreamTargetType : "",
          receivedAt: typeof meta.upstreamReceivedAt === "number" ? meta.upstreamReceivedAt : 0,
          metadata: freezeValue(meta.upstreamMetadata || {})
        })
      : undefined;
    const runtime = {
      provider: meta.provider,
      executor: meta.executor,
      dispatchKind,
      laneId: meta.laneId,
      requestId: meta.requestId,
      traceId: meta.traceId,
      appEntry: meta.appEntry,
      moduleRoot: meta.moduleRoot,
      runtimeProfile: meta.runtimeProfile,
      threadCount: meta.threadCount,
      capabilities,
      request,
      upstream,
      method: meta.method,
      path: requestPath,
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
        if (typeof hostEmit !== "function") {
          return false;
        }
        const normalizedFields = {};
        if (fields && typeof fields === "object") {
          for (const [key, value] of Object.entries(fields)) {
            normalizedFields[String(key)] = value == null ? "" : String(value);
          }
        }
        return !!hostEmit(String(kind), normalizedFields);
      },
      snapshot() {
        if (typeof hostSnapshot !== "function") {
          return undefined;
        }
        const raw = hostSnapshot();
        if (raw === undefined || raw === null || raw === "") {
          return undefined;
        }
        try {
          const snapshot = JSON.parse(String(raw));
          if (snapshot && typeof snapshot === "object") {
            return freezeValue(snapshot);
          }
          return snapshot;
        } catch (_) {
          return undefined;
        }
      },
      readTextFile(path, fallbackValue = "") {
        if (!this.capabilities || !this.capabilities.fs || typeof hostReadFile !== "function") {
          return fallbackValue;
        }
        const raw = hostReadFile(path == null ? "" : String(path));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        return String(raw);
      },
      findCodexSessionPath(threadId, fallbackValue = "") {
        if (!this.capabilities || !this.capabilities.fs || typeof hostFindCodexSession !== "function") {
          return fallbackValue;
        }
        const raw = hostFindCodexSession(threadId == null ? "" : String(threadId));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        return String(raw);
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
          dispatchKind: this.dispatchKind,
          method: this.method,
          path: this.path
        };
      }
    };
    return freezeValue(runtime);
  } catch (err) {
    const errorMessage = err && typeof err === "object" && "stack" in err && err.stack
      ? String(err.stack)
      : String(err);
    if (typeof console !== "undefined" && console && typeof console.error === "function") {
      console.error("[vhttpd]", meta.laneId || "", meta.requestId || "", meta.traceId || "", "runtime facade create failed", errorMessage, JSON.stringify(meta));
    }
    const dispatchKind = typeof meta.dispatchKind === "string" && meta.dispatchKind ? meta.dispatchKind : "http";
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    return freezeValue({
      provider: typeof meta.provider === "string" ? meta.provider : "",
      executor: typeof meta.executor === "string" ? meta.executor : "",
      dispatchKind,
      laneId: typeof meta.laneId === "string" ? meta.laneId : "",
      requestId: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
      moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
      runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
      threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
      capabilities: freezeValue({
        http: dispatchKind === "http",
        stream: false,
        websocket: false,
        websocketUpstream: dispatchKind === "websocket_upstream",
        fs: !!meta.enableFs,
        process: !!meta.enableProcess,
        network: !!meta.enableNetwork
      }),
      request: freezeValue({
        id: typeof meta.requestId === "string" ? meta.requestId : "",
        traceId: typeof meta.traceId === "string" ? meta.traceId : "",
        method: typeof meta.method === "string" ? meta.method : "",
        path: requestPath,
        url: requestPath,
        target: typeof meta.requestTarget === "string" ? meta.requestTarget : requestPath,
        href: typeof meta.requestTarget === "string" ? meta.requestTarget : requestPath,
        origin: "",
        scheme: typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "http",
        host: typeof meta.requestHost === "string" ? meta.requestHost : "",
        port: typeof meta.requestPort === "string" ? meta.requestPort : "",
        protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
        remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        server: freezeValue(meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {})
      }),
      upstream: dispatchKind === "websocket_upstream"
        ? freezeValue({
            provider: typeof meta.upstreamProvider === "string" ? meta.upstreamProvider : "",
            instance: typeof meta.upstreamInstance === "string" ? meta.upstreamInstance : "",
            event: typeof meta.upstreamEvent === "string" ? meta.upstreamEvent : "message",
            eventType: typeof meta.upstreamEventType === "string" ? meta.upstreamEventType : "",
            messageId: typeof meta.upstreamMessageId === "string" ? meta.upstreamMessageId : "",
            target: typeof meta.upstreamTarget === "string" ? meta.upstreamTarget : "",
            targetType: typeof meta.upstreamTargetType === "string" ? meta.upstreamTargetType : "",
            receivedAt: typeof meta.upstreamReceivedAt === "number" ? meta.upstreamReceivedAt : 0,
            metadata: freezeValue(meta.upstreamMetadata && typeof meta.upstreamMetadata === "object" ? meta.upstreamMetadata : {})
          })
        : undefined,
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      runtimeInitError: errorMessage,
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
      emit() {
        return false;
      },
      snapshot() {
        return undefined;
      },
      readTextFile(_path, fallbackValue = "") {
        return fallbackValue;
      },
      findCodexSessionPath(_threadId, fallbackValue = "") {
        return fallbackValue;
      },
      toJSON() {
        return {
          provider: this.provider,
          executor: this.executor,
          laneId: this.laneId,
          requestId: this.requestId,
          traceId: this.traceId,
          dispatchKind: this.dispatchKind,
          method: this.method,
          path: this.path,
          runtimeInitError: this.runtimeInitError
        };
      }
    });
  }
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
globalThis.__vhttpd_create_websocket_upstream_frame = function(raw, runtime) {
  raw = raw && typeof raw === "object" ? raw : {};
  runtime = runtime && typeof runtime === "object" ? runtime : {};
  const frame = {
    mode: typeof raw.mode === "string" && raw.mode ? raw.mode : "websocket_upstream",
    event: typeof raw.event === "string" && raw.event ? raw.event : "message",
    id: typeof raw.id === "string" ? raw.id : runtime.requestId,
    provider: typeof raw.provider === "string" ? raw.provider : (runtime.upstream?.provider || ""),
    instance: typeof raw.instance === "string" ? raw.instance : (runtime.upstream?.instance || ""),
    traceId: typeof raw.trace_id === "string" ? raw.trace_id : runtime.traceId,
    eventType: typeof raw.event_type === "string" ? raw.event_type : (runtime.upstream?.eventType || ""),
    messageId: typeof raw.message_id === "string" ? raw.message_id : (runtime.upstream?.messageId || ""),
    target: typeof raw.target === "string" ? raw.target : (runtime.upstream?.target || ""),
    targetType: typeof raw.target_type === "string" ? raw.target_type : (runtime.upstream?.targetType || ""),
    payload: raw.payload == null ? "" : String(raw.payload),
    receivedAt: typeof raw.received_at === "number" ? raw.received_at : (runtime.upstream?.receivedAt || 0),
    metadata: raw.metadata && typeof raw.metadata === "object" ? Object.freeze(raw.metadata) : Object.freeze({}),
    runtime,
    payloadText(fallbackValue) {
      if (this.payload === "") {
        return fallbackValue;
      }
      return this.payload;
    },
    payloadJson(fallbackValue) {
      if (this.payload == null || String(this.payload).trim() === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(this.payload));
      } catch (_) {
        return fallbackValue;
      }
    }
  };
  return Object.freeze(frame);
};
globalThis.__vhttpd_normalize_result = function(ctx, result) {
  if (result === undefined || result === null) {
    return ctx.response;
  }
  return result;
};
globalThis.__vhttpd_bind_method = function(target, key) {
  if (!target || (typeof target !== "object" && typeof target !== "function")) {
    return undefined;
  }
  const value = target[key];
  if (typeof value !== "function") {
    return undefined;
  }
  return typeof value.bind === "function" ? value.bind(target) : value;
};
globalThis.__vhttpd_resolve_handler_for_kind = function(exportsValue, kind) {
  const httpAliases = ["http", "handle", "handleHttp", "handle_http"];
  const upstreamAliases = ["websocket_upstream", "websocketUpstream", "handleWebSocketUpstream", "handle_websocket_upstream"];
  const aliases = kind === "websocket_upstream" ? upstreamAliases : httpAliases;
  if (exportsValue && typeof exportsValue === "object") {
    if (kind === "http") {
      if (typeof exportsValue.default === "function") {
        return exportsValue.default;
      }
      if (typeof exportsValue.handle === "function") {
        return exportsValue.handle;
      }
    } else {
      for (const key of upstreamAliases) {
        if (typeof exportsValue[key] === "function") {
          return exportsValue[key];
        }
      }
    }
    for (const key of aliases) {
      const boundExport = globalThis.__vhttpd_bind_method(exportsValue, key);
      if (typeof boundExport === "function") {
        return boundExport;
      }
    }
    const defaultExport = exportsValue.default;
    if (defaultExport && (typeof defaultExport === "object" || typeof defaultExport === "function")) {
      for (const key of aliases) {
        const boundDefault = globalThis.__vhttpd_bind_method(defaultExport, key);
        if (typeof boundDefault === "function") {
          return boundDefault;
        }
      }
    }
  }
  if (kind === "http" && typeof globalThis.__vhttpd_handle === "function") {
    return globalThis.__vhttpd_handle;
  }
  if (kind === "websocket_upstream" && typeof globalThis.__vhttpd_websocket_upstream_handle === "function") {
    return globalThis.__vhttpd_websocket_upstream_handle;
  }
  return undefined;
};
globalThis.__vhttpd_resolve_handler = function(exportsValue) {
  return globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "http");
};
globalThis.__vhttpd_bind_handler = function(exportsValue) {
  const handler = globalThis.__vhttpd_resolve_handler(exportsValue);
  if (typeof handler === "function") {
    globalThis.__vhttpd_handle = handler;
  }
  return handler;
};
globalThis.__vhttpd_bind_handlers = function(exportsValue) {
  const httpHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "http");
  const websocketUpstreamHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "websocket_upstream");
  if (typeof httpHandler === "function") {
    globalThis.__vhttpd_handle = httpHandler;
  }
  if (typeof websocketUpstreamHandler === "function") {
    globalThis.__vhttpd_websocket_upstream_handle = websocketUpstreamHandler;
  }
  return {
    http: httpHandler,
    websocket_upstream: websocketUpstreamHandler
  };
};
globalThis.__vhttpd_register_exports = function(exportsValue) {
  if (!exportsValue || typeof exportsValue !== "object") {
    return globalThis.__vhttpd_bind_handlers(undefined);
  }
  return globalThis.__vhttpd_bind_handlers(exportsValue);
};
globalThis.__vhttpd_normalize_websocket_upstream_result = function(frame, result) {
  if (result === undefined || result === null || result === false) {
    return {
      handled: false,
      commands: []
    };
  }
  if (result === true) {
    return {
      handled: true,
      commands: []
    };
  }
  if (Array.isArray(result)) {
    return {
      handled: true,
      commands: result
    };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid websocket_upstream result type");
  }
  return {
    handled: Object.prototype.hasOwnProperty.call(result, "handled") ? !!result.handled : true,
    commands: Array.isArray(result.commands) ? result.commands : []
  };
};
')!
	ctx.end()
}

fn load_inproc_vjsx_entry(mut ctx vjsx.Context, config VjsxRuntimeFacadeConfig, idx int, source_signature string, as_module bool) !vjsx.Value {
	temp_root := vjsx_lane_temp_root_for_signature(config, idx, source_signature)
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
	mut host_read_file := ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
		_ = idx
		if args.len == 0 {
			return ctx.js_string('')
		}
		path := args[0].to_string().trim_space()
		if path == '' {
			return ctx.js_string('')
		}
		mut enable_fs := false
		state.mu.@lock()
		enable_fs = state.facade.config.enable_fs
		state.mu.unlock()
		if !enable_fs {
			return ctx.js_string('')
		}
		content := os.read_file(path) or {
			resolved := os.real_path(path)
			if resolved != '' && resolved != path {
				return ctx.js_string(os.read_file(resolved) or { '' })
			}
			return ctx.js_string('')
		}
		return ctx.js_string(content)
	})
	mut host_find_codex_session := ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
		_ = idx
		if args.len == 0 {
			return ctx.js_string('')
		}
		thread_id := args[0].to_string().trim_space()
		if thread_id == '' {
			return ctx.js_string('')
		}
		mut enable_fs := false
		state.mu.@lock()
		enable_fs = state.facade.config.enable_fs
		state.mu.unlock()
		if !enable_fs {
			return ctx.js_string('')
		}
		return ctx.js_string(inproc_vjsx_find_codex_session_file(thread_id))
	})
	global.set('__vhttpd_host_emit', host_emit)
	global.set('__vhttpd_host_snapshot', host_snapshot)
	global.set('__vhttpd_host_read_file', host_read_file)
	global.set('__vhttpd_host_find_codex_session', host_find_codex_session)
	host_emit.free()
	host_snapshot.free()
	host_read_file.free()
	host_find_codex_session.free()
	global.free()
}

fn inproc_vjsx_destroy_lane_host(mut host VjsxLaneHost) {
	if !isnil(host.ctx) {
		host.ctx.free()
		host.ctx = unsafe { nil }
	}
	if !isnil(host.rt) {
		host.rt.free()
		host.rt = unsafe { nil }
	}
	host.initialized = false
	host.dirty = false
	host.source_signature = ''
	host.request_ctx = InProcVjsxRequestContext{}
}

fn (e InProcVjsxExecutor) reset_lane_host(idx int) {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len {
		state.mu.unlock()
		return
	}
	mut stale := state.hosts[idx]
	state.hosts[idx] = VjsxLaneHost{}
	state.mu.unlock()
	inproc_vjsx_destroy_lane_host(mut stale)
}

fn (e InProcVjsxExecutor) ensure_lane_host(idx int) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := e.facade_snapshot().config
	source_signature := vjsx_source_signature_for_config(config)
	mut needs_reset := false
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len || idx >= state.lanes.len {
		state.mu.unlock()
		return error('inproc_vjsx_executor_invalid_lane')
	}
	host := state.hosts[idx]
	if host.initialized && !host.dirty && host.source_signature == source_signature {
		state.mu.unlock()
		return
	}
	needs_reset = host.initialized
	state.mu.unlock()
	if needs_reset {
		e.reset_lane_host(idx)
	}

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
	mut entry_exports := load_inproc_vjsx_entry(mut ctx, config, idx, source_signature,
		as_module) or {
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
	bind_handlers := ctx.js_global('__vhttpd_bind_handlers')
	defer {
		bind_handlers.free()
	}
	if !bind_handlers.is_undefined() && bind_handlers.is_function() {
		mut bound := ctx.call(bind_handlers, entry_exports) or {
			ctx.free()
			rt.free()
			return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
		}
		defer {
			bound.free()
		}
	}
	http_handler := ctx.js_global('__vhttpd_handle')
	upstream_handler := ctx.js_global('__vhttpd_websocket_upstream_handle')
	has_http_handler := !http_handler.is_undefined() && http_handler.is_function()
	has_upstream_handler := !upstream_handler.is_undefined() && upstream_handler.is_function()
	http_handler.free()
	upstream_handler.free()
	if !has_http_handler && !has_upstream_handler {
		ctx.free()
		rt.free()
		return error('inproc_vjsx_executor_missing_handler')
	}

	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	state.hosts[idx] = VjsxLaneHost{
		initialized:      true
		dirty:            false
		source_signature: source_signature
		rt:               rt
		ctx:              ctx
	}
	state.lanes[idx].healthy = true
	state.lanes[idx].dirty = false
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
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'http'
		lane_id:                  lane.id
		request_id:               req.request_id
		trace_id:                 req.trace_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           scheme
		request_host:             host
		request_port:             port
		request_target:           target
		request_protocol_version: req.req.version.str().trim_left('HTTP/')
		request_remote_addr:      req.remote_addr
		request_server:           server
		method:                   req.method.to_upper()
		path:                     normalized_path
	})
}

fn (e InProcVjsxExecutor) build_websocket_upstream_runtime_payload(lane VjsxExecutionLane, req WorkerWebSocketUpstreamDispatchRequest) string {
	config := e.facade_snapshot().config
	return json.encode(InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'websocket_upstream'
		lane_id:                  lane.id
		request_id:               req.id
		trace_id:                 req.trace_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           ''
		request_host:             ''
		request_port:             ''
		request_target:           req.target
		request_protocol_version: ''
		request_remote_addr:      ''
		request_server:           map[string]string{}
		upstream_provider:        req.provider
		upstream_instance:        req.instance
		upstream_event:           req.event
		upstream_event_type:      req.event_type
		upstream_message_id:      req.message_id
		upstream_target:          req.target
		upstream_target_type:     req.target_type
		upstream_received_at:     req.received_at
		upstream_metadata:        req.metadata.clone()
		method:                   ''
		path:                     req.target
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

struct InProcVjsxWebSocketUpstreamResult {
	handled  bool
	commands []WorkerWebSocketUpstreamCommand
}

fn websocket_upstream_response_from_js_value(val vjsx.Value, req WorkerWebSocketUpstreamDispatchRequest) WorkerWebSocketUpstreamDispatchResponse {
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return WorkerWebSocketUpstreamDispatchResponse{
			mode:     'websocket_upstream'
			event:    'result'
			id:       req.id
			handled:  false
			commands: []WorkerWebSocketUpstreamCommand{}
		}
	}
	normalized := json.decode(InProcVjsxWebSocketUpstreamResult, raw) or {
		InProcVjsxWebSocketUpstreamResult{}
	}
	return WorkerWebSocketUpstreamDispatchResponse{
		mode:     'websocket_upstream'
		event:    'result'
		id:       req.id
		handled:  normalized.handled
		commands: normalized.commands
	}
}

fn (e InProcVjsxExecutor) dispatch_http_once(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	e.bootstrap_placeholder()!
	lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
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

pub fn (e InProcVjsxExecutor) dispatch_http(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	mut last_err := 'inproc_vjsx_executor_dispatch_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		outcome := e.dispatch_http_once(mut app, req) or {
			last_err = err.msg()
			if attempt + 1 < inproc_vjsx_dispatch_retry_attempts
				&& inproc_vjsx_should_retry_dispatch(last_err) {
				continue
			}
			return error(last_err)
		}
		return outcome
	}
	return error(last_err)
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

fn (e InProcVjsxExecutor) dispatch_websocket_upstream_once(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	e.bootstrap_placeholder()!
	lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
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
	e.activate_lane_request_context(idx, mut app, lane.id, HttpLogicDispatchRequest{
		method:     req.event
		path:       req.target
		trace_id:   req.trace_id
		request_id: req.id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	frame_obj := host.ctx.json_parse(json.encode(req))
	defer {
		frame_obj.free()
	}
	runtime_obj := host.ctx.json_parse(e.build_websocket_upstream_runtime_payload(lane,
		req))
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
	create_frame_fn := host.ctx.js_global('__vhttpd_create_websocket_upstream_frame')
	defer {
		create_frame_fn.free()
	}
	mut js_frame := host.ctx.call(create_frame_fn, frame_obj, js_runtime) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_upstream_frame_create_failed:${err.msg()}')
	}
	defer {
		js_frame.free()
	}
	handler := host.ctx.js_global('__vhttpd_websocket_upstream_handle')
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		e.record_lane_success(lane.id)
		return WorkerWebSocketUpstreamDispatchResponse{
			mode:     'websocket_upstream'
			event:    'result'
			id:       req.id
			handled:  false
			commands: []WorkerWebSocketUpstreamCommand{}
		}
	}
	mut result := host.ctx.call(handler, js_frame) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_websocket_upstream_handler_failed:${err.msg()}')
	}
	defer {
		result.free()
	}
	normalize_fn := host.ctx.js_global('__vhttpd_normalize_websocket_upstream_result')
	defer {
		normalize_fn.free()
	}
	if result.instanceof('Promise') {
		mut awaited := result.await()
		defer {
			awaited.free()
		}
		mut normalized := host.ctx.call(normalize_fn, js_frame, awaited) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_websocket_upstream_normalize_failed:${err.msg()}')
		}
		defer {
			normalized.free()
		}
		e.record_lane_success(lane.id)
		return websocket_upstream_response_from_js_value(normalized, req)
	}
	mut normalized := host.ctx.call(normalize_fn, js_frame, result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_websocket_upstream_normalize_failed:${err.msg()}')
	}
	defer {
		normalized.free()
	}
	e.record_lane_success(lane.id)
	return websocket_upstream_response_from_js_value(normalized, req)
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_upstream(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	mut last_err := 'inproc_vjsx_executor_dispatch_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		outcome := e.dispatch_websocket_upstream_once(mut app, req) or {
			last_err = err.msg()
			if attempt + 1 < inproc_vjsx_dispatch_retry_attempts
				&& inproc_vjsx_should_retry_dispatch(last_err) {
				continue
			}
			return error(last_err)
		}
		return outcome
	}
	return error(last_err)
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return inproc_vjsx_not_ready_error('dispatch_websocket_event')
}
