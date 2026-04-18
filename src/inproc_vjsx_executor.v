module main

import json
import net.http
import net.urllib
import os
import sync
import time
import vjsx
import vjsx.runtimejs
import x.json2

const inproc_vjsx_lane_wait_timeout_ms = 1000
const inproc_vjsx_lane_wait_poll_ms = 5
const inproc_vjsx_dispatch_retry_attempts = 2
const inproc_vjsx_startup_wait_poll_ms = 5
const inproc_vjsx_signature_probe_poll_ms = 100
const inproc_vjsx_signature_refresh_debounce_ms = 200
const inproc_vjsx_signature_full_refresh_ms = 3000

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
	build_root        string
	signature_root    string
	signature_include []string
	signature_exclude []string
	runtime_profile   string
	thread_count      int
	max_requests      int
	enable_fs         bool
	enable_process    bool
	enable_network    bool
	websocket_affinity WebSocketAffinityConfig
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
	mu                           sync.Mutex
	facade                       VjsxRuntimeFacade
	lanes                        []VjsxExecutionLane
	hosts                        []VjsxLaneHost
	rr_index                     int
	websocket_affinity_lane_by_key map[string]string
	websocket_affinity_ref_count_by_key map[string]int
	websocket_connection_lane_by_id map[string]string
	websocket_connection_affinity_key_by_id map[string]string
	cached_source_probe          string
	cached_source_signature      string
	signature_refresh_started    bool
	signature_refresh_stop       bool
	signature_last_checked_at    i64
	signature_last_probe_at      i64
	signature_pending_since      i64
	signature_last_error         string
	warmup_source_signature      string
	warmup_running               bool
	warmup_completed             bool
	warmup_last_error            string
	app_startup_source_signature string
	app_startup_running          bool
	app_startup_completed        bool
	app_startup_last_error       string
}

struct VjsxLaneHost {
mut:
	initialized       bool
	startup_completed bool
	dirty             bool
	source_signature  string
	is_module_entry   bool
	temp_root         string
	app_ref           &App = unsafe { nil }
	session           &vjsx.RuntimeSession = unsafe { nil }
	module_binding    &vjsx.ScriptModule   = unsafe { nil }
	request_ctx       InProcVjsxRequestContext
}

fn vjsx_empty_lane_host() VjsxLaneHost {
	return VjsxLaneHost{
		session:        unsafe { nil }
		module_binding: unsafe { nil }
	}
}

pub struct InProcVjsxExecutor {
pub:
	provider_name string = 'vjsx'
	kind_name     string = 'vjsx'
pub mut:
	state &VjsxExecutorState = unsafe { nil }
}

struct InProcVjsxHostHttpFetchResponse {
	ok      bool
	status  int
	body    string
	headers map[string]string
	error   string
}

struct InProcVjsxHostHttpFetchRequest {
	url     string
	method  string
	body    string
	headers map[string]string
}

struct InProcVjsxHostBridgeDispatchRequest {
	app         string
	trace_id    string            @[json: 'trace_id']
	event_type  string            @[json: 'event_type']
	message_id  string            @[json: 'message_id']
	target      string
	target_type string            @[json: 'target_type']
	payload     string
}

struct InProcVjsxHostWebSocketDispatchRequest {
	commands []WorkerWebSocketFrame
}

struct InProcVjsxHostWebSocketDispatchResponse {
	ok         bool
	has_close  bool              @[json: 'has_close']
	close_code int               @[json: 'close_code']
	close_reason string          @[json: 'close_reason']
	close_target_id string       @[json: 'close_target_id']
	failures   []WorkerWebSocketDispatchCommandFailure
	error      string
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
	build_root               string            @[json: 'buildRoot']
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

struct InProcVjsxWebSocketFrameBundle {
	raw     WorkerWebSocketFrame
	runtime InProcVjsxRuntimeMeta
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
	mut hosts := []VjsxLaneHost{}
	for _ in 0 .. lanes.len {
		hosts << vjsx_empty_lane_host()
	}
	initial_probe := if config.app_entry.trim_space() != '' {
		vjsx_source_probe_for_config(config)
	} else {
		''
	}
	initial_signature := if config.app_entry.trim_space() != '' {
		vjsx_source_signature_for_config(config)
	} else {
		''
	}
	now_ms := time.now().unix_milli()
	return InProcVjsxExecutor{
		state: &VjsxExecutorState{
			facade: VjsxRuntimeFacade{
				config: config
			}
			lanes:                               lanes
			hosts:                               hosts
			websocket_affinity_lane_by_key:      map[string]string{}
			websocket_affinity_ref_count_by_key: map[string]int{}
			websocket_connection_lane_by_id:     map[string]string{}
			websocket_connection_affinity_key_by_id: map[string]string{}
			cached_source_probe:                 initial_probe
			cached_source_signature:             initial_signature
			signature_last_checked_at: if initial_signature != '' {
				now_ms
			} else {
				0
			}
			signature_last_probe_at: if initial_probe != '' {
				now_ms
			} else {
				0
			}
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

pub fn (e InProcVjsxExecutor) admin_details() LogicExecutorAdminDetails {
	config := e.facade_snapshot().config
	return LogicExecutorAdminDetails{
		kind:            e.kind()
		provider:        e.provider()
		model:           LogicExecutorModel.embedded.str()
		runtime_profile: config.runtime_profile
		lane_count:      config.thread_count
		module_root:     config.module_root
		build_root:      config.build_root
		signature_root:  config.signature_root
		max_requests:    config.max_requests
		enable_fs:       config.enable_fs
		enable_process:  config.enable_process
		enable_network:  config.enable_network
	}
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

pub fn (e InProcVjsxExecutor) warmup(mut app App) ! {
	e.bootstrap_placeholder()!
	lane_count := e.lane_count()
	if lane_count <= 0 {
		return
	}
	for idx in 0 .. lane_count {
		e.ensure_lane_host(idx) or {
			e.record_lane_error('lane_${idx}', err.msg())
			return error(err.msg())
		}
	}
	lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
	defer {
		e.release_lane(lane.id)
	}
	idx := e.lane_index_by_id(lane.id)
	if idx < 0 {
		e.record_lane_error(lane.id, 'inproc_vjsx_executor_lane_not_found')
		return error('inproc_vjsx_executor_lane_not_found')
	}
	mut source_signature := ''
	mut state := e.state
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len {
		source_signature = state.hosts[idx].source_signature
	}
	if state.warmup_source_signature != source_signature {
		state.warmup_source_signature = source_signature
		state.warmup_running = false
		state.warmup_completed = false
		state.warmup_last_error = ''
	}
	state.mu.unlock()
	for {
		state.mu.@lock()
		if state.warmup_source_signature != source_signature {
			state.warmup_source_signature = source_signature
			state.warmup_running = false
			state.warmup_completed = false
			state.warmup_last_error = ''
		}
		if state.warmup_completed {
			state.mu.unlock()
			return
		}
		if !state.warmup_running && state.warmup_last_error != '' {
			last_error := state.warmup_last_error
			state.mu.unlock()
			return error(last_error)
		}
		if state.warmup_running {
			state.mu.unlock()
			time.sleep(time.millisecond * inproc_vjsx_startup_wait_poll_ms)
			continue
		}
		state.warmup_running = true
		state.warmup_last_error = ''
		state.mu.unlock()
		e.run_app_startup(mut app, idx, lane) or {
			state.mu.@lock()
			state.warmup_running = false
			state.warmup_completed = false
			state.warmup_last_error = err.msg()
			state.mu.unlock()
			e.record_lane_error(lane.id, err.msg())
			return error(err.msg())
		}
		state.mu.@lock()
		state.warmup_running = false
		state.warmup_completed = true
		state.warmup_last_error = ''
		state.mu.unlock()
		return
	}
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
	if !state.signature_refresh_started {
		state.signature_refresh_started = true
		go inproc_vjsx_signature_refresh_loop(mut state)
	}
	state.facade.bootstrapped = true
	state.facade.last_error = ''
}

fn inproc_vjsx_signature_refresh_loop(mut state VjsxExecutorState) {
	if isnil(state) {
		return
	}
	mut last_probe := ''
	mut pending_since := i64(0)
	for {
		mut stop := false
		mut config := VjsxRuntimeFacadeConfig{}
		mut last_checked_at := i64(0)
		state.mu.@lock()
		stop = state.signature_refresh_stop
		config = state.facade.config
		last_probe = if last_probe != '' { last_probe } else { state.cached_source_probe }
		pending_since = if pending_since > 0 { pending_since } else { state.signature_pending_since }
		last_checked_at = state.signature_last_checked_at
		state.mu.unlock()
		if stop {
			return
		}
		now := time.now().unix_milli()
		next_probe := if config.app_entry.trim_space() != '' {
			vjsx_source_probe_for_config(config)
		} else {
			''
		}
		probe_changed := next_probe != last_probe
		if probe_changed {
			last_probe = next_probe
			pending_since = now
		}
		needs_full_refresh := probe_changed
			|| (pending_since > 0 && now - pending_since >= inproc_vjsx_signature_refresh_debounce_ms)
			|| (last_checked_at <= 0 || now - last_checked_at >= inproc_vjsx_signature_full_refresh_ms)
		mut next_signature := ''
		if needs_full_refresh {
			next_signature = if config.app_entry.trim_space() != '' {
				vjsx_source_signature_for_config(config)
			} else {
				''
			}
		}
		state.mu.@lock()
		if state.signature_refresh_stop {
			state.mu.unlock()
			return
		}
		state.cached_source_probe = next_probe
		state.signature_last_probe_at = now
		state.signature_pending_since = pending_since
		if needs_full_refresh {
			state.cached_source_signature = next_signature
			state.signature_last_checked_at = now
			state.signature_pending_since = 0
			pending_since = 0
		}
		state.signature_last_error = ''
		state.mu.unlock()
		time.sleep(time.millisecond * inproc_vjsx_signature_probe_poll_ms)
	}
}

fn (e InProcVjsxExecutor) current_source_signature() string {
	if isnil(e.state) {
		return ''
	}
	mut state := e.state
	state.mu.@lock()
	mut cached := state.cached_source_signature
	config := state.facade.config
	state.mu.unlock()
	if cached != '' {
		return cached
	}
	if config.app_entry.trim_space() == '' {
		return ''
	}
	cached = vjsx_source_signature_for_config(config)
	state.mu.@lock()
	if state.cached_source_signature == '' {
		state.cached_source_signature = cached
		state.signature_last_checked_at = time.now().unix_milli()
		state.signature_last_error = ''
	}
	result := state.cached_source_signature
	state.mu.unlock()
	return result
}

fn normalize_websocket_affinity_source(raw string) string {
	source := raw.trim_space().to_lower()
	return match source {
		'header', 'headers' { 'header' }
		'path_param', 'path-param', 'pathparam' { 'path_param' }
		else { 'query' }
	}
}

fn normalize_websocket_affinity_scope(raw string) string {
	scope := raw.trim_space().to_lower()
	return if scope == '' { 'lane' } else { scope }
}

fn normalize_websocket_affinity_fallback(raw string) string {
	fallback := raw.trim_space().to_lower()
	return if fallback == 'reject' { 'reject' } else { 'round_robin' }
}

fn websocket_affinity_header_lookup(headers map[string]string, key string) string {
	if key == '' {
		return ''
	}
	if key in headers {
		return headers[key]
	}
	lower_key := key.to_lower()
	for name, value in headers {
		if name.to_lower() == lower_key {
			return value
		}
	}
	return ''
}

fn websocket_affinity_value(frame WorkerWebSocketFrame, config WebSocketAffinityConfig) string {
	if !config.enabled || normalize_websocket_affinity_scope(config.scope) != 'lane' {
		return ''
	}
	key := config.key.trim_space()
	if key == '' {
		return ''
	}
	return match normalize_websocket_affinity_source(config.source) {
		'header' { websocket_affinity_header_lookup(frame.headers, key).trim_space() }
		'path_param' { '' }
		else { (frame.query[key] or { '' }).trim_space() }
	}
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

fn (e InProcVjsxExecutor) select_lane_by_id(lane_id string) !VjsxExecutionLane {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	if lane_id.trim_space() == '' {
		return error('inproc_vjsx_executor_lane_id_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for idx, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		if state.lanes[idx].inflight > 0 {
			return error('inproc_vjsx_executor_no_available_lane')
		}
		if !state.lanes[idx].healthy && !state.lanes[idx].dirty {
			return error('inproc_vjsx_executor_no_available_lane')
		}
		state.lanes[idx].inflight++
		state.rr_index = (idx + 1) % state.lanes.len
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_lane_not_found')
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

fn (e InProcVjsxExecutor) acquire_lane_by_id(lane_id string, timeout_ms int) !VjsxExecutionLane {
	mut remaining_ms := if timeout_ms > 0 { timeout_ms } else { 0 }
	deadline := time.now().add(time.millisecond * remaining_ms)
	for {
		lane := e.select_lane_by_id(lane_id) or {
			if err.msg() == 'inproc_vjsx_executor_lane_not_found' {
				return error(err.msg())
			}
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

fn (e InProcVjsxExecutor) release_websocket_connection_affinity(frame WorkerWebSocketFrame) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	state.websocket_connection_lane_by_id.delete(frame.id)
	affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	if affinity_key == '' {
		state.websocket_connection_affinity_key_by_id.delete(frame.id)
		return
	}
	state.websocket_connection_affinity_key_by_id.delete(frame.id)
	if affinity_key !in state.websocket_affinity_ref_count_by_key {
		state.websocket_affinity_lane_by_key.delete(affinity_key)
		return
	}
	mut remaining := state.websocket_affinity_ref_count_by_key[affinity_key] - 1
	if remaining <= 0 {
		state.websocket_affinity_ref_count_by_key.delete(affinity_key)
		state.websocket_affinity_lane_by_key.delete(affinity_key)
		return
	}
	state.websocket_affinity_ref_count_by_key[affinity_key] = remaining
}

fn (e InProcVjsxExecutor) acquire_websocket_lane(frame WorkerWebSocketFrame) !(VjsxExecutionLane, string) {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := state.facade.config.websocket_affinity
	state.mu.@lock()
	existing_lane_id := state.websocket_connection_lane_by_id[frame.id] or { '' }
	state.mu.unlock()
	if existing_lane_id != '' {
		return e.acquire_lane_by_id(existing_lane_id, inproc_vjsx_lane_wait_timeout_ms)!, ''
	}
	affinity_key := websocket_affinity_value(frame, config)
	if affinity_key == '' {
		if config.enabled && normalize_websocket_affinity_fallback(config.fallback) == 'reject' {
			return error('inproc_vjsx_executor_websocket_affinity_key_missing')
		}
		lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
		if frame.id.trim_space() != '' {
			state.mu.@lock()
			state.websocket_connection_lane_by_id[frame.id] = lane.id
			state.mu.unlock()
		}
		return lane, ''
	}
	state.mu.@lock()
	mapped_lane_id := state.websocket_affinity_lane_by_key[affinity_key] or { '' }
	state.mu.unlock()
	if mapped_lane_id != '' {
		lane := e.acquire_lane_by_id(mapped_lane_id, inproc_vjsx_lane_wait_timeout_ms)!
		if frame.id.trim_space() != '' {
			state.mu.@lock()
			state.websocket_connection_lane_by_id[frame.id] = lane.id
			state.websocket_connection_affinity_key_by_id[frame.id] = affinity_key
			state.websocket_affinity_ref_count_by_key[affinity_key] = (state.websocket_affinity_ref_count_by_key[affinity_key] or {
				0
			}) + 1
			state.mu.unlock()
		}
		return lane, affinity_key
	}
	lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
	state.mu.@lock()
	state.websocket_affinity_lane_by_key[affinity_key] = lane.id
	state.websocket_affinity_ref_count_by_key[affinity_key] = (state.websocket_affinity_ref_count_by_key[affinity_key] or {
		0
	}) + 1
	if frame.id.trim_space() != '' {
		state.websocket_connection_lane_by_id[frame.id] = lane.id
		state.websocket_connection_affinity_key_by_id[frame.id] = affinity_key
	}
	state.mu.unlock()
	return lane, affinity_key
}

fn inproc_vjsx_should_retry_dispatch(err_msg string) bool {
	return err_msg.starts_with('inproc_vjsx_executor_runtime_create_failed:')
}

fn inproc_vjsx_normalize_error_message(err_msg string, fallback string) string {
	normalized := err_msg.trim_space()
	if normalized != '' && normalized != '{}' {
		return normalized
	}
	return fallback
}

fn inproc_vjsx_context_error_message(ctx &vjsx.Context, err_msg string, fallback string) string {
	normalized := inproc_vjsx_normalize_error_message(err_msg, '')
	if normalized != '' {
		return normalized
	}
	js_err := ctx.js_exception()
	js_msg := js_err.msg().trim_space()
	if js_msg != '' {
		return js_msg
	}
	return fallback
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

pub fn (e InProcVjsxExecutor) record_lane_soft_error(lane_id string, err_msg string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
	normalized := inproc_vjsx_normalize_error_message(err_msg, 'inproc_vjsx_executor_unknown_error')
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[i].healthy = true
		state.lanes[i].dirty = false
		state.lanes[i].last_error = normalized
		if i < state.hosts.len {
			state.hosts[i].dirty = false
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
    const hostApi = globalThis.vhttpdHost && typeof globalThis.vhttpdHost === "object" ? globalThis.vhttpdHost : undefined;
    const hostEmit = hostApi && typeof hostApi.emit === "function"
      ? (...args) => hostApi.emit(...args)
      : undefined;
    const hostSnapshot = hostApi && typeof hostApi.snapshot === "function"
      ? (...args) => hostApi.snapshot(...args)
      : undefined;
    const hostConfig = hostApi && typeof hostApi.config === "function"
      ? (...args) => hostApi.config(...args)
      : undefined;
    const hostReadFile = hostApi && typeof hostApi.readTextFile === "function"
      ? (...args) => hostApi.readTextFile(...args)
      : undefined;
    const hostFindCodexSession = hostApi && typeof hostApi.findCodexSessionPath === "function"
      ? (...args) => hostApi.findCodexSessionPath(...args)
      : undefined;
    const hostHttpFetch = hostApi && typeof hostApi.httpFetch === "function"
      ? (...args) => hostApi.httpFetch(...args)
      : undefined;
    const hostBridgeDispatch = hostApi && typeof hostApi.bridgeDispatch === "function"
      ? (...args) => hostApi.bridgeDispatch(...args)
      : undefined;
    const hostWebSocketDispatch = hostApi && typeof hostApi.websocketDispatch === "function"
      ? (...args) => hostApi.websocketDispatch(...args)
      : undefined;
    const capabilities = freezeValue({
      http: dispatchKind === "http",
      stream: false,
      websocket: dispatchKind === "websocket",
      websocketUpstream: dispatchKind === "websocket_upstream",
      websocketDispatch: typeof hostWebSocketDispatch === "function",
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
      config(fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const raw = hostConfig("");
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      getConfig(path, fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const key = path == null ? "" : String(path);
        const raw = hostConfig(key);
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
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
      httpFetch(input, fallbackValue = undefined) {
        if (!this.capabilities || !this.capabilities.network || typeof hostHttpFetch !== "function") {
          return fallbackValue;
        }
        const request = input && typeof input === "object" ? input : {};
        const raw = hostHttpFetch(JSON.stringify({
          url: typeof request.url === "string" ? request.url : "",
          method: typeof request.method === "string" ? request.method : "GET",
          body: request.body == null ? "" : String(request.body),
          headers: request.headers && typeof request.headers === "object" ? request.headers : {},
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      },
      bridgeDispatch(input, fallbackValue = undefined) {
        if (typeof hostBridgeDispatch !== "function") {
          return fallbackValue;
        }
        const request = input && typeof input === "object" ? input : {};
        const raw = hostBridgeDispatch(JSON.stringify({
          app: typeof request.app === "string" ? request.app : "",
          trace_id: typeof request.trace_id === "string" ? request.trace_id : "",
          event_type: typeof request.event_type === "string" ? request.event_type : "",
          message_id: typeof request.message_id === "string" ? request.message_id : "",
          target: typeof request.target === "string" ? request.target : "",
          target_type: typeof request.target_type === "string" ? request.target_type : "",
          payload: typeof request.payload === "string" ? request.payload : "",
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
        }
      },
      websocketDispatch(input, fallbackValue = undefined) {
        if (typeof hostWebSocketDispatch !== "function") {
          return fallbackValue;
        }
        let commands = [];
        if (Array.isArray(input)) {
          commands = input;
        } else if (input && typeof input === "object") {
          if (Array.isArray(input.commands)) {
            commands = input.commands;
          } else {
            commands = [input];
          }
        }
        const raw = hostWebSocketDispatch(JSON.stringify({
          commands: commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, {}))
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
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
        websocketDispatch: false,
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
      config(fallbackValue = undefined) {
        return fallbackValue;
      },
      getConfig(_path, fallbackValue = undefined) {
        return fallbackValue;
      },
      readTextFile(_path, fallbackValue = "") {
        return fallbackValue;
      },
      findCodexSessionPath(_threadId, fallbackValue = "") {
        return fallbackValue;
      },
      httpFetch(_input, fallbackValue = undefined) {
        return fallbackValue;
      },
      bridgeDispatch(_input, fallbackValue = undefined) {
        return fallbackValue;
      },
      websocketDispatch(_input, fallbackValue = undefined) {
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
globalThis.__vhttpd_create_websocket_runtime = function(meta) {
  meta = meta && typeof meta === "object" ? meta : {};
  const freezeValue = (value) => {
    try {
      return Object.freeze(value);
    } catch (_) {
      return value;
    }
  };
  try {
    const dispatchKind = "websocket";
    const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "ws";
    const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
    const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : requestPath;
    const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
    const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
    const hostApi = globalThis.vhttpdHost && typeof globalThis.vhttpdHost === "object" ? globalThis.vhttpdHost : undefined;
    const hostConfig = hostApi && typeof hostApi.config === "function"
      ? (...args) => hostApi.config(...args)
      : undefined;
    const hostWebSocketDispatch = hostApi && typeof hostApi.websocketDispatch === "function"
      ? (...args) => hostApi.websocketDispatch(...args)
      : undefined;
    const capabilities = freezeValue({
      http: false,
      stream: false,
      websocket: true,
      websocketUpstream: false,
      websocketDispatch: typeof hostWebSocketDispatch === "function",
      fs: !!meta.enableFs,
      process: !!meta.enableProcess,
      network: !!meta.enableNetwork
    });
    const request = freezeValue({
      id: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      url: requestPath,
      target: requestTarget,
      href: requestHref,
      origin: requestOrigin,
      scheme: requestScheme,
      host: requestHost,
      port: requestPort,
      protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
      remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      server: freezeValue(meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {})
    });
    const runtime = {
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
      capabilities,
      request,
      method: typeof meta.method === "string" ? meta.method : "",
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
      config(fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const raw = hostConfig("");
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      getConfig(path, fallbackValue = undefined) {
        if (typeof hostConfig !== "function") {
          return fallbackValue;
        }
        const key = path == null ? "" : String(path);
        const raw = hostConfig(key);
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          const parsed = JSON.parse(String(raw));
          if (parsed && typeof parsed === "object") {
            return freezeValue(parsed);
          }
          return parsed;
        } catch (_) {
          return fallbackValue;
        }
      },
      websocketDispatch(input, fallbackValue = undefined) {
        if (typeof hostWebSocketDispatch !== "function") {
          return fallbackValue;
        }
        let commands = [];
        if (Array.isArray(input)) {
          commands = input;
        } else if (input && typeof input === "object") {
          if (Array.isArray(input.commands)) {
            commands = input.commands;
          } else {
            commands = [input];
          }
        }
        const raw = hostWebSocketDispatch(JSON.stringify({
          commands: commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, {}))
        }));
        if (raw === undefined || raw === null || raw === "") {
          return fallbackValue;
        }
        try {
          return JSON.parse(String(raw));
        } catch (_) {
          return fallbackValue;
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
      console.error("[vhttpd]", meta.laneId || "", meta.requestId || "", meta.traceId || "", "websocket runtime facade create failed", errorMessage, JSON.stringify(meta));
    }
    const requestPath = typeof meta.path === "string" ? meta.path : "";
    return freezeValue({
      provider: typeof meta.provider === "string" ? meta.provider : "",
      executor: typeof meta.executor === "string" ? meta.executor : "",
      dispatchKind: "websocket",
      laneId: typeof meta.laneId === "string" ? meta.laneId : "",
      requestId: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
      moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
      runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
      threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
      capabilities: freezeValue({
        http: false,
        stream: false,
        websocket: true,
        websocketUpstream: false,
        websocketDispatch: false,
        fs: false,
        process: false,
        network: false
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
        scheme: typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "ws",
        host: typeof meta.requestHost === "string" ? meta.requestHost : "",
        port: typeof meta.requestPort === "string" ? meta.requestPort : "",
        protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
        remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
        server: freezeValue(meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {})
      }),
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
      config(_fallbackValue = undefined) {
        return _fallbackValue;
      },
      getConfig(_path, fallbackValue = undefined) {
        return fallbackValue;
      },
      websocketDispatch(_input, fallbackValue = undefined) {
        return fallbackValue;
      }
    });
  }
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
globalThis.__vhttpd_create_websocket_frame = function(bundle) {
  bundle = bundle && typeof bundle === "object" ? bundle : {};
  const raw = bundle.raw && typeof bundle.raw === "object" ? bundle.raw : {};
  const meta = bundle.runtime && typeof bundle.runtime === "object" ? bundle.runtime : {};
  const hostApi = globalThis.vhttpdHost && typeof globalThis.vhttpdHost === "object" ? globalThis.vhttpdHost : undefined;
  const hostConfig = hostApi && typeof hostApi.config === "function"
    ? (...args) => hostApi.config(...args)
    : undefined;
  const hostWebSocketDispatch = hostApi && typeof hostApi.websocketDispatch === "function"
    ? (...args) => hostApi.websocketDispatch(...args)
    : undefined;
  const requestPath = typeof meta.path === "string" ? meta.path : "";
  const requestTarget = typeof meta.requestTarget === "string" && meta.requestTarget ? meta.requestTarget : requestPath;
  const requestScheme = typeof meta.requestScheme === "string" && meta.requestScheme ? meta.requestScheme : "ws";
  const requestHost = typeof meta.requestHost === "string" ? meta.requestHost : "";
  const requestPort = typeof meta.requestPort === "string" ? meta.requestPort : "";
  const requestOrigin = requestHost ? requestScheme + "://" + requestHost + (requestPort ? ":" + requestPort : "") : "";
  const requestHref = requestOrigin ? requestOrigin + requestTarget : requestTarget;
  const runtime = {
    provider: typeof meta.provider === "string" ? meta.provider : "",
    executor: typeof meta.executor === "string" ? meta.executor : "",
    dispatchKind: "websocket",
    laneId: typeof meta.laneId === "string" ? meta.laneId : "",
    requestId: typeof meta.requestId === "string" ? meta.requestId : "",
    traceId: typeof meta.traceId === "string" ? meta.traceId : "",
    appEntry: typeof meta.appEntry === "string" ? meta.appEntry : "",
    moduleRoot: typeof meta.moduleRoot === "string" ? meta.moduleRoot : "",
    runtimeProfile: typeof meta.runtimeProfile === "string" ? meta.runtimeProfile : "",
    threadCount: typeof meta.threadCount === "number" ? meta.threadCount : 0,
    capabilities: {
      http: false,
      stream: false,
      websocket: true,
      websocketUpstream: false,
      websocketDispatch: typeof hostWebSocketDispatch === "function",
      fs: !!meta.enableFs,
      process: !!meta.enableProcess,
      network: !!meta.enableNetwork
    },
    request: {
      id: typeof meta.requestId === "string" ? meta.requestId : "",
      traceId: typeof meta.traceId === "string" ? meta.traceId : "",
      method: typeof meta.method === "string" ? meta.method : "",
      path: requestPath,
      url: requestPath,
      target: requestTarget,
      href: requestHref,
      origin: requestOrigin,
      scheme: requestScheme,
      host: requestHost,
      port: requestPort,
      protocolVersion: typeof meta.requestProtocolVersion === "string" ? meta.requestProtocolVersion : "",
      remoteAddr: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      ip: typeof meta.requestRemoteAddr === "string" ? meta.requestRemoteAddr : "",
      server: meta.requestServer && typeof meta.requestServer === "object" ? meta.requestServer : {}
    },
    method: typeof meta.method === "string" ? meta.method : "",
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
    config(fallbackValue = undefined) {
      if (typeof hostConfig !== "function") {
        return fallbackValue;
      }
      const rawConfig = hostConfig("");
      if (rawConfig === undefined || rawConfig === null || rawConfig === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(rawConfig));
      } catch (_) {
        return fallbackValue;
      }
    },
    getConfig(path, fallbackValue = undefined) {
      if (typeof hostConfig !== "function") {
        return fallbackValue;
      }
      const key = path == null ? "" : String(path);
      const rawConfig = hostConfig(key);
      if (rawConfig === undefined || rawConfig === null || rawConfig === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(rawConfig));
      } catch (_) {
        return fallbackValue;
      }
    },
    websocketDispatch(input, fallbackValue = undefined) {
      if (typeof hostWebSocketDispatch !== "function") {
        return fallbackValue;
      }
      let commands = [];
      if (Array.isArray(input)) {
        commands = input;
      } else if (input && typeof input === "object") {
        if (Array.isArray(input.commands)) {
          commands = input.commands;
        } else {
          commands = [input];
        }
      }
      const rawResult = hostWebSocketDispatch(JSON.stringify({
        commands: commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, {}))
      }));
      if (rawResult === undefined || rawResult === null || rawResult === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(rawResult));
      } catch (_) {
        return fallbackValue;
      }
    }
  };
  const frame = {
    mode: typeof raw.mode === "string" && raw.mode ? raw.mode : "websocket_dispatch",
    event: typeof raw.event === "string" && raw.event ? raw.event : "message",
    id: typeof raw.id === "string" ? raw.id : runtime.requestId,
    path: typeof raw.path === "string" ? raw.path : runtime.path,
    query: raw.query && typeof raw.query === "object" ? raw.query : {},
    headers: raw.headers && typeof raw.headers === "object" ? raw.headers : {},
    remoteAddr: typeof raw.remote_addr === "string" ? raw.remote_addr : (runtime.request?.remoteAddr || ""),
    requestId: typeof raw.request_id === "string" ? raw.request_id : runtime.requestId,
    traceId: typeof raw.trace_id === "string" ? raw.trace_id : runtime.traceId,
    targetId: typeof raw.target_id === "string" ? raw.target_id : "",
    room: typeof raw.room === "string" ? raw.room : "",
    key: typeof raw.key === "string" ? raw.key : "",
    value: typeof raw.value === "string" ? raw.value : "",
    exceptId: typeof raw.except_id === "string" ? raw.except_id : "",
    rooms: Array.isArray(raw.rooms) ? raw.rooms.slice() : [],
    metadata: raw.metadata && typeof raw.metadata === "object" ? raw.metadata : {},
    roomMembers: raw.room_members && typeof raw.room_members === "object" ? raw.room_members : {},
    memberMetadata: raw.member_metadata && typeof raw.member_metadata === "object" ? raw.member_metadata : {},
    roomCounts: raw.room_counts && typeof raw.room_counts === "object" ? raw.room_counts : {},
    presenceUsers: raw.presence_users && typeof raw.presence_users === "object" ? raw.presence_users : {},
    status: typeof raw.status === "number" ? raw.status : 0,
    code: typeof raw.code === "number" ? raw.code : 0,
    reason: typeof raw.reason === "string" ? raw.reason : "",
    opcode: typeof raw.opcode === "string" ? raw.opcode : "",
    data: raw.data == null ? "" : String(raw.data),
    error: typeof raw.error === "string" ? raw.error : "",
    errorClass: typeof raw.error_class === "string" ? raw.error_class : "",
    runtime,
    dataText(fallbackValue) {
      if (this.opcode === "binary") {
        return fallbackValue;
      }
      if (this.data === "") {
        return fallbackValue;
      }
      return this.data;
    },
    dataBase64(fallbackValue) {
      if (this.opcode !== "binary") {
        return fallbackValue;
      }
      if (this.data === "") {
        return fallbackValue;
      }
      return this.data;
    },
    dataJson(fallbackValue) {
      if (this.opcode === "binary") {
        return fallbackValue;
      }
      if (this.data == null || String(this.data).trim() === "") {
        return fallbackValue;
      }
      try {
        return JSON.parse(String(this.data));
      } catch (_) {
        return fallbackValue;
      }
    }
  };
  return frame;
};
globalThis.__vhttpd_normalize_result = function(ctx, result) {
  if (result === undefined || result === null) {
    return ctx.response;
  }
  return result;
};
globalThis.__vhttpd_normalize_startup_result = function(result) {
  if (result === undefined || result === null || result === false || result === true) {
    return { commands: [] };
  }
  if (Array.isArray(result)) {
    return { commands: result };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid startup result type");
  }
  return {
    commands: Array.isArray(result.commands) ? result.commands : []
  };
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
  const websocketAliases = ["websocket", "handleWebSocket", "handle_websocket"];
  const upstreamAliases = ["websocket_upstream", "websocketUpstream", "handleWebSocketUpstream", "handle_websocket_upstream"];
  const aliases = kind === "websocket"
    ? websocketAliases
    : kind === "websocket_upstream"
      ? upstreamAliases
      : httpAliases;
  if (exportsValue && typeof exportsValue === "object") {
    if (kind === "http" || kind === "websocket") {
      if (typeof exportsValue.default === "function") {
        return exportsValue.default;
      }
      if (kind === "http" && typeof exportsValue.handle === "function") {
        return exportsValue.handle;
      }
      if (kind === "websocket" && typeof exportsValue.websocket === "function") {
        return exportsValue.websocket;
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
  if (kind === "websocket" && typeof globalThis.__vhttpd_websocket_handle === "function") {
    return globalThis.__vhttpd_websocket_handle;
  }
  if (kind === "websocket_upstream" && typeof globalThis.__vhttpd_websocket_upstream_handle === "function") {
    return globalThis.__vhttpd_websocket_upstream_handle;
  }
  return undefined;
};
globalThis.__vhttpd_resolve_handler = function(exportsValue) {
  return globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "http");
};
globalThis.__vhttpd_resolve_hook_for_kind = function(exportsValue, kind) {
  const startupAliases = ["startup", "lane_startup", "laneStartup"];
  const appStartupAliases = ["app_startup", "appStartup"];
  const aliases = kind === "app_startup" ? appStartupAliases : startupAliases;
  if (exportsValue && typeof exportsValue === "object") {
    for (const key of aliases) {
      if (typeof exportsValue[key] === "function") {
        return exportsValue[key];
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
  if (kind === "startup" && typeof globalThis.__vhttpd_startup_handle === "function") {
    return globalThis.__vhttpd_startup_handle;
  }
  if (kind === "app_startup" && typeof globalThis.__vhttpd_app_startup_handle === "function") {
    return globalThis.__vhttpd_app_startup_handle;
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
globalThis.__vhttpd_wrap_handler = function(kind, handler) {
  if (typeof handler !== "function") {
    return handler;
  }
  if (kind !== "websocket" && kind !== "websocket_upstream") {
    return handler;
  }
  return function(...args) {
    try {
      return handler(...args);
    } catch (error) {
      const rendered = error && typeof error === "object" && typeof error.stack === "string" && error.stack
        ? error.stack
        : error && typeof error === "object" && typeof error.message === "string" && error.message
          ? error.message
          : String(error);
      if (typeof console !== "undefined" && console && typeof console.error === "function") {
        console.error("[vhttpd] " + kind + " handler error", rendered);
      }
      throw error;
    }
  };
};
globalThis.__vhttpd_invoke_wrapped_handler = function(kind, handler, arg) {
  if (typeof handler !== "function") {
    throw new TypeError("handler is not a function");
  }
  try {
    const result = handler(arg);
    if (result && typeof result.then === "function") {
      return Promise.resolve(result).catch((error) => {
        const rendered = error && typeof error === "object" && typeof error.stack === "string" && error.stack
          ? error.stack
          : error && typeof error === "object" && typeof error.message === "string" && error.message
            ? error.message
            : String(error);
        if (typeof console !== "undefined" && console && typeof console.error === "function") {
          console.error("[vhttpd] " + kind + " handler error", rendered);
        }
        throw error;
      });
    }
    return result;
  } catch (error) {
    const rendered = error && typeof error === "object" && typeof error.stack === "string" && error.stack
      ? error.stack
      : error && typeof error === "object" && typeof error.message === "string" && error.message
        ? error.message
        : String(error);
    if (typeof console !== "undefined" && console && typeof console.error === "function") {
      console.error("[vhttpd] " + kind + " handler error", rendered);
    }
    throw error;
  }
};
globalThis.__vhttpd_invoke_websocket_handle = function(frame) {
  const handler = globalThis.__vhttpd_websocket_handle;
  return globalThis.__vhttpd_invoke_wrapped_handler("websocket", handler, frame);
};
globalThis.__vhttpd_bind_handlers = function(exportsValue) {
  const httpHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "http");
  const websocketHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "websocket");
  const websocketUpstreamHandler = globalThis.__vhttpd_resolve_handler_for_kind(exportsValue, "websocket_upstream");
  const startupHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "startup");
  const appStartupHandler = globalThis.__vhttpd_resolve_hook_for_kind(exportsValue, "app_startup");
  if (typeof httpHandler === "function") {
    globalThis.__vhttpd_handle = httpHandler;
  }
  if (typeof websocketHandler === "function") {
    globalThis.__vhttpd_websocket_handle = globalThis.__vhttpd_wrap_handler("websocket", websocketHandler);
  }
  if (typeof websocketUpstreamHandler === "function") {
    globalThis.__vhttpd_websocket_upstream_handle = globalThis.__vhttpd_wrap_handler("websocket_upstream", websocketUpstreamHandler);
  }
  if (typeof startupHandler === "function") {
    globalThis.__vhttpd_startup_handle = startupHandler;
  }
  if (typeof appStartupHandler === "function") {
    globalThis.__vhttpd_app_startup_handle = appStartupHandler;
  }
  return {
    http: httpHandler,
    websocket: websocketHandler,
    websocket_upstream: websocketUpstreamHandler,
    startup: startupHandler,
    app_startup: appStartupHandler
  };
};
globalThis.__vhttpd_register_exports = function(exportsValue) {
  if (!exportsValue || typeof exportsValue !== "object") {
    return globalThis.__vhttpd_bind_handlers(undefined);
  }
  return globalThis.__vhttpd_bind_handlers(exportsValue);
};
globalThis.__vhttpd_normalize_websocket_command = function(command, frame) {
  const raw = command && typeof command === "object" ? command : {};
  const source = frame && typeof frame === "object" ? frame : {};
  return {
    mode: typeof raw.mode === "string" && raw.mode ? raw.mode : "websocket_dispatch",
    event: typeof raw.event === "string" ? raw.event : "",
    id: typeof raw.id === "string" && raw.id ? raw.id : (typeof source.id === "string" ? source.id : ""),
    path: typeof raw.path === "string" ? raw.path : (typeof source.path === "string" ? source.path : ""),
    query: raw.query && typeof raw.query === "object" && !Array.isArray(raw.query) ? raw.query : {},
    headers: raw.headers && typeof raw.headers === "object" && !Array.isArray(raw.headers) ? raw.headers : {},
    remote_addr: typeof raw.remote_addr === "string" ? raw.remote_addr : "",
    request_id: typeof raw.request_id === "string" ? raw.request_id : (typeof source.requestId === "string" ? source.requestId : ""),
    trace_id: typeof raw.trace_id === "string" ? raw.trace_id : (typeof source.traceId === "string" ? source.traceId : ""),
    target_id: typeof raw.target_id === "string"
      ? raw.target_id
      : typeof raw.targetId === "string"
        ? raw.targetId
        : "",
    room: typeof raw.room === "string" ? raw.room : "",
    key: typeof raw.key === "string" ? raw.key : "",
    value: typeof raw.value === "string" ? raw.value : "",
    except_id: typeof raw.except_id === "string"
      ? raw.except_id
      : typeof raw.exceptId === "string"
        ? raw.exceptId
        : "",
    rooms: Array.isArray(raw.rooms) ? raw.rooms : [],
    metadata: raw.metadata && typeof raw.metadata === "object" && !Array.isArray(raw.metadata) ? raw.metadata : {},
    room_members: raw.room_members && typeof raw.room_members === "object" && !Array.isArray(raw.room_members) ? raw.room_members : {},
    member_metadata: raw.member_metadata && typeof raw.member_metadata === "object" && !Array.isArray(raw.member_metadata) ? raw.member_metadata : {},
    room_counts: raw.room_counts && typeof raw.room_counts === "object" && !Array.isArray(raw.room_counts) ? raw.room_counts : {},
    presence_users: raw.presence_users && typeof raw.presence_users === "object" && !Array.isArray(raw.presence_users) ? raw.presence_users : {},
    status: typeof raw.status === "number" ? raw.status : 0,
    code: typeof raw.code === "number" ? raw.code : 0,
    reason: typeof raw.reason === "string" ? raw.reason : "",
    opcode: typeof raw.opcode === "string" ? raw.opcode : "text",
    data: raw.data == null ? "" : String(raw.data),
    error: typeof raw.error === "string" ? raw.error : "",
    error_class: typeof raw.error_class === "string"
      ? raw.error_class
      : typeof raw.errorClass === "string"
        ? raw.errorClass
        : ""
  };
};
globalThis.__vhttpd_normalize_websocket_result = function(frame, result) {
  if (result === undefined || result === null || result === false) {
    return {
      accepted: false,
      closed: false,
      commands: [],
      error: "",
      error_class: ""
    };
  }
  if (result === true) {
    return {
      accepted: true,
      closed: false,
      commands: [],
      error: "",
      error_class: ""
    };
  }
  if (Array.isArray(result)) {
    return {
      accepted: true,
      closed: false,
      commands: result.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, frame)),
      error: "",
      error_class: ""
    };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid websocket result type");
  }
  const commands = Array.isArray(result.commands)
    ? result.commands.map((item) => globalThis.__vhttpd_normalize_websocket_command(item, frame))
    : [];
  return {
    accepted: Object.prototype.hasOwnProperty.call(result, "accepted") ? !!result.accepted : true,
    closed: !!result.closed,
    commands,
    error: typeof result.error === "string" ? result.error : "",
    error_class: typeof result.error_class === "string"
      ? result.error_class
      : typeof result.errorClass === "string"
        ? result.errorClass
        : ""
  };
};
globalThis.__vhttpd_normalize_websocket_upstream_result = function(frame, result) {
  if (result === undefined || result === null || result === false) {
    return {
      handled: false,
      commands: [],
      response: { status: 200, headers: {}, body: "" }
    };
  }
  if (result === true) {
    return {
      handled: true,
      commands: [],
      response: { status: 200, headers: {}, body: "" }
    };
  }
  if (Array.isArray(result)) {
    return {
      handled: true,
      commands: result,
      response: { status: 200, headers: {}, body: "" }
    };
  }
  if (typeof result !== "object") {
    throw new TypeError("Invalid websocket_upstream result type");
  }
  const response = result.response && typeof result.response === "object" ? result.response : {};
  return {
    handled: Object.prototype.hasOwnProperty.call(result, "handled") ? !!result.handled : true,
    commands: Array.isArray(result.commands) ? result.commands : [],
    response: {
      status: typeof response.status === "number" ? response.status : 200,
      headers: response.headers && typeof response.headers === "object" && !Array.isArray(response.headers) ? response.headers : {},
      body: response.body == null ? "" : String(response.body)
    }
  };
};
')!
	ctx.end()
}

fn inproc_vjsx_host_emit_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
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
	}
}

fn inproc_vjsx_host_snapshot_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
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
	}
}

fn inproc_vjsx_config_lookup(raw_json string, path string) string {
	if raw_json.trim_space() == '' {
		return ''
	}
	if path.trim_space() == '' {
		return raw_json
	}
	parsed := json2.decode[json2.Any](raw_json) or { return '' }
	mut current := parsed
	for raw_part in path.split('.') {
		part := raw_part.trim_space()
		if part == '' {
			continue
		}
		root := current.as_map()
		if part !in root {
			return ''
		}
		current = root[part] or { return '' }
	}
	return current.json_str()
}

fn inproc_vjsx_host_config_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			mut app_ref := &App(unsafe { nil })
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string('')
			}
			mut app := app_ref
			path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			return ctx.js_string(inproc_vjsx_config_lookup(app.runtime_config_json, path))
		})
	}
}

fn inproc_vjsx_host_read_text_file_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
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
	}
}

fn inproc_vjsx_host_find_codex_session_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
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
	}
}

fn inproc_vjsx_host_http_fetch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			mut enable_network := false
			state.mu.@lock()
			enable_network = state.facade.config.enable_network
			state.mu.unlock()
			if !enable_network {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'network_disabled'
				}))
			}
			parsed := json.decode(InProcVjsxHostHttpFetchRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'invalid_fetch_request'
				}))
			}
			url := parsed.url.trim_space()
			if url == '' {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'missing_url'
				}))
			}
			method_raw := parsed.method.trim_space()
			method := match method_raw.to_upper() {
				'POST' { http.Method.post }
				'PUT' { http.Method.put }
				'PATCH' { http.Method.patch }
				'DELETE' { http.Method.delete }
				'HEAD' { http.Method.head }
				'OPTIONS' { http.Method.options }
				else { http.Method.get }
			}
			body := parsed.body
			mut header := http.new_header()
			for name, value in parsed.headers {
				header.add_custom(name, value) or {}
			}
			resp := http.fetch(http.FetchConfig{
				url:    url
				method: method
				data:   body
				header: header
			}) or {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: err.msg()
				}))
			}
			mut response_headers := map[string]string{}
			for key in resp.header.keys() {
				response_headers[key] = resp.header.get_custom(key) or { '' }
			}
			return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
				ok:      true
				status:  resp.status_code
				body:    resp.body
				headers: response_headers
			}))
		})
	}
}

fn inproc_vjsx_host_bridge_dispatch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			req := json.decode(InProcVjsxHostBridgeDispatchRequest, raw) or {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: 'invalid_bridge_dispatch_request'
				}))
			}
			mut app_ref := &App(unsafe { nil })
			mut request_trace_id := ''
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
				request_trace_id = state.hosts[idx].request_ctx.trace_id
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: 'bridge_dispatch_app_missing'
				}))
			}
			mut app := app_ref
			summary := feishu_runtime_event_summary(req.payload)
			trace_id := if req.trace_id.trim_space() != '' { req.trace_id } else { request_trace_id }
			result := app.feishu_card_bridge_dispatch_callback(req.app, trace_id, FeishuRuntimeEventSummary{
				event_id:        summary.event_id
				event_kind:      if summary.event_kind != '' { summary.event_kind } else { 'action' }
				event_type:      if req.event_type.trim_space() != '' { req.event_type } else { summary.event_type }
				message_id:      if req.message_id.trim_space() != '' { req.message_id } else { summary.message_id }
				target:          if req.target.trim_space() != '' { req.target } else { summary.target }
				target_type:     if req.target_type.trim_space() != '' { req.target_type } else { summary.target_type }
				open_message_id: summary.open_message_id
				action_tag:      summary.action_tag
			}, req.payload) or {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: err.msg()
				}))
			}
			return ctx.js_string(json.encode(result))
		})
	}
}

fn inproc_vjsx_host_websocket_dispatch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			req := json.decode(InProcVjsxHostWebSocketDispatchRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					error: 'invalid_websocket_dispatch_request'
				}))
			}
			mut app_ref := &App(unsafe { nil })
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len {
				if state.hosts[idx].request_ctx.active {
					app_ref = state.hosts[idx].request_ctx.app
				} else {
					app_ref = state.hosts[idx].app_ref
				}
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					error: 'websocket_dispatch_app_missing'
				}))
			}
			mut app := app_ref
			result := app.execute_websocket_dispatch_commands_result(req.commands)
			if result.has_close {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					ok:              true
					has_close:       true
					close_code:      result.close_frame.code
					close_reason:    result.close_frame.reason
					close_target_id: if result.close_frame.target_id != '' { result.close_frame.target_id } else { result.close_frame.id }
					failures:        result.failures
				}))
			}
			return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
				ok: true
				failures: result.failures
			}))
		})
	}
}

fn inproc_vjsx_host_api_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return vjsx.host_object(vjsx.HostObjectField{
		name:  'emit'
		value: inproc_vjsx_host_emit_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'snapshot'
		value: inproc_vjsx_host_snapshot_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'config'
		value: inproc_vjsx_host_config_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'readTextFile'
		value: inproc_vjsx_host_read_text_file_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'findCodexSessionPath'
		value: inproc_vjsx_host_find_codex_session_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'httpFetch'
		value: inproc_vjsx_host_http_fetch_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'bridgeDispatch'
		value: inproc_vjsx_host_bridge_dispatch_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'websocketDispatch'
		value: inproc_vjsx_host_websocket_dispatch_builder(mut state, idx)
	})
}

fn install_inproc_host_api(mut ctx vjsx.Context, mut state VjsxExecutorState, idx int) {
	ctx.install_host_api(vjsx.HostApiConfig{
		globals: [
			vjsx.HostGlobalBinding{
				name:  'vhttpdHost'
				value: inproc_vjsx_host_api_builder(mut state, idx)
			},
		]
	})
}

fn inproc_vjsx_destroy_lane_host(mut host VjsxLaneHost) {
	if host.is_module_entry && !isnil(host.module_binding) && !host.module_binding.is_closed() {
		host.module_binding.close()
		host.module_binding = unsafe { nil }
	}
	if host.initialized && !isnil(host.session) && !host.session.is_closed() {
		host.session.close()
		host.session = unsafe { nil }
	}
	if host.temp_root.trim_space() != '' {
		os.rmdir_all(host.temp_root) or {}
	}
	host.initialized = false
	host.startup_completed = false
	host.dirty = false
	host.source_signature = ''
	host.is_module_entry = false
	host.temp_root = ''
	host.app_ref = unsafe { nil }
	host.request_ctx = InProcVjsxRequestContext{}
}

fn inproc_vjsx_module_aliases(kind string) []string {
	return match kind {
		'http' {
			['handle', 'http', 'handleHttp', 'handle_http']
		}
		'websocket' {
			['websocket', 'handleWebSocket', 'handle_websocket']
		}
		'websocket_upstream' {
			['websocket_upstream', 'websocketUpstream', 'handleWebSocketUpstream',
				'handle_websocket_upstream']
		}
		'startup' {
			['startup', 'lane_startup', 'laneStartup']
		}
		'app_startup' {
			['app_startup', 'appStartup']
		}
		else {
			[]string{}
		}
	}
}

fn inproc_vjsx_module_has_default_function(kind string) bool {
	return kind in ['http', 'websocket']
}

fn inproc_vjsx_global_handler_name(kind string) string {
	return match kind {
		'http' { '__vhttpd_handle' }
		'websocket' { '__vhttpd_websocket_handle' }
		'websocket_upstream' { '__vhttpd_websocket_upstream_handle' }
		'startup' { '__vhttpd_startup_handle' }
		'app_startup' { '__vhttpd_app_startup_handle' }
		else { '' }
	}
}

fn inproc_vjsx_global_has_callable(ctx vjsx.Context, kind string) bool {
	global_name := inproc_vjsx_global_handler_name(kind)
	if global_name == '' {
		return false
	}
	handler := ctx.js_global(global_name)
	defer {
		handler.free()
	}
	return !handler.is_undefined() && handler.is_function()
}

fn inproc_vjsx_call_global_entry(ctx vjsx.Context, kind string, arg vjsx.Value) !vjsx.Value {
	global_name := inproc_vjsx_global_handler_name(kind)
	if global_name == '' {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	handler := ctx.js_global(global_name)
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	return ctx.call(handler, arg)
}

fn inproc_vjsx_module_has_callable(module_binding &vjsx.ScriptModule, kind string) bool {
	aliases := inproc_vjsx_module_aliases(kind)
	if module_binding.has_export('default') {
		default_export := module_binding.default_export() or { return false }
		defer {
			default_export.free()
		}
		if inproc_vjsx_module_has_default_function(kind) && default_export.is_function() {
			return true
		}
		if default_export.is_object() {
			for alias in aliases {
				if !default_export.has(alias) {
					continue
				}
				method := default_export.get(alias)
				is_callable := method.is_function()
				method.free()
				if is_callable {
					return true
				}
			}
		}
	}
	for alias in aliases {
		if !module_binding.has_export(alias) {
			continue
		}
		export_value := module_binding.get_export(alias) or { continue }
		is_callable := export_value.is_function()
		export_value.free()
		if is_callable {
			return true
		}
	}
	return false
}

fn inproc_vjsx_call_module_entry(module_binding &vjsx.ScriptModule, kind string, arg vjsx.Value) !vjsx.Value {
	aliases := inproc_vjsx_module_aliases(kind)
	if module_binding.has_export('default') {
		default_export := module_binding.default_export() or {
			return error('inproc_vjsx_executor_missing_${kind}_handler')
		}
		if inproc_vjsx_module_has_default_function(kind) && default_export.is_function() {
			default_export.free()
			return module_binding.call_export('default', arg)
		}
		if default_export.is_object() {
			for alias in aliases {
				if !default_export.has(alias) {
					continue
				}
				method := default_export.get(alias)
				is_callable := method.is_function()
				method.free()
				if is_callable {
					default_export.free()
					return module_binding.call_default_method(alias, arg)
				}
			}
		}
		default_export.free()
	}
	for alias in aliases {
		if !module_binding.has_export(alias) {
			continue
		}
		export_value := module_binding.get_export(alias) or { continue }
		is_callable := export_value.is_function()
		export_value.free()
		if is_callable {
			return module_binding.call_export(alias, arg)
		}
	}
	return error('inproc_vjsx_executor_missing_${kind}_handler')
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
	state.hosts[idx] = vjsx_empty_lane_host()
	state.mu.unlock()
	inproc_vjsx_destroy_lane_host(mut stale)
}

pub fn (e InProcVjsxExecutor) close() {
	if isnil(e.state) {
		return
	}
	mut stale_hosts := []VjsxLaneHost{}
	mut reset_hosts := []VjsxLaneHost{}
	mut state := e.state
	state.mu.@lock()
	stale_hosts = state.hosts.clone()
	for _ in 0 .. stale_hosts.len {
		reset_hosts << vjsx_empty_lane_host()
	}
	state.hosts = reset_hosts
	for i in 0 .. state.lanes.len {
		state.lanes[i].healthy = true
		state.lanes[i].dirty = false
		state.lanes[i].inflight = 0
		state.lanes[i].last_error = ''
	}
	state.rr_index = 0
	state.warmup_source_signature = ''
	state.warmup_running = false
	state.warmup_completed = false
	state.warmup_last_error = ''
	state.app_startup_source_signature = ''
	state.app_startup_running = false
	state.app_startup_completed = false
	state.app_startup_last_error = ''
	state.facade.bootstrapped = false
	state.facade.last_error = ''
	state.signature_refresh_stop = true
	state.signature_refresh_started = false
	state.cached_source_probe = ''
	state.cached_source_signature = ''
	state.signature_last_checked_at = 0
	state.signature_last_probe_at = 0
	state.signature_pending_since = 0
	state.signature_last_error = ''
	state.mu.unlock()
	for mut host in stale_hosts {
		inproc_vjsx_destroy_lane_host(mut host)
	}
}

fn inproc_vjsx_new_runtime_session_ptr(config VjsxRuntimeFacadeConfig) !&vjsx.RuntimeSession {
	asset_root := vjsx_runtime_asset_root()
	session_value := match config.runtime_profile {
		'', 'script' {
			runtimejs.new_script_runtime_session(vjsx.ContextConfig{}, vjsx.ScriptRuntimeConfig{
				fs_roots:     vjsx_fs_roots(config)
				process_args: [config.app_entry]
				asset_root:   asset_root
			})
		}
		'node' {
			runtimejs.new_node_runtime_session(vjsx.ContextConfig{}, vjsx.NodeRuntimeConfig{
				fs_roots:     vjsx_fs_roots(config)
				process_args: [config.app_entry]
				asset_root:   asset_root
			})
		}
		else {
			return error('inproc_vjsx_executor_unsupported_runtime_profile:${config.runtime_profile}')
		}
	}
	// Keep the RuntimeSession on the heap; lane hosts outlive ensure_lane_host().
	mut session := session_value
	return &session
}

fn (e InProcVjsxExecutor) ensure_lane_host(idx int) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := e.facade_snapshot().config
	source_signature := e.current_source_signature()
	mut needs_reset := false
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len || idx >= state.lanes.len {
		state.mu.unlock()
		return error('inproc_vjsx_executor_invalid_lane')
	}
	host := state.hosts[idx]
	if host.initialized && !host.dirty && !isnil(host.session) && !host.session.is_closed()
		&& host.source_signature == source_signature {
		state.mu.unlock()
		return
	}
	needs_reset = host.initialized
	state.mu.unlock()
	if needs_reset {
		e.reset_lane_host(idx)
	}

	as_module := vjsx_entry_runs_as_module(config.app_entry)!
	temp_root := vjsx_lane_temp_root_for_signature(config, idx, source_signature)
	mut session := inproc_vjsx_new_runtime_session_ptr(config)!
	mut ctx := session.context()
	install_inproc_http_facade(mut ctx)!
	install_inproc_host_api(mut ctx, mut state, idx)
	mut module_binding_ptr := &vjsx.ScriptModule(unsafe { nil })
	mut has_http_handler := false
	mut has_websocket_handler := false
	mut has_upstream_handler := false
	if as_module {
		if vjsx.is_typescript_file(config.app_entry)
			|| vjsx.is_runtime_module_file(config.app_entry) {
			runtimejs.install_typescript_runtime(ctx)!
		}
		module_entry_path := runtimejs.build_runtime_module_entry(ctx, config.app_entry,
			true, temp_root) or {
			session.close()
			os.rmdir_all(temp_root) or {}
			return error('inproc_vjsx_executor_bootstrap_failed:${err.msg()}')
		}
		module_binding_value := session.import_module(module_entry_path) or {
			session.close()
			os.rmdir_all(temp_root) or {}
			return error('inproc_vjsx_executor_module_import_failed:${err.msg()}')
		}
		has_http_handler = inproc_vjsx_module_has_callable(&module_binding_value, 'http')
			|| inproc_vjsx_global_has_callable(ctx, 'http')
		has_websocket_handler = inproc_vjsx_module_has_callable(&module_binding_value, 'websocket')
			|| inproc_vjsx_global_has_callable(ctx, 'websocket')
		has_upstream_handler =
			inproc_vjsx_module_has_callable(&module_binding_value, 'websocket_upstream')
			|| inproc_vjsx_global_has_callable(ctx, 'websocket_upstream')
		if !has_http_handler && !has_websocket_handler && !has_upstream_handler {
			mut cleanup_binding := module_binding_value
			cleanup_binding.close()
			session.close()
			os.rmdir_all(temp_root) or {}
			return error('inproc_vjsx_executor_missing_handler')
		}
		bind_handlers := ctx.js_global('__vhttpd_bind_handlers')
		defer {
			bind_handlers.free()
		}
		if !bind_handlers.is_undefined() && bind_handlers.is_function() {
			entry_exports := module_binding_value.namespace() or {
				mut cleanup_binding := module_binding_value
				cleanup_binding.close()
				session.close()
				os.rmdir_all(temp_root) or {}
				return error('inproc_vjsx_executor_module_namespace_failed:${err.msg()}')
			}
			defer {
				entry_exports.free()
			}
			mut bound := ctx.call(bind_handlers, entry_exports) or {
				mut cleanup_binding := module_binding_value
				cleanup_binding.close()
				session.close()
				os.rmdir_all(temp_root) or {}
				return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
			}
			defer {
				bound.free()
			}
		}
		mut module_binding := module_binding_value
		module_binding_ptr = &module_binding
	} else {
		mut entry_exports := load_inproc_vjsx_entry(mut ctx, config, idx, source_signature,
			false) or {
			session.close()
			os.rmdir_all(temp_root) or {}
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
				session.close()
				os.rmdir_all(temp_root) or {}
				return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
			}
			defer {
				bound.free()
			}
		}
		http_handler := ctx.js_global('__vhttpd_handle')
		websocket_handler := ctx.js_global('__vhttpd_websocket_handle')
		upstream_handler := ctx.js_global('__vhttpd_websocket_upstream_handle')
		has_http_handler = !http_handler.is_undefined() && http_handler.is_function()
		has_websocket_handler = !websocket_handler.is_undefined() && websocket_handler.is_function()
		has_upstream_handler = !upstream_handler.is_undefined() && upstream_handler.is_function()
		http_handler.free()
		websocket_handler.free()
		upstream_handler.free()
		if !has_http_handler && !has_websocket_handler && !has_upstream_handler {
			session.close()
			os.rmdir_all(temp_root) or {}
			return error('inproc_vjsx_executor_missing_handler')
		}
	}

	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	state.hosts[idx] = VjsxLaneHost{
		initialized:       true
		startup_completed: false
		dirty:             false
		source_signature:  source_signature
		is_module_entry:   as_module
		temp_root:         temp_root
		session:           session
		module_binding:    module_binding_ptr
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
	state.hosts[idx].app_ref = app
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
		build_root:               config.build_root
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
		build_root:               config.build_root
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

fn websocket_request_target_from_frame(frame WorkerWebSocketFrame) string {
	if frame.query.len == 0 {
		return frame.path
	}
	mut keys := frame.query.keys()
	keys.sort()
	mut parts := []string{cap: keys.len}
	for key in keys {
		parts << '${urllib.query_escape(key)}=${urllib.query_escape(frame.query[key] or { '' })}'
	}
	query := parts.join('&')
	if query == '' {
		return frame.path
	}
	return '${frame.path}?${query}'
}

fn websocket_request_server_map(frame WorkerWebSocketFrame) map[string]string {
	mut server := map[string]string{}
	host_header := frame.headers['host'] or { '' }
	host_name, port := urllib.split_host_port(host_header)
	server['host'] = host_name
	server['port'] = port
	server['remote_addr'] = frame.remote_addr
	server['url'] = websocket_request_target_from_frame(frame)
	return server
}

fn websocket_request_scheme_from_frame(frame WorkerWebSocketFrame) string {
	for key in ['x-forwarded-proto', 'x-scheme'] {
		if raw := frame.headers[key] {
			normalized := raw.trim_space().to_lower()
			if normalized != '' {
				return normalized
			}
		}
	}
	return 'ws'
}

fn (e InProcVjsxExecutor) websocket_runtime_meta(lane VjsxExecutionLane, frame WorkerWebSocketFrame) InProcVjsxRuntimeMeta {
	config := e.facade_snapshot().config
	server := websocket_request_server_map(frame)
	host := server['host'] or { '' }
	port := server['port'] or { '' }
	target := server['url'] or { frame.path }
	return InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'websocket'
		lane_id:                  lane.id
		request_id:               frame.request_id
		trace_id:                 frame.trace_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		build_root:               config.build_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           websocket_request_scheme_from_frame(frame)
		request_host:             host
		request_port:             port
		request_target:           target
		request_protocol_version: ''
		request_remote_addr:      frame.remote_addr
		request_server:           server
		method:                   frame.event.to_upper()
		path:                     frame.path
	}
}

fn (e InProcVjsxExecutor) build_websocket_runtime_payload(lane VjsxExecutionLane, frame WorkerWebSocketFrame) string {
	return json.encode(e.websocket_runtime_meta(lane, frame))
}

fn (e InProcVjsxExecutor) build_websocket_frame_bundle_payload(lane VjsxExecutionLane, frame WorkerWebSocketFrame) string {
	return json.encode(InProcVjsxWebSocketFrameBundle{
		raw: frame
		runtime: e.websocket_runtime_meta(lane, frame)
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

fn websocket_js_value_from_json(ctx &vjsx.Context, raw string) vjsx.Value {
	if raw.trim_space() == '' {
		return ctx.js_object()
	}
	return ctx.json_parse(raw)
}

fn websocket_log_args(args []vjsx.Value) string {
	mut parts := []string{cap: args.len}
	for arg in args {
		parts << arg.to_string()
	}
	return parts.join(' ')
}

fn build_websocket_js_runtime(ctx &vjsx.Context, runtime_meta InProcVjsxRuntimeMeta, runtime_config_json string, mut app App) vjsx.Value {
	mut runtime := ctx.js_object()
	mut capabilities := ctx.js_object()
	capabilities.set('http', false)
	capabilities.set('fetch', false)
	capabilities.set('bridgeDispatch', false)
	capabilities.set('websocketUpstream', false)
	capabilities.set('websocketDispatch', true)
	capabilities.set('fs', false)
	capabilities.set('process', false)
	capabilities.set('network', false)
	runtime.set('provider', runtime_meta.provider)
	runtime.set('executor', runtime_meta.executor)
	runtime.set('dispatchKind', 'websocket')
	runtime.set('laneId', runtime_meta.lane_id)
	runtime.set('requestId', runtime_meta.request_id)
	runtime.set('traceId', runtime_meta.trace_id)
	runtime.set('appEntry', runtime_meta.app_entry)
	runtime.set('moduleRoot', runtime_meta.module_root)
	runtime.set('runtimeProfile', runtime_meta.runtime_profile)
	runtime.set('threadCount', runtime_meta.thread_count)
	runtime.set('capabilities', capabilities)
	mut request := ctx.js_object()
	request.set('id', runtime_meta.request_id)
	request.set('traceId', runtime_meta.trace_id)
	request.set('method', runtime_meta.method)
	request.set('path', runtime_meta.path)
	request.set('url', runtime_meta.path)
	request.set('target', runtime_meta.request_target)
	request.set('href', runtime_meta.request_target)
	request.set('origin', '')
	request.set('scheme', runtime_meta.request_scheme)
	request.set('host', runtime_meta.request_host)
	request.set('port', runtime_meta.request_port)
	request.set('protocolVersion', runtime_meta.request_protocol_version)
	request.set('remoteAddr', runtime_meta.request_remote_addr)
	request.set('ip', runtime_meta.request_remote_addr)
	request.set('server', websocket_js_value_from_json(ctx, json.encode(runtime_meta.request_server)))
	runtime.set('request', request)
	runtime.set('method', runtime_meta.method)
	runtime.set('path', runtime_meta.path)
	runtime.set('runtimeInitError', '')
	runtime.set('now', ctx.js_function(fn [ctx] (args []vjsx.Value) vjsx.Value {
		_ = args
		return ctx.js_i64(time.now().unix_milli())
	}))
	runtime.set('log', ctx.js_function(fn [ctx, runtime_meta] (args []vjsx.Value) vjsx.Value {
		println('[vhttpd] ${runtime_meta.lane_id} ${runtime_meta.request_id} ${runtime_meta.trace_id} ${websocket_log_args(args)}')
		return ctx.js_undefined()
	}))
	runtime.set('warn', ctx.js_function(fn [ctx, runtime_meta] (args []vjsx.Value) vjsx.Value {
		eprintln('[vhttpd] ${runtime_meta.lane_id} ${runtime_meta.request_id} ${runtime_meta.trace_id} ${websocket_log_args(args)}')
		return ctx.js_undefined()
	}))
	runtime.set('error', ctx.js_function(fn [ctx, runtime_meta] (args []vjsx.Value) vjsx.Value {
		eprintln('[vhttpd] ${runtime_meta.lane_id} ${runtime_meta.request_id} ${runtime_meta.trace_id} ${websocket_log_args(args)}')
		return ctx.js_undefined()
	}))
	runtime.set('config', ctx.js_function(fn [ctx, runtime_config_json] (args []vjsx.Value) vjsx.Value {
		path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		raw := inproc_vjsx_config_lookup(runtime_config_json, path)
		if raw.trim_space() == '' {
			return fallback
		}
		return ctx.js_string(raw)
	}))
	runtime.set('getConfig', ctx.js_function(fn [ctx, runtime_config_json] (args []vjsx.Value) vjsx.Value {
		path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		raw := inproc_vjsx_config_lookup(runtime_config_json, path)
		if raw.trim_space() == '' {
			return fallback
		}
		return ctx.json_parse(raw)
	}))
	runtime.set('websocketDispatch', ctx.js_function(fn [ctx, mut app] (args []vjsx.Value) vjsx.Value {
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		if args.len == 0 {
			return fallback
		}
		raw := args[0].json_stringify().trim_space()
		if raw == '' || raw == 'undefined' || raw == 'null' {
			return fallback
		}
		req_raw := if raw.starts_with('[') {
			'{"commands":${raw}}'
		} else {
			decoded := json.decode(InProcVjsxHostWebSocketDispatchRequest, raw) or {
				InProcVjsxHostWebSocketDispatchRequest{}
			}
			if decoded.commands.len > 0 {
				raw
			} else {
				'{"commands":[${raw}]}'
			}
		}
		req := json.decode(InProcVjsxHostWebSocketDispatchRequest, req_raw) or {
			return fallback
		}
		result := app.execute_websocket_dispatch_commands_result(req.commands)
		response := if result.has_close {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:              true
				has_close:       true
				close_code:      result.close_frame.code
				close_reason:    result.close_frame.reason
				close_target_id: if result.close_frame.target_id != '' { result.close_frame.target_id } else { result.close_frame.id }
				failures:        result.failures
			}
		} else {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:       true
				failures: result.failures
			}
		}
		return ctx.json_parse(json.encode(response))
	}))
	return runtime
}

fn build_websocket_js_frame(ctx &vjsx.Context, frame WorkerWebSocketFrame, runtime vjsx.Value) vjsx.Value {
	mut js_frame := ctx.js_object()
	js_frame.set('mode', if frame.mode != '' { frame.mode } else { 'websocket_dispatch' })
	js_frame.set('event', if frame.event != '' { frame.event } else { 'message' })
	js_frame.set('id', frame.id)
	js_frame.set('path', frame.path)
	js_frame.set('query', websocket_js_value_from_json(ctx, json.encode(frame.query)))
	js_frame.set('headers', websocket_js_value_from_json(ctx, json.encode(frame.headers)))
	js_frame.set('remoteAddr', frame.remote_addr)
	js_frame.set('requestId', frame.request_id)
	js_frame.set('traceId', frame.trace_id)
	js_frame.set('targetId', frame.target_id)
	js_frame.set('metadata', websocket_js_value_from_json(ctx, json.encode(frame.metadata)))
	js_frame.set('status', frame.status)
	js_frame.set('code', frame.code)
	js_frame.set('reason', frame.reason)
	js_frame.set('opcode', frame.opcode)
	js_frame.set('data', frame.data)
	js_frame.set('error', frame.error)
	js_frame.set('errorClass', frame.error_class)
	js_frame.set('runtime', runtime)
	return js_frame
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
	response WorkerResponse
}

struct InProcVjsxWebSocketResult {
	accepted    bool
	closed      bool
	commands    []WorkerWebSocketFrame
	error       string
	error_class string @[json: 'error_class']
}

struct InProcVjsxStartupResult {
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
			status:   200
			headers:  map[string]string{}
			body:     ''
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
		status:   if normalized.response.status > 0 { normalized.response.status } else { 200 }
		headers:  normalized.response.headers.clone()
		body:     normalized.response.body
	}
}

fn websocket_response_from_js_value(val vjsx.Value, frame WorkerWebSocketFrame) WorkerWebSocketDispatchResponse {
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return WorkerWebSocketDispatchResponse{
			mode:     'websocket_dispatch'
			event:    'result'
			id:       frame.id
			accepted: false
			closed:   false
			commands: []WorkerWebSocketFrame{}
		}
	}
	normalized := json.decode(InProcVjsxWebSocketResult, raw) or { InProcVjsxWebSocketResult{} }
	return WorkerWebSocketDispatchResponse{
		mode:        'websocket_dispatch'
		event:       'result'
		id:          frame.id
		accepted:    normalized.accepted
		closed:      normalized.closed
		commands:    normalized.commands
		error:       normalized.error
		error_class: normalized.error_class
	}
}

fn startup_result_commands_from_js_value(val vjsx.Value) []WorkerWebSocketUpstreamCommand {
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return []WorkerWebSocketUpstreamCommand{}
	}
	normalized := json.decode(InProcVjsxStartupResult, raw) or { InProcVjsxStartupResult{} }
	return normalized.commands
}

fn inproc_vjsx_startup_request_id(kind string, lane_id string) string {
	return 'vjsx.${kind}.${lane_id}'
}

fn inproc_vjsx_startup_path(kind string) string {
	return '/__vhttpd/${kind}'
}

fn inproc_vjsx_startup_method(kind string) string {
	return kind.to_upper()
}

fn (e InProcVjsxExecutor) build_startup_runtime_payload(lane VjsxExecutionLane, kind string) string {
	config := e.facade_snapshot().config
	request_id := inproc_vjsx_startup_request_id(kind, lane.id)
	path := inproc_vjsx_startup_path(kind)
	return json.encode(InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            kind
		lane_id:                  lane.id
		request_id:               request_id
		trace_id:                 request_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		build_root:               config.build_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           ''
		request_host:             ''
		request_port:             ''
		request_target:           path
		request_protocol_version: ''
		request_remote_addr:      ''
		request_server:           map[string]string{}
		method:                   inproc_vjsx_startup_method(kind)
		path:                     path
	})
}

fn (e InProcVjsxExecutor) execute_startup_hook(mut app App, idx int, lane VjsxExecutionLane, kind string) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	request_id := inproc_vjsx_startup_request_id(kind, lane.id)
	e.activate_lane_request_context(idx, mut app, lane.id, HttpLogicDispatchRequest{
		method:     inproc_vjsx_startup_method(kind)
		path:       inproc_vjsx_startup_path(kind)
		trace_id:   request_id
		request_id: request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	js_ctx_host := host.session.context()
	runtime_obj := js_ctx_host.json_parse(e.build_startup_runtime_payload(lane, kind))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := js_ctx_host.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	mut js_runtime := js_ctx_host.call(create_runtime_fn, runtime_obj) or {
		return error('inproc_vjsx_executor_${kind}_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	mut result := if host.is_module_entry && !isnil(host.module_binding) {
		inproc_vjsx_call_module_entry(host.module_binding, kind, js_runtime) or {
			if err.msg() != 'inproc_vjsx_executor_missing_${kind}_handler' {
				return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
			}
			inproc_vjsx_call_global_entry(js_ctx_host, kind, js_runtime) or {
				if err.msg() == 'inproc_vjsx_executor_missing_${kind}_handler' {
					return
				}
				return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
			}
		}
	} else {
		hook_global_name := if kind == 'app_startup' {
			'__vhttpd_app_startup_handle'
		} else {
			'__vhttpd_startup_handle'
		}
		hook := js_ctx_host.js_global(hook_global_name)
		defer {
			hook.free()
		}
		if hook.is_undefined() || !hook.is_function() {
			return
		}
		js_ctx_host.call(hook, js_runtime) or {
			return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	normalize_fn := js_ctx_host.js_global('__vhttpd_normalize_startup_result')
	defer {
		normalize_fn.free()
	}
	if result.instanceof('Promise') {
		mut awaited := result.await()
		defer {
			awaited.free()
		}
		mut normalized := js_ctx_host.call(normalize_fn, awaited) or {
			return error('inproc_vjsx_executor_${kind}_normalize_failed:${err.msg()}')
		}
		defer {
			normalized.free()
		}
		commands := startup_result_commands_from_js_value(normalized)
		if commands.len == 0 {
			return
		}
		dispatch_ctx := DispatchContext{
			metadata: {
				'dispatch_kind': kind
				'lane_id':       lane.id
			}
			event:    kind
		}
		_, command_error := app.execute_command_envelopes(request_id, dispatch_ctx, commands)
		if command_error != '' {
			return error('inproc_vjsx_executor_${kind}_command_failed:${command_error}')
		}
		return
	}
	mut normalized := js_ctx_host.call(normalize_fn, result) or {
		return error('inproc_vjsx_executor_${kind}_normalize_failed:${err.msg()}')
	}
	defer {
		normalized.free()
	}
	commands := startup_result_commands_from_js_value(normalized)
	if commands.len == 0 {
		return
	}
	dispatch_ctx := DispatchContext{
		metadata: {
			'dispatch_kind': kind
			'lane_id':       lane.id
		}
		event:    kind
	}
	_, command_error := app.execute_command_envelopes(request_id, dispatch_ctx, commands)
	if command_error != '' {
		return error('inproc_vjsx_executor_${kind}_command_failed:${command_error}')
	}
}

fn (e InProcVjsxExecutor) run_lane_startup(mut app App, idx int, lane VjsxExecutionLane) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut should_run := false
	mut state := e.state
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len && state.hosts[idx].initialized
		&& !state.hosts[idx].startup_completed {
		should_run = true
	}
	state.mu.unlock()
	if !should_run {
		return
	}
	e.execute_startup_hook(mut app, idx, lane, 'startup')!
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len {
		state.hosts[idx].startup_completed = true
	}
	state.mu.unlock()
}

fn (e InProcVjsxExecutor) run_app_startup(mut app App, idx int, lane VjsxExecutionLane) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut source_signature := ''
	mut state := e.state
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len {
		source_signature = state.hosts[idx].source_signature
	}
	if state.app_startup_source_signature != source_signature {
		state.app_startup_source_signature = source_signature
		state.app_startup_running = false
		state.app_startup_completed = false
		state.app_startup_last_error = ''
	}
	state.mu.unlock()
	for {
		state.mu.@lock()
		if state.app_startup_source_signature != source_signature {
			state.app_startup_source_signature = source_signature
			state.app_startup_running = false
			state.app_startup_completed = false
			state.app_startup_last_error = ''
		}
		if state.app_startup_completed {
			state.mu.unlock()
			return
		}
		if state.app_startup_running {
			state.mu.unlock()
			time.sleep(time.millisecond * inproc_vjsx_startup_wait_poll_ms)
			continue
		}
		state.app_startup_running = true
		state.app_startup_last_error = ''
		state.mu.unlock()
		e.execute_startup_hook(mut app, idx, lane, 'app_startup') or {
			state.mu.@lock()
			state.app_startup_running = false
			state.app_startup_completed = false
			state.app_startup_last_error = err.msg()
			state.mu.unlock()
			return error(err.msg())
		}
		state.mu.@lock()
		state.app_startup_running = false
		state.app_startup_completed = true
		state.app_startup_last_error = ''
		state.mu.unlock()
		return
	}
}

fn (e InProcVjsxExecutor) run_startup_hooks(mut app App, idx int, lane VjsxExecutionLane) ! {
	e.run_lane_startup(mut app, idx, lane)!
	e.run_app_startup(mut app, idx, lane)!
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
	e.run_startup_hooks(mut app, idx, lane) or {
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
	ctx := host.session.context()
	request_obj := ctx.json_parse(build_inproc_request_payload(req))
	defer {
		request_obj.free()
	}
	runtime_obj := ctx.json_parse(e.build_runtime_payload(lane, req))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := ctx.js_global('__vhttpd_create_websocket_runtime')
	defer {
		create_runtime_fn.free()
	}
	mut js_runtime := ctx.call(create_runtime_fn, runtime_obj) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	create_ctx_fn := ctx.js_global('__vhttpd_create_ctx')
	defer {
		create_ctx_fn.free()
	}
	mut js_ctx := ctx.call(create_ctx_fn, request_obj, js_runtime) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_ctx_create_failed:${err.msg()}')
	}
	defer {
		js_ctx.free()
	}
	mut result := if host.is_module_entry && !isnil(host.module_binding) {
		inproc_vjsx_call_module_entry(host.module_binding, 'http', js_ctx) or {
			if err.msg() != 'inproc_vjsx_executor_missing_http_handler' {
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_handler_failed:${err.msg()}')
			}
			inproc_vjsx_call_global_entry(ctx, 'http', js_ctx) or {
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_handler_failed:${err.msg()}')
			}
		}
	} else {
		handler := ctx.js_global('__vhttpd_handle')
		defer {
			handler.free()
		}
		if handler.is_undefined() || !handler.is_function() {
			e.record_lane_error(lane.id, 'inproc_vjsx_executor_missing_handler')
			return error('inproc_vjsx_executor_missing_handler')
		}
		ctx.call(handler, js_ctx) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_handler_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	normalize_fn := ctx.js_global('__vhttpd_normalize_result')
	defer {
		normalize_fn.free()
	}
	if result.instanceof('Promise') {
		mut awaited := result.await()
		defer {
			awaited.free()
		}
		mut normalized := ctx.call(normalize_fn, js_ctx, awaited) or {
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
	mut normalized := ctx.call(normalize_fn, js_ctx, result) or {
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
	e.run_startup_hooks(mut app, idx, lane) or {
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
	ctx := host.session.context()
	frame_obj := ctx.json_parse(json.encode(req))
	defer {
		frame_obj.free()
	}
	runtime_obj := ctx.json_parse(e.build_websocket_upstream_runtime_payload(lane, req))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := ctx.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	mut js_runtime := ctx.call(create_runtime_fn, runtime_obj) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	create_frame_fn := ctx.js_global('__vhttpd_create_websocket_upstream_frame')
	defer {
		create_frame_fn.free()
	}
	mut js_frame := ctx.call(create_frame_fn, frame_obj, js_runtime) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_upstream_frame_create_failed:${err.msg()}')
	}
	defer {
		js_frame.free()
	}
	mut result := if host.is_module_entry && !isnil(host.module_binding) {
		inproc_vjsx_call_module_entry(host.module_binding, 'websocket_upstream', js_frame) or {
			if err.msg() != 'inproc_vjsx_executor_missing_websocket_upstream_handler' {
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_websocket_upstream_handler_failed:${err.msg()}')
			}
			inproc_vjsx_call_global_entry(ctx, 'websocket_upstream', js_frame) or {
				if err.msg() == 'inproc_vjsx_executor_missing_websocket_upstream_handler' {
					e.record_lane_success(lane.id)
					return WorkerWebSocketUpstreamDispatchResponse{
						mode:     'websocket_upstream'
						event:    'result'
						id:       req.id
						handled:  false
						commands: []WorkerWebSocketUpstreamCommand{}
					}
				}
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_websocket_upstream_handler_failed:${err.msg()}')
			}
		}
	} else {
		handler := ctx.js_global('__vhttpd_websocket_upstream_handle')
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
		ctx.call(handler, js_frame) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_websocket_upstream_handler_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	normalize_fn := ctx.js_global('__vhttpd_normalize_websocket_upstream_result')
	defer {
		normalize_fn.free()
	}
	if result.instanceof('Promise') {
		mut awaited := result.await()
		defer {
			awaited.free()
		}
		mut normalized := ctx.call(normalize_fn, js_frame, awaited) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_websocket_upstream_normalize_failed:${err.msg()}')
		}
		defer {
			normalized.free()
		}
		e.record_lane_success(lane.id)
		return websocket_upstream_response_from_js_value(normalized, req)
	}
	mut normalized := ctx.call(normalize_fn, js_frame, result) or {
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

fn (e InProcVjsxExecutor) dispatch_websocket_event_once(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	e.bootstrap_placeholder()!
	lane, _ := e.acquire_websocket_lane(frame) or {
		if err.msg() == 'inproc_vjsx_executor_websocket_affinity_key_missing' {
			return WorkerWebSocketDispatchResponse{
				mode:        'websocket_dispatch'
				event:       'result'
				id:          frame.id
				accepted:    false
				closed:      true
				commands:    []WorkerWebSocketFrame{}
				error:       'websocket_affinity_key_missing'
				error_class: 'websocket_affinity_key_missing'
			}
		}
		return error(err.msg())
	}
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
	e.run_startup_hooks(mut app, idx, lane) or {
		e.record_lane_error(lane.id, err.msg())
		return error(err.msg())
	}
	e.activate_lane_request_context(idx, mut app, lane.id, HttpLogicDispatchRequest{
		method:     frame.event
		path:       frame.path
		trace_id:   frame.trace_id
		request_id: frame.request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.session.context()
	runtime_meta := e.websocket_runtime_meta(lane, frame)
	mut js_runtime := build_websocket_js_runtime(ctx, runtime_meta, app.runtime_config_json, mut app)
	defer {
		js_runtime.free()
	}
	mut js_frame := build_websocket_js_frame(ctx, frame, js_runtime)
	defer {
		js_frame.free()
	}
	handler := ctx.js_global('__vhttpd_websocket_handle')
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		e.record_lane_success(lane.id)
		return WorkerWebSocketDispatchResponse{
			mode:     'websocket_dispatch'
			event:    'result'
			id:       frame.id
			accepted: false
			closed:   false
			commands: []WorkerWebSocketFrame{}
		}
	}
	invoke_handler := ctx.js_global('__vhttpd_invoke_websocket_handle')
	defer {
		invoke_handler.free()
	}
	mut result := ctx.call(invoke_handler, js_frame) or {
		err_msg := inproc_vjsx_context_error_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_handler_failed')
		e.record_lane_soft_error(lane.id, err_msg)
		return error('inproc_vjsx_executor_websocket_handler_failed:${err_msg}')
	}
	defer {
		result.free()
	}
	normalize_fn := ctx.js_global('__vhttpd_normalize_websocket_result')
	defer {
		normalize_fn.free()
	}
	if result.instanceof('Promise') {
		mut awaited := result.await()
		defer {
			awaited.free()
		}
		mut normalized := ctx.call(normalize_fn, js_frame, awaited) or {
			err_msg := inproc_vjsx_normalize_error_message(err.msg(),
				'inproc_vjsx_executor_websocket_normalize_failed')
			e.record_lane_soft_error(lane.id, err_msg)
			return error('inproc_vjsx_executor_websocket_normalize_failed:${err_msg}')
		}
		defer {
			normalized.free()
		}
		if frame.event == 'close' {
			e.release_websocket_connection_affinity(frame)
		}
		e.record_lane_success(lane.id)
		return websocket_response_from_js_value(normalized, frame)
	}
	mut normalized := ctx.call(normalize_fn, js_frame, result) or {
		err_msg := inproc_vjsx_normalize_error_message(err.msg(),
			'inproc_vjsx_executor_websocket_normalize_failed')
		e.record_lane_soft_error(lane.id, err_msg)
		return error('inproc_vjsx_executor_websocket_normalize_failed:${err_msg}')
	}
	defer {
		normalized.free()
	}
	if frame.event == 'close' {
		e.release_websocket_connection_affinity(frame)
	}
	e.record_lane_success(lane.id)
	return websocket_response_from_js_value(normalized, frame)
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	mut last_err := 'inproc_vjsx_executor_dispatch_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		outcome := e.dispatch_websocket_event_once(mut app, frame) or {
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
