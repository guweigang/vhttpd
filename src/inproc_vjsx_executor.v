module main

import json
import log
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
const inproc_vjsx_lane_task_timeout = 10 * time.second
const inproc_vjsx_websocket_queue_wait_timeout = 30 * time.second
const inproc_vjsx_dispatch_retry_attempts = 2
const inproc_vjsx_startup_wait_poll_ms = 5
const inproc_vjsx_signature_probe_poll_ms = 100
const inproc_vjsx_signature_refresh_debounce_ms = 200
const inproc_vjsx_signature_full_refresh_ms = 3000
const inproc_vjsx_http_facade_source = $embed_file('src/inproc_vjsx_http_facade.js')

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
	app_entry          string
	module_root        string
	build_root         string
	signature_root     string
	signature_include  []string
	signature_exclude  []string
	runtime_profile    string
	thread_count       int
	max_requests       int
	enable_fs          bool
	enable_process     bool
	enable_network     bool
	websocket_affinity WebSocketAffinityConfig
	websocket_actor    WebSocketActorConfig
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
	mu                                      sync.Mutex
	app_ref                                 &App = unsafe { nil }
	facade                                  VjsxRuntimeFacade
	session_store                           MemoryStateStore[string]
	lanes                                   []VjsxExecutionLane
	hosts                                   []VjsxLaneHost
	lane_workers                            []VjsxLaneWorker
	rr_index                                int
	websocket_affinity_lane_by_key          map[string]string
	websocket_affinity_ref_count_by_key     map[string]int
	websocket_connection_lane_by_id         map[string]string
	websocket_connection_affinity_key_by_id map[string]string
	websocket_connection_actor_key_by_id    map[string]string
	websocket_connection_actor_class_by_id  map[string]string
	websocket_mailbox_by_key                map[string][]InProcVjsxWebSocketTask
	websocket_mailbox_pending_keys          []string
	websocket_mailbox_running_by_key        map[string]bool
	lane_wakeup_by_id                       map[string]VjsxLaneWakeup
	cached_source_probe                     string
	cached_source_signature                 string
	signature_refresh_started               bool
	signature_refresh_stop                  bool
	signature_last_checked_at               i64
	signature_last_probe_at                 i64
	signature_pending_since                 i64
	signature_last_error                    string
	warmup_source_signature                 string
	warmup_running                          bool
	warmup_completed                        bool
	warmup_last_error                       string
	app_startup_source_signature            string
	app_startup_running                     bool
	app_startup_completed                   bool
	app_startup_last_error                  string
}

struct VjsxLaneWakeup {
	wake_at_ms i64
	generation u64
}

struct VjsxLaneHost {
mut:
	initialized       bool
	startup_completed bool
	dirty             bool
	source_signature  string
	is_module_entry   bool
	temp_root         string
	app_ref           &App                 = unsafe { nil }
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

fn (e InProcVjsxExecutor) remember_app(mut app App) {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.mu.@lock()
	state.app_ref = app
	state.mu.unlock()
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
	trace_id    string @[json: 'trace_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target      string
	target_type string @[json: 'target_type']
	payload     string
}

struct InProcVjsxHostWebSocketDispatchRequest {
	commands []WorkerWebSocketFrame
}

struct InProcVjsxHostWebSocketDispatchResponse {
	ok              bool
	has_close       bool   @[json: 'has_close']
	close_code      int    @[json: 'close_code']
	close_reason    string @[json: 'close_reason']
	close_target_id string @[json: 'close_target_id']
	failures        []WorkerWebSocketDispatchCommandFailure
	error           string
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

struct InProcVjsxWebSocketTaskResult {
	ok            bool
	response_json string
	error         string
}

struct InProcVjsxWebSocketTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxWebSocketTaskResult
	ready  bool
}

struct InProcVjsxWebSocketTask {
	app               &App = unsafe { nil }
	frame             WorkerWebSocketFrame
	done              chan bool
	started           chan bool
	affinity_key      string
	affinity_priority int
	actor_key         string
	actor_class       string
	actor_priority    int
	actor_persist     bool
	actor_serialized  bool
mut:
	slot &InProcVjsxWebSocketTaskSlot = unsafe { nil }
}

struct WebSocketActorDecision {
mut:
	key        string
	class_name string
	priority   int
	persist    bool = true
}

struct InProcVjsxLaneSnapshotTaskResult {
	ok    bool
	raw   string
	error string
}

struct InProcVjsxLaneSnapshotTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLaneSnapshotTaskResult
	ready  bool
}

struct InProcVjsxLaneSnapshotTask {
	app  &App = unsafe { nil }
	done chan bool
mut:
	slot &InProcVjsxLaneSnapshotTaskSlot = unsafe { nil }
}

struct InProcVjsxLaneWarmupTaskResult {
	ok    bool
	error string
}

struct InProcVjsxLaneWarmupTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLaneWarmupTaskResult
	ready  bool
}

struct InProcVjsxLaneWarmupTask {
	app  &App = unsafe { nil }
	done chan bool
mut:
	slot &InProcVjsxLaneWarmupTaskSlot = unsafe { nil }
}

struct InProcVjsxLanePumpTaskResult {
	ok    bool
	error string
}

struct InProcVjsxLanePumpTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLanePumpTaskResult
	ready  bool
}

struct InProcVjsxLanePumpTask {
	done chan bool
mut:
	slot &InProcVjsxLanePumpTaskSlot = unsafe { nil }
}

struct InProcVjsxLaneAffinityTaskResult {
	ok    bool
	value WebSocketAffinityDecision
	actor WebSocketActorDecision
	error string
}

struct InProcVjsxLaneAffinityTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLaneAffinityTaskResult
	ready  bool
}

struct InProcVjsxLaneAffinityTask {
	app   &App = unsafe { nil }
	frame WorkerWebSocketFrame
	done  chan bool
	kind  string
mut:
	slot &InProcVjsxLaneAffinityTaskSlot = unsafe { nil }
}

struct InProcVjsxHostSnapshotRequest {
	scope string
	kind  string
}

struct InProcVjsxHostSessionStoreRequest {
	namespace      string
	op             string
	key            string
	value          string
	expected_value string @[json: 'expected_value']
	expected_found bool   @[json: 'expected_found']
	delete_value   bool   @[json: 'delete_value']
	ttl_ms         i64    @[json: 'ttl_ms']
}

struct InProcVjsxHostSessionStoreResponse {
	ok       bool
	found    bool
	conflict bool
	value    string
	error    string
}

struct VjsxLaneWorker {
mut:
	lane_id         string
	websocket_tasks chan InProcVjsxWebSocketTask
	snapshot_tasks  chan InProcVjsxLaneSnapshotTask
	warmup_tasks    chan InProcVjsxLaneWarmupTask
	pump_tasks      chan InProcVjsxLanePumpTask
	affinity_tasks  chan InProcVjsxLaneAffinityTask
	stop_ch         chan bool
	thread          thread
	started         bool
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
	mut lane_workers := []VjsxLaneWorker{}
	for lane in lanes {
		lane_workers << VjsxLaneWorker{
			lane_id:         lane.id
			websocket_tasks: chan InProcVjsxWebSocketTask{cap: 64}
			snapshot_tasks:  chan InProcVjsxLaneSnapshotTask{cap: 16}
			warmup_tasks:    chan InProcVjsxLaneWarmupTask{cap: 4}
			pump_tasks:      chan InProcVjsxLanePumpTask{cap: 4}
			affinity_tasks:  chan InProcVjsxLaneAffinityTask{cap: 16}
			stop_ch:         chan bool{cap: 1}
		}
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
	mut executor := InProcVjsxExecutor{
		state: &VjsxExecutorState{
			facade:                                  VjsxRuntimeFacade{
				config: config
			}
			session_store:                           new_memory_state_store[string]()
			lanes:                                   lanes
			hosts:                                   hosts
			lane_workers:                            lane_workers
			websocket_affinity_lane_by_key:          map[string]string{}
			websocket_affinity_ref_count_by_key:     map[string]int{}
			websocket_connection_lane_by_id:         map[string]string{}
			websocket_connection_affinity_key_by_id: map[string]string{}
			websocket_connection_actor_key_by_id:    map[string]string{}
			websocket_connection_actor_class_by_id:  map[string]string{}
			websocket_mailbox_by_key:                map[string][]InProcVjsxWebSocketTask{}
			websocket_mailbox_pending_keys:          []string{}
			websocket_mailbox_running_by_key:        map[string]bool{}
			lane_wakeup_by_id:                       map[string]VjsxLaneWakeup{}
			cached_source_probe:                     initial_probe
			cached_source_signature:                 initial_signature
			signature_last_checked_at:               if initial_signature != '' {
				now_ms
			} else {
				0
			}
			signature_last_probe_at:                 if initial_probe != '' {
				now_ms
			} else {
				0
			}
		}
	}
	executor.start_lane_workers()
	return executor
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
	e.remember_app(mut app)
	e.bootstrap_placeholder()!
	for lane in e.lane_snapshot() {
		log.debug('[vhttpd] warmup request begin lane=${lane.id}')
		e.request_lane_warmup(mut app, lane)!
		log.debug('[vhttpd] warmup request done lane=${lane.id}')
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
		needs_full_refresh := probe_changed || (pending_since > 0
			&& now - pending_since >= inproc_vjsx_signature_refresh_debounce_ms)
			|| (last_checked_at <= 0
			|| now - last_checked_at >= inproc_vjsx_signature_full_refresh_ms)
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
		'app', 'hook', 'runtime' { 'app' }
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

fn normalize_websocket_actor_source(raw string) string {
	source := raw.trim_space().to_lower()
	return match source {
		'connection_cache', 'connection-cache', 'cache' { 'connection_cache' }
		'app', 'hook', 'runtime' { 'app' }
		'header', 'headers' { 'header' }
		'metadata', 'meta' { 'metadata' }
		else { 'query' }
	}
}

fn normalize_websocket_actor_fallback(raw string) string {
	fallback := raw.trim_space().to_lower()
	return if fallback == 'reject' { 'reject' } else { 'unkeyed' }
}

fn normalize_websocket_actor_event(raw string) string {
	event := raw.trim_space().to_lower()
	return match event {
		'open', 'message', 'close', 'info' { event }
		else { '' }
	}
}

fn websocket_actor_events_include(events []string, event string) bool {
	normalized_event := normalize_websocket_actor_event(event)
	if normalized_event == '' {
		return false
	}
	if events.len == 0 {
		return true
	}
	for raw in events {
		if normalize_websocket_actor_event(raw) == normalized_event {
			return true
		}
	}
	return false
}

fn websocket_actor_queue_key(class_name string, key string) string {
	trimmed_key := key.trim_space()
	if trimmed_key == '' {
		return ''
	}
	trimmed_class := class_name.trim_space()
	if trimmed_class == '' {
		return trimmed_key
	}
	return '${trimmed_class}:${trimmed_key}'
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
		'app' { '' }
		'header' { websocket_affinity_header_lookup(frame.headers, key).trim_space() }
		'path_param' { '' }
		else { (frame.query[key] or { '' }).trim_space() }
	}
}

struct WebSocketAffinityDecision {
mut:
	key      string
	priority int
}

fn websocket_affinity_priority_from_string(raw string) int {
	return match raw.trim_space().to_lower() {
		'high' { 100 }
		'low' { -100 }
		else { 0 }
	}
}

fn websocket_actor_priority_from_string(raw string) int {
	return websocket_affinity_priority_from_string(raw)
}

fn websocket_affinity_decision_from_app_result(val vjsx.Value) WebSocketAffinityDecision {
	if val.is_undefined() || val.is_null() {
		return WebSocketAffinityDecision{}
	}
	if val.is_string() {
		return WebSocketAffinityDecision{
			key: val.to_string().trim_space()
		}
	}
	key_val := val.get('key')
	priority_val := val.get('priority')
	defer {
		key_val.free()
		priority_val.free()
	}
	mut decision := WebSocketAffinityDecision{}
	if !key_val.is_undefined() && !key_val.is_null() {
		decision.key = key_val.to_string().trim_space()
	}
	if !priority_val.is_undefined() && !priority_val.is_null() {
		if priority_val.is_number() {
			decision.priority = int(priority_val.to_i64())
		} else {
			decision.priority = websocket_affinity_priority_from_string(priority_val.to_string())
		}
	}
	return decision
}

fn websocket_actor_decision_from_app_result(val vjsx.Value) WebSocketActorDecision {
	if val.is_undefined() || val.is_null() {
		return WebSocketActorDecision{}
	}
	if val.is_string() {
		return WebSocketActorDecision{
			key:     val.to_string().trim_space()
			persist: true
		}
	}
	key_val := val.get('key')
	class_val := val.get('class')
	priority_val := val.get('priority')
	persist_val := val.get('persist')
	defer {
		key_val.free()
		class_val.free()
		priority_val.free()
		persist_val.free()
	}
	mut decision := WebSocketActorDecision{
		persist: true
	}
	if !key_val.is_undefined() && !key_val.is_null() {
		decision.key = key_val.to_string().trim_space()
	}
	if !class_val.is_undefined() && !class_val.is_null() {
		decision.class_name = class_val.to_string().trim_space()
	}
	if !priority_val.is_undefined() && !priority_val.is_null() {
		if priority_val.is_number() {
			decision.priority = int(priority_val.to_i64())
		} else {
			decision.priority = websocket_actor_priority_from_string(priority_val.to_string())
		}
	}
	if !persist_val.is_undefined() && !persist_val.is_null() {
		decision.persist = persist_val.to_string().trim_space().to_lower() !in [
			'false',
			'0',
			'no',
			'off',
		]
	}
	return decision
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

fn (e InProcVjsxExecutor) force_select_lane_by_id(lane_id string) !VjsxExecutionLane {
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
		state.lanes[idx].inflight++
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_lane_not_found')
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
	lane_id := state.websocket_connection_lane_by_id[frame.id] or { '' }
	affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	state.websocket_connection_lane_by_id.delete(frame.id)
	state.websocket_connection_affinity_key_by_id.delete(frame.id)
	if affinity_key == '' {
		return
	}
	if affinity_key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[affinity_key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(affinity_key)
			if lane_id != '' && !websocket_should_pin_affinity_lane(frame, affinity_key) {
				state.websocket_affinity_lane_by_key.delete(affinity_key)
			}
			state.websocket_mailbox_by_key.delete(affinity_key)
			state.websocket_mailbox_running_by_key.delete(affinity_key)
			mut next_pending_keys := []string{}
			for key in state.websocket_mailbox_pending_keys {
				if key != affinity_key {
					next_pending_keys << key
				}
			}
			state.websocket_mailbox_pending_keys = next_pending_keys
		} else {
			state.websocket_affinity_ref_count_by_key[affinity_key] = remaining
		}
	}
}

fn (e InProcVjsxExecutor) release_websocket_affinity_key(affinity_key string) {
	if isnil(e.state) {
		return
	}
	key := affinity_key.trim_space()
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(key)
			state.websocket_mailbox_by_key.delete(key)
			state.websocket_mailbox_running_by_key.delete(key)
			mut next_pending_keys := []string{}
			for pending_key in state.websocket_mailbox_pending_keys {
				if pending_key != key {
					next_pending_keys << pending_key
				}
			}
			state.websocket_mailbox_pending_keys = next_pending_keys
		} else {
			state.websocket_affinity_ref_count_by_key[key] = remaining
		}
	}
}

fn (e InProcVjsxExecutor) migrate_websocket_connection_affinity(frame WorkerWebSocketFrame, affinity_key string, current_lane_id string) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	new_key := affinity_key.trim_space()
	if new_key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	old_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	if old_key == new_key {
		return
	}
	old_lane := state.websocket_connection_lane_by_id[frame.id] or { '' }
	if old_key != '' && old_key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[old_key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(old_key)
			if old_lane != '' && !websocket_should_pin_affinity_lane(frame, old_key) {
				state.websocket_affinity_lane_by_key.delete(old_key)
			}
		} else {
			state.websocket_affinity_ref_count_by_key[old_key] = remaining
		}
	}
	mut new_lane := if old_lane != '' {
		old_lane
	} else {
		state.websocket_affinity_lane_by_key[new_key] or { '' }
	}
	if new_lane == '' && current_lane_id.trim_space() != ''
		&& websocket_should_pin_affinity_lane(frame, new_key) {
		new_lane = current_lane_id.trim_space()
	}
	state.websocket_connection_affinity_key_by_id[frame.id] = new_key
	if new_lane != '' {
		state.websocket_connection_lane_by_id[frame.id] = new_lane
		state.websocket_affinity_lane_by_key[new_key] = new_lane
	}
	state.websocket_affinity_ref_count_by_key[new_key] = (state.websocket_affinity_ref_count_by_key[new_key] or {
		0
	}) + 1
	log.debug('[vhttpd] websocket affinity migrated socket=${frame.id} request_id=${frame.request_id} old_key=${old_key} new_key=${new_key} lane=${new_lane}')
}

fn (e InProcVjsxExecutor) websocket_affinity_probe_lane() !VjsxExecutionLane {
	return e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)
}

fn (e InProcVjsxExecutor) request_lane_affinity(mut app App, lane VjsxExecutionLane, frame WorkerWebSocketFrame) !WebSocketAffinityDecision {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneAffinityTaskSlot{}
	worker.affinity_tasks <- InProcVjsxLaneAffinityTask{
		app:   app
		frame: frame
		slot:  slot
		done:  done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_websocket_affinity_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_websocket_affinity_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
	return result.value
}

fn (e InProcVjsxExecutor) resolve_websocket_affinity_key_from_app(mut app App, frame WorkerWebSocketFrame) !WebSocketAffinityDecision {
	lane := e.websocket_affinity_probe_lane()!
	return e.request_lane_affinity(mut app, lane, frame)
}

fn (e InProcVjsxExecutor) resolve_websocket_affinity(frame WorkerWebSocketFrame) !WebSocketAffinityDecision {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := state.facade.config.websocket_affinity
	state.mu.@lock()
	existing_affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	state.mu.unlock()
	mut decision := WebSocketAffinityDecision{
		key: existing_affinity_key
	}
	if decision.key == '' {
		if normalize_websocket_affinity_source(config.source) == 'app' {
			mut app_ref := &App(unsafe { nil })
			state.mu.@lock()
			app_ref = state.app_ref
			state.mu.unlock()
			if isnil(app_ref) {
				return error('inproc_vjsx_executor_app_missing')
			}
			decision = e.resolve_websocket_affinity_key_from_app(mut app_ref, frame) or {
				return error(err.msg())
			}
		} else {
			decision.key = websocket_affinity_value(frame, config)
		}
	}
	if decision.key == '' && config.enabled
		&& normalize_websocket_affinity_fallback(config.fallback) == 'reject' {
		return error('inproc_vjsx_executor_websocket_affinity_key_missing')
	}
	return decision
}

fn (e InProcVjsxExecutor) websocket_actor_probe_lane() !VjsxExecutionLane {
	return e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
}

fn (e InProcVjsxExecutor) request_lane_actor(mut app App, lane VjsxExecutionLane, frame WorkerWebSocketFrame) !WebSocketActorDecision {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneAffinityTaskSlot{}
	worker.affinity_tasks <- InProcVjsxLaneAffinityTask{
		app:   app
		frame: frame
		slot:  slot
		done:  done_ch
		kind:  'actor'
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_websocket_actor_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_websocket_actor_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
	return websocket_actor_decision_from_affinity_result(result)
}

fn websocket_actor_decision_from_affinity_result(result InProcVjsxLaneAffinityTaskResult) WebSocketActorDecision {
	return result.actor
}

fn (e InProcVjsxExecutor) resolve_websocket_actor_from_app(mut app App, frame WorkerWebSocketFrame) !WebSocketActorDecision {
	lane := e.websocket_actor_probe_lane()!
	defer {
		e.release_lane(lane.id)
	}
	return e.request_lane_actor(mut app, lane, frame)
}

fn (e InProcVjsxExecutor) websocket_actor_connection_cache(frame WorkerWebSocketFrame) WebSocketActorDecision {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return WebSocketActorDecision{}
	}
	mut state := e.state
	state.mu.@lock()
	cached_key := state.websocket_connection_actor_key_by_id[frame.id] or { '' }
	cached_class := state.websocket_connection_actor_class_by_id[frame.id] or { '' }
	state.mu.unlock()
	if cached_key == '' {
		return WebSocketActorDecision{}
	}
	return WebSocketActorDecision{
		key:        cached_key
		class_name: cached_class
		persist:    true
	}
}

fn websocket_actor_value_from_source(frame WorkerWebSocketFrame, source WebSocketActorSourceConfig) WebSocketActorDecision {
	key_name := source.key.trim_space()
	if key_name == '' {
		return WebSocketActorDecision{}
	}
	value := match normalize_websocket_actor_source(source.typ) {
		'header' { websocket_affinity_header_lookup(frame.headers, key_name).trim_space() }
		'metadata' { (frame.metadata[key_name] or { '' }).trim_space() }
		else { (frame.query[key_name] or { '' }).trim_space() }
	}

	if value == '' {
		return WebSocketActorDecision{}
	}
	return WebSocketActorDecision{
		key:        value
		class_name: source.class_name.trim_space()
		persist:    true
	}
}

fn (e InProcVjsxExecutor) websocket_actor_enabled_for_frame(frame WorkerWebSocketFrame) bool {
	if isnil(e.state) {
		return false
	}
	mut state := e.state
	config := state.facade.config.websocket_actor
	return config.enabled && websocket_actor_events_include(config.events, frame.event)
}

fn (e InProcVjsxExecutor) resolve_websocket_actor(frame WorkerWebSocketFrame) !WebSocketActorDecision {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := state.facade.config.websocket_actor
	if !config.enabled || !websocket_actor_events_include(config.events, frame.event) {
		return WebSocketActorDecision{}
	}
	for source in config.sources {
		source_kind := normalize_websocket_actor_source(source.typ)
		mut decision := WebSocketActorDecision{}
		if source_kind == 'connection_cache' {
			decision = e.websocket_actor_connection_cache(frame)
		} else if source_kind == 'app' {
			mut app_ref := &App(unsafe { nil })
			state.mu.@lock()
			app_ref = state.app_ref
			state.mu.unlock()
			if isnil(app_ref) {
				return error('inproc_vjsx_executor_app_missing')
			}
			decision = e.resolve_websocket_actor_from_app(mut app_ref, frame) or {
				return error(err.msg())
			}
		} else {
			decision = websocket_actor_value_from_source(frame, source)
		}
		if decision.key.trim_space() != '' {
			return decision
		}
	}
	if normalize_websocket_actor_fallback(config.fallback) == 'reject' {
		return error('inproc_vjsx_executor_websocket_actor_key_missing')
	}
	return WebSocketActorDecision{}
}

fn (e InProcVjsxExecutor) cache_websocket_actor(frame WorkerWebSocketFrame, actor_key string, actor_class string) {
	if isnil(e.state) || frame.id.trim_space() == '' || actor_key.trim_space() == '' {
		return
	}
	if frame.event == 'open' {
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_connection_actor_key_by_id[frame.id] = actor_key.trim_space()
	state.websocket_connection_actor_class_by_id[frame.id] = actor_class.trim_space()
	state.mu.unlock()
}

fn (e InProcVjsxExecutor) release_websocket_actor(frame WorkerWebSocketFrame) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	if frame.event == 'close' {
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_connection_actor_key_by_id.delete(frame.id)
	state.websocket_connection_actor_class_by_id.delete(frame.id)
	state.mu.unlock()
}

fn (e InProcVjsxExecutor) acquire_websocket_lane(frame WorkerWebSocketFrame) !(VjsxExecutionLane, string) {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := state.facade.config.websocket_affinity
	state.mu.@lock()
	existing_affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	state.mu.unlock()
	mut affinity := WebSocketAffinityDecision{
		key: existing_affinity_key
	}
	if affinity.key == '' {
		if normalize_websocket_affinity_source(config.source) == 'app' {
			mut app_ref := &App(unsafe { nil })
			state.mu.@lock()
			app_ref = state.app_ref
			state.mu.unlock()
			if isnil(app_ref) {
				return error('inproc_vjsx_executor_app_missing')
			}
			affinity = e.resolve_websocket_affinity_key_from_app(mut app_ref, frame) or {
				return error(err.msg())
			}
		} else {
			affinity.key = websocket_affinity_value(frame, config)
		}
	}
	affinity_key := affinity.key
	if affinity_key == '' {
		if config.enabled && normalize_websocket_affinity_fallback(config.fallback) == 'reject' {
			return error('inproc_vjsx_executor_websocket_affinity_key_missing')
		}
		lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
		return lane, ''
	}
	should_pin_lane := websocket_should_pin_affinity_lane(frame, affinity_key)
	if !should_pin_lane {
		lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
		return lane, affinity_key
	}
	state.mu.@lock()
	mut mapped_lane_id := state.websocket_connection_lane_by_id[frame.id] or { '' }
	if mapped_lane_id == '' {
		mapped_lane_id = state.websocket_affinity_lane_by_key[affinity_key] or { '' }
	}
	state.mu.unlock()
	lane := if mapped_lane_id != '' {
		e.acquire_lane_by_id(mapped_lane_id, inproc_vjsx_lane_wait_timeout_ms)!
	} else {
		e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
	}
	if frame.id.trim_space() != '' {
		state.mu.@lock()
		state.websocket_affinity_lane_by_key[affinity_key] = lane.id
		existing_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
		if existing_key == '' {
			state.websocket_affinity_ref_count_by_key[affinity_key] = (state.websocket_affinity_ref_count_by_key[affinity_key] or {
				0
			}) + 1
		}
		state.websocket_connection_lane_by_id[frame.id] = lane.id
		state.websocket_connection_affinity_key_by_id[frame.id] = affinity_key
		state.mu.unlock()
	}
	return lane, affinity_key
}

fn (e InProcVjsxExecutor) resolve_websocket_dispatch_affinity(frame WorkerWebSocketFrame) !(string, int, bool) {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := state.facade.config.websocket_affinity
	state.mu.@lock()
	existing_affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	state.mu.unlock()
	mut affinity := WebSocketAffinityDecision{
		key: existing_affinity_key
	}
	if affinity.key == '' {
		if normalize_websocket_affinity_source(config.source) == 'app' {
			mut app_ref := &App(unsafe { nil })
			state.mu.@lock()
			app_ref = state.app_ref
			state.mu.unlock()
			if isnil(app_ref) {
				return error('inproc_vjsx_executor_app_missing')
			}
			affinity = e.resolve_websocket_affinity_key_from_app(mut app_ref, frame) or {
				return error(err.msg())
			}
		} else {
			affinity.key = websocket_affinity_value(frame, config)
		}
	}
	affinity_key := affinity.key
	if affinity_key == '' {
		if config.enabled && normalize_websocket_affinity_fallback(config.fallback) == 'reject' {
			return error('inproc_vjsx_executor_websocket_affinity_key_missing')
		}
		return '', affinity.priority, false
	}
	return affinity_key, affinity.priority, websocket_should_pin_affinity_lane(frame, affinity_key)
}

fn websocket_should_pin_affinity_lane(_frame WorkerWebSocketFrame, affinity_key string) bool {
	key := affinity_key.trim_space()
	if key == '' {
		return false
	}
	return true
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
	js_err := ctx.js_exception()
	js_msg := js_err.msg().trim_space()
	if js_msg != '' && js_msg != '{}' {
		return js_msg
	}

	val := ctx.js_exception_value()
	defer {
		val.free()
	}
	json_msg := val.json_stringify()
	if json_msg != '' && json_msg != 'undefined' && json_msg != 'null' && json_msg != '{}' {
		eprintln('[vhttpd] DEBUG: captured raw js exception json=${json_msg}')
		return json_msg
	}

	normalized := inproc_vjsx_normalize_error_message(err_msg, '')
	if normalized != '' {
		return normalized
	}
	return fallback
}

pub fn (e InProcVjsxExecutor) release_lane(lane_id string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		if state.lanes[i].inflight > 0 {
			state.lanes[i].inflight--
		}
		break
	}
	state.mu.unlock()
	e.try_schedule_websocket_mailboxes()
}

fn (e InProcVjsxExecutor) start_lane_workers() {
	if isnil(e.state) {
		return
	}
	mut workers := []VjsxLaneWorker{}
	mut state := e.state
	state.mu.@lock()
	workers = state.lane_workers.clone()
	state.mu.unlock()
	for idx, worker in workers {
		if worker.started {
			continue
		}
		task_ch := worker.websocket_tasks
		snapshot_ch := worker.snapshot_tasks
		warmup_ch := worker.warmup_tasks
		pump_ch := worker.pump_tasks
		affinity_ch := worker.affinity_tasks
		stop_ch := worker.stop_ch
		lane_id := worker.lane_id
		mut thr := spawn inproc_vjsx_lane_worker_loop(e.state, lane_id, task_ch, snapshot_ch,
			warmup_ch, pump_ch, affinity_ch, stop_ch)
		state.mu.@lock()
		if idx >= 0 && idx < state.lane_workers.len {
			state.lane_workers[idx].thread = thr
			state.lane_workers[idx].started = true
		}
		state.mu.unlock()
	}
}

fn (e InProcVjsxExecutor) lane_worker_by_id(lane_id string) ?VjsxLaneWorker {
	if isnil(e.state) || lane_id == '' {
		return none
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for worker in state.lane_workers {
		if worker.lane_id == lane_id {
			return worker
		}
	}
	return none
}

fn (mut state VjsxExecutorState) schedule_lane_wakeup(lane_id string, wake_at_ms i64, generation u64) {
	if isnil(state) || lane_id.trim_space() == '' {
		return
	}
	state.mu.@lock()
	state.lane_wakeup_by_id[lane_id] = VjsxLaneWakeup{
		wake_at_ms: wake_at_ms
		generation: generation
	}
	state.mu.unlock()
	go state.deliver_lane_wakeup(lane_id, wake_at_ms, generation)
}

fn (mut state VjsxExecutorState) cancel_lane_wakeup(lane_id string, generation u64) {
	if isnil(state) || lane_id.trim_space() == '' {
		return
	}
	state.mu.@lock()
	current_wakeup := state.lane_wakeup_by_id[lane_id] or {
		state.mu.unlock()
		return
	}
	if current_wakeup.generation == generation {
		state.lane_wakeup_by_id.delete(lane_id)
	}
	state.mu.unlock()
}

fn (mut state VjsxExecutorState) deliver_lane_wakeup(lane_id string, wake_at_ms i64, generation u64) {
	if isnil(state) || lane_id.trim_space() == '' {
		return
	}
	delay_ms := wake_at_ms - time.now().unix_milli()
	if delay_ms > 0 {
		time.sleep(time.millisecond * int(delay_ms))
	}
	state.mu.@lock()
	current_wakeup := state.lane_wakeup_by_id[lane_id] or {
		state.mu.unlock()
		return
	}
	if current_wakeup.wake_at_ms != wake_at_ms || current_wakeup.generation != generation {
		state.mu.unlock()
		return
	}
	state.lane_wakeup_by_id.delete(lane_id)
	state.mu.unlock()
	executor := InProcVjsxExecutor{
		state: state
	}
	lane := executor.lane_snapshot_by_id(lane_id) or { return }
	executor.request_lane_pump(lane) or {}
}

fn (e InProcVjsxExecutor) lane_snapshot_by_id(lane_id string) ?VjsxExecutionLane {
	if isnil(e.state) || lane_id == '' {
		return none
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for lane in state.lanes {
		if lane.id == lane_id {
			return lane
		}
	}
	return none
}

fn (e InProcVjsxExecutor) dispatch_websocket_task_to_lane(task InProcVjsxWebSocketTask, lane_id string) ! {
	worker := e.lane_worker_by_id(lane_id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	if task.frame.event == 'open' {
	}
	log.debug('[vhttpd] websocket dispatch enqueue lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id}')
	worker.websocket_tasks <- task
	if task.frame.event == 'open' {
	}
}

fn (e InProcVjsxExecutor) bind_websocket_task_lane(task InProcVjsxWebSocketTask, lane_id string) {
	if isnil(e.state) || lane_id.trim_space() == '' {
		return
	}
	if task.actor_serialized {
		return
	}
	key := task.affinity_key.trim_space()
	if !websocket_should_pin_affinity_lane(task.frame, key) {
		return
	}
	if key == '' && task.frame.id.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if key != '' {
		state.websocket_affinity_lane_by_key[key] = lane_id
	}
	if task.frame.id.trim_space() != '' {
		state.websocket_connection_lane_by_id[task.frame.id] = lane_id
		if key != '' {
			state.websocket_connection_affinity_key_by_id[task.frame.id] = key
		}
	}
}

fn (e InProcVjsxExecutor) try_schedule_websocket_mailboxes() {
	if isnil(e.state) {
		return
	}
	for {
		mut selected_key := ''
		mut selected_task := InProcVjsxWebSocketTask{}
		mut selected_lane_id := ''
		mut selected_priority := -1000000000
		mut state := e.state
		state.mu.@lock()
		if state.websocket_mailbox_pending_keys.len == 0 {
			state.mu.unlock()
			return
		}
		mut filtered_pending_keys := []string{}
		for key in state.websocket_mailbox_pending_keys {
			if state.websocket_mailbox_running_by_key[key] or { false } {
				if key !in filtered_pending_keys {
					filtered_pending_keys << key
				}
				continue
			}
			queue := state.websocket_mailbox_by_key[key] or { []InProcVjsxWebSocketTask{} }
			if queue.len == 0 {
				continue
			}
			if key !in filtered_pending_keys {
				filtered_pending_keys << key
			}
			priority := if queue[0].actor_serialized {
				queue[0].actor_priority
			} else {
				queue[0].affinity_priority
			}
			if selected_key == '' || priority > selected_priority {
				selected_key = key
				selected_task = queue[0]
				selected_priority = priority
			}
		}
		state.websocket_mailbox_pending_keys = filtered_pending_keys
		if selected_key != '' {
			queue := state.websocket_mailbox_by_key[selected_key] or { []InProcVjsxWebSocketTask{} }
			remaining := if queue.len > 1 { queue[1..] } else { []InProcVjsxWebSocketTask{} }
			if remaining.len == 0 {
				state.websocket_mailbox_by_key.delete(selected_key)
				mut next_pending_keys := []string{}
				for key in state.websocket_mailbox_pending_keys {
					if key != selected_key {
						next_pending_keys << key
					}
				}
				state.websocket_mailbox_pending_keys = next_pending_keys
			} else {
				state.websocket_mailbox_by_key[selected_key] = remaining
			}
			state.websocket_mailbox_running_by_key[selected_key] = true
		}
		state.mu.unlock()
		if selected_key == '' {
			return
		}
		if selected_task.frame.event == 'open' {
		}
		mut preferred_lane_id := ''
		mut state_lane := e.state
		state_lane.mu.@lock()
		if !selected_task.actor_serialized {
			preferred_lane_id = state_lane.websocket_affinity_lane_by_key[selected_key] or { '' }
		}
		state_lane.mu.unlock()
		lane := if preferred_lane_id != '' {
			e.acquire_lane_by_id(preferred_lane_id, inproc_vjsx_lane_wait_timeout_ms) or {
				mut state_retry := e.state
				state_retry.mu.@lock()
				queue := state_retry.websocket_mailbox_by_key[selected_key] or {
					[]InProcVjsxWebSocketTask{}
				}
				mut restored := [selected_task]
				restored << queue
				state_retry.websocket_mailbox_by_key[selected_key] = restored
				if selected_key !in state_retry.websocket_mailbox_pending_keys {
					state_retry.websocket_mailbox_pending_keys << selected_key
				}
				state_retry.websocket_mailbox_running_by_key.delete(selected_key)
				state_retry.mu.unlock()
				return
			}
		} else {
			e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms) or {
				mut state_retry := e.state
				state_retry.mu.@lock()
				queue := state_retry.websocket_mailbox_by_key[selected_key] or {
					[]InProcVjsxWebSocketTask{}
				}
				mut restored := [selected_task]
				restored << queue
				state_retry.websocket_mailbox_by_key[selected_key] = restored
				if selected_key !in state_retry.websocket_mailbox_pending_keys {
					state_retry.websocket_mailbox_pending_keys << selected_key
				}
				state_retry.websocket_mailbox_running_by_key.delete(selected_key)
				state_retry.mu.unlock()
				return
			}
		}
		selected_lane_id = lane.id
		e.bind_websocket_task_lane(selected_task, selected_lane_id)
		e.dispatch_websocket_task_to_lane(selected_task, selected_lane_id) or {
			e.release_lane(selected_lane_id)
			mut state_retry := e.state
			state_retry.mu.@lock()
			queue := state_retry.websocket_mailbox_by_key[selected_key] or {
				[]InProcVjsxWebSocketTask{}
			}
			mut restored := [selected_task]
			restored << queue
			state_retry.websocket_mailbox_by_key[selected_key] = restored
			if selected_key !in state_retry.websocket_mailbox_pending_keys {
				state_retry.websocket_mailbox_pending_keys << selected_key
			}
			state_retry.websocket_mailbox_running_by_key.delete(selected_key)
			state_retry.mu.unlock()
			return
		}
	}
}

fn (e InProcVjsxExecutor) enqueue_websocket_mailbox_task(task InProcVjsxWebSocketTask) {
	if isnil(e.state) {
		return
	}
	key := if task.actor_serialized {
		task.actor_key.trim_space()
	} else {
		task.affinity_key.trim_space()
	}
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	mut queue := state.websocket_mailbox_by_key[key] or { []InProcVjsxWebSocketTask{} }
	queue << task
	state.websocket_mailbox_by_key[key] = queue
	if key !in state.websocket_mailbox_pending_keys {
		state.websocket_mailbox_pending_keys << key
	}
	state.mu.unlock()
	e.try_schedule_websocket_mailboxes()
}

fn (e InProcVjsxExecutor) finish_websocket_mailbox_task(affinity_key string) {
	if isnil(e.state) {
		return
	}
	key := affinity_key.trim_space()
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_mailbox_running_by_key.delete(key)
	state.mu.unlock()
	e.try_schedule_websocket_mailboxes()
}

fn (e InProcVjsxExecutor) request_lane_snapshot(mut app App, lane VjsxExecutionLane) !string {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneSnapshotTaskSlot{}
	worker.snapshot_tasks <- InProcVjsxLaneSnapshotTask{
		app:  app
		slot: slot
		done: done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_snapshot_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_snapshot_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
	return result.raw
}

fn (e InProcVjsxExecutor) request_lane_warmup(mut app App, lane VjsxExecutionLane) ! {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneWarmupTaskSlot{}
	log.debug('[vhttpd] warmup enqueue lane=${lane.id}')
	worker.warmup_tasks <- InProcVjsxLaneWarmupTask{
		app:  unsafe { &app }
		slot: slot
		done: done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_warmup_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_warmup_not_ready')
	}
	log.debug('[vhttpd] warmup reply lane=${lane.id} ok=${result.ok} error=${result.error}')
	if !result.ok {
		return error(result.error)
	}
}

fn (e InProcVjsxExecutor) request_lane_pump(lane VjsxExecutionLane) ! {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLanePumpTaskSlot{}
	worker.pump_tasks <- InProcVjsxLanePumpTask{
		slot: slot
		done: done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_pump_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_pump_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
}

fn inproc_vjsx_lane_worker_loop(state &VjsxExecutorState, lane_id string, task_ch chan InProcVjsxWebSocketTask, snapshot_ch chan InProcVjsxLaneSnapshotTask, warmup_ch chan InProcVjsxLaneWarmupTask, pump_ch chan InProcVjsxLanePumpTask, affinity_ch chan InProcVjsxLaneAffinityTask, stop_ch chan bool) {
	worker_executor := InProcVjsxExecutor{
		state: state
	}
	for {
		select {
			_ := <-stop_ch {
				return
			}
			mut task := <-task_ch {
				mut response_json := ''
				mut err_msg := ''
				mut task_app := task.app
				defer {
					if task.actor_serialized {
						worker_executor.finish_websocket_mailbox_task(task.actor_key)
					} else if websocket_should_pin_affinity_lane(task.frame, task.affinity_key) {
						worker_executor.finish_websocket_mailbox_task(task.affinity_key)
					}
					worker_executor.release_lane(lane_id)
				}
				task.started <- true
				if task.frame.event == 'open' {
				}
				log.debug('[vhttpd] lane worker recv lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id}')
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					err_msg = inproc_vjsx_normalize_error_message(err.msg(),
						'inproc_vjsx_executor_lane_not_found')
					log.debug('[vhttpd] lane worker reply_error lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} error=${err_msg}')
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxWebSocketTaskResult{
						ok:    false
						error: err_msg
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				response_json = worker_executor.dispatch_websocket_callback_on_lane(mut task_app,
					task.frame, lane) or {
					err_msg = inproc_vjsx_normalize_error_message(err.msg(),
						'inproc_vjsx_executor_websocket_dispatch_failed')
					eprintln('[vhttpd] websocket lane worker error lane=${lane_id} event=${task.frame.event} path=${task.frame.path} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id} query=${task.frame.query} error=${err_msg}')
					log.debug('[vhttpd] lane worker reply_error lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} error=${err_msg}')
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxWebSocketTaskResult{
						ok:    false
						error: err_msg
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				log.debug('[vhttpd] lane worker reply_ok lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} response_len=${response_json.len}')
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxWebSocketTaskResult{
					ok:            true
					response_json: response_json
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-snapshot_ch {
				mut task_app := task.app
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneSnapshotTaskResult{
						ok:    false
						error: inproc_vjsx_normalize_error_message(err.msg(),
							'inproc_vjsx_executor_lane_not_found')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				idx := worker_executor.lane_index_by_id(lane.id)
				if idx < 0 {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneSnapshotTaskResult{
						ok:    false
						error: 'inproc_vjsx_executor_lane_not_found'
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				raw := worker_executor.execute_snapshot_hook(mut task_app, idx, lane) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneSnapshotTaskResult{
						ok:    false
						error: inproc_vjsx_normalize_error_message(err.msg(),
							'inproc_vjsx_executor_snapshot_failed')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLaneSnapshotTaskResult{
					ok:  true
					raw: raw
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-warmup_ch {
				mut task_app := task.app
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: inproc_vjsx_normalize_error_message(err.msg(),
							'inproc_vjsx_executor_lane_not_found')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				idx := worker_executor.lane_index_by_id(lane.id)
				log.debug('[vhttpd] lane warmup begin lane=${lane.id} idx=${idx}')
				if idx < 0 {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: 'inproc_vjsx_executor_lane_not_found'
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				worker_executor.ensure_lane_host(idx) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: inproc_vjsx_normalize_error_message(err.msg(),
							'inproc_vjsx_executor_warmup_host_failed')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				worker_executor.run_startup_hooks(mut task_app, idx, lane) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: inproc_vjsx_normalize_error_message(err.msg(),
							'inproc_vjsx_executor_warmup_startup_failed')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				log.debug('[vhttpd] lane warmup done lane=${lane.id} idx=${idx}')
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLaneWarmupTaskResult{
					ok: true
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-pump_ch {
				idx := worker_executor.lane_index_by_id(lane_id)
				if idx < 0 {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLanePumpTaskResult{
						ok:    false
						error: 'inproc_vjsx_executor_lane_not_found'
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				mut state_pump := worker_executor.state
				state_pump.mu.@lock()
				host := state_pump.hosts[idx]
				state_pump.mu.unlock()
				host.pump_until_idle()
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLanePumpTaskResult{
					ok: true
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-affinity_ch {
				mut task_app := task.app
				defer {
					worker_executor.release_lane(lane_id)
				}
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneAffinityTaskResult{
						ok:    false
						error: inproc_vjsx_normalize_error_message(err.msg(),
							'inproc_vjsx_executor_lane_not_found')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				mut affinity_decision := WebSocketAffinityDecision{}
				mut actor_decision := WebSocketActorDecision{}
				if task.kind == 'actor' {
					actor_decision = worker_executor.resolve_websocket_actor_on_lane(mut task_app,
						task.frame, lane) or {
						task.slot.mu.@lock()
						task.slot.result = InProcVjsxLaneAffinityTaskResult{
							ok:    false
							error: inproc_vjsx_normalize_error_message(err.msg(),
								'inproc_vjsx_executor_websocket_actor_failed')
						}
						task.slot.ready = true
						task.slot.mu.unlock()
						task.done <- true
						continue
					}
				} else {
					affinity_decision = worker_executor.resolve_websocket_affinity_on_lane(mut task_app,
						task.frame, lane) or {
						task.slot.mu.@lock()
						task.slot.result = InProcVjsxLaneAffinityTaskResult{
							ok:    false
							error: inproc_vjsx_normalize_error_message(err.msg(),
								'inproc_vjsx_executor_websocket_affinity_failed')
						}
						task.slot.ready = true
						task.slot.mu.unlock()
						task.done <- true
						continue
					}
				}
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLaneAffinityTaskResult{
					ok:    true
					value: affinity_decision
					actor: actor_decision
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
		}
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
	facade_source := inproc_vjsx_http_facade_source.to_string()
	eval_res := ctx.eval(facade_source) or {
		eprintln('[vhttpd] ERROR: js_bootstrap eval failed: ${err.msg()}')
		return err
	}
	defer { eval_res.free() }

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

fn inproc_vjsx_host_snapshot_builder(state_ptr &VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	mut state := unsafe { state_ptr }
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = args
			mut app_ref := &App(unsafe { nil })
			mut lane_id := ''
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
				lane_id = state.hosts[idx].request_ctx.lane_id
			}
			if isnil(app_ref) && !isnil(state.app_ref) {
				app_ref = state.app_ref
			}
			if lane_id == '' && idx >= 0 && idx < state.lanes.len {
				lane_id = state.lanes[idx].id
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_undefined()
			}
			mut app := app_ref
			mut req := InProcVjsxHostSnapshotRequest{
				scope: 'lane'
				kind:  'runtime'
			}
			if args.len > 0 {
				raw := if args[0].is_string() {
					args[0].to_string().trim_space()
				} else {
					args[0].json_stringify().trim_space()
				}
				if raw != '' && raw != 'undefined' && raw != 'null' {
					req = json.decode(InProcVjsxHostSnapshotRequest, raw) or { req }
				}
			}
			if req.kind == 'app' {
				executor := InProcVjsxExecutor{
					state: state
				}
				if req.scope == 'all_lanes' {
					raw := executor.aggregate_app_lane_snapshots(mut app, lane_id, true)
					if raw.trim_space() == '' {
						return ctx.js_undefined()
					}
					return ctx.js_string(raw)
				}
				if req.scope == 'other_lanes' {
					raw := executor.aggregate_app_lane_snapshots(mut app, lane_id, false)
					if raw.trim_space() == '' {
						return ctx.js_undefined()
					}
					return ctx.js_string(raw)
				}
				if lane_id == '' {
					return ctx.js_undefined()
				}
				lane := executor.lane_snapshot_by_id(lane_id) or { return ctx.js_undefined() }
				raw := executor.execute_snapshot_hook(mut app, executor.lane_index_by_id(lane.id), lane) or {
					return ctx.js_undefined()
				}
				if raw.trim_space() == '' || raw.trim_space() == 'undefined'
					|| raw.trim_space() == 'null' {
					return ctx.js_undefined()
				}
				return ctx.js_string(raw)
			}
			if req.scope == 'all_lanes' {
				executor := InProcVjsxExecutor{
					state: state
				}
				raw := executor.aggregate_runtime_lane_snapshots(mut app, lane_id)
				return ctx.js_string(raw)
			}
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

fn inproc_vjsx_host_session_store_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	_ = idx
	return fn [mut state] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'missing_session_store_request'
				}))
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'missing_session_store_request'
				}))
			}
			req := json.decode(InProcVjsxHostSessionStoreRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'invalid_session_store_request'
				}))
			}
			namespace := req.namespace.trim_space()
			key := req.key.trim_space()
			if namespace == '' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'session_store_namespace_missing'
				}))
			}
			if key == '' && req.op != 'keys' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'session_store_key_missing'
				}))
			}
			full_key := '${namespace}:${key}'
			return match req.op {
				'get' {
					value := state.session_store.get(full_key) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							ok:    true
							found: false
						}))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: true
						value: value
					}))
				}
				'set' {
					if req.ttl_ms > 0 {
						state.session_store.set_with_ttl(full_key, req.value,
							req.ttl_ms * time.millisecond) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					} else {
						state.session_store.set(full_key, req.value) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}))
				}
				'patch' {
					mut swapped := false
					if req.delete_value {
						swapped = state.session_store.compare_and_swap_delete(full_key,
							req.expected_found, req.expected_value) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					} else {
						swapped = state.session_store.compare_and_swap_set_with_ttl(full_key,
							req.expected_found, req.expected_value, req.value,
							req.ttl_ms * time.millisecond) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					}
					if !swapped {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							ok:       false
							conflict: true
						}))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}))
				}
				'delete' {
					state.session_store.delete(full_key) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							error: err.msg()
						}))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}))
				}
				'exists' {
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: state.session_store.exists(full_key)
					}))
				}
				'keys' {
					prefix := '${namespace}:'
					keys :=
						state.session_store.keys().filter(it.starts_with(prefix)).map(it[prefix.len..])
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: keys.len > 0
						value: json.encode(keys)
					}))
				}
				else {
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						error: 'unsupported_session_store_op:${req.op}'
					}))
				}
			}
		})
	}
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
				event_type:      if req.event_type.trim_space() != '' {
					req.event_type
				} else {
					summary.event_type
				}
				message_id:      if req.message_id.trim_space() != '' {
					req.message_id
				} else {
					summary.message_id
				}
				target:          if req.target.trim_space() != '' {
					req.target
				} else {
					summary.target
				}
				target_type:     if req.target_type.trim_space() != '' {
					req.target_type
				} else {
					summary.target_type
				}
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
					close_target_id: if result.close_frame.target_id != '' {
						result.close_frame.target_id
					} else {
						result.close_frame.id
					}
					failures:        result.failures
				}))
			}
			return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
				ok:       true
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
		value: inproc_vjsx_host_snapshot_builder(state, idx)
	}, vjsx.HostObjectField{
		name:  'sessionStore'
		value: inproc_vjsx_host_session_store_builder(mut state, idx)
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
		'websocket_affinity' {
			['websocket_affinity', 'websocketAffinity', 'getWebSocketAffinity',
				'get_websocket_affinity']
		}
		'websocket_actor' {
			['websocket_actor', 'websocketActor', 'getWebSocketActor', 'get_websocket_actor']
		}
		'websocket_upstream' {
			['websocket_upstream', 'websocketUpstream', 'handleWebSocketUpstream',
				'handle_websocket_upstream']
		}
		'plugin' {
			['plugin', 'handlePlugin', 'handle_plugin']
		}
		'openai' {
			['openai', 'openaiPlugin', 'handleOpenAI', 'handleOpenai', 'handle_openai']
		}
		'startup' {
			['startup', 'lane_startup', 'laneStartup']
		}
		'app_startup' {
			['app_startup', 'appStartup']
		}
		'snapshot' {
			['snapshot', 'lane_snapshot', 'laneSnapshot']
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
		'websocket_affinity' { '__vhttpd_websocket_affinity_handle' }
		'websocket_actor' { '__vhttpd_websocket_actor_handle' }
		'websocket_upstream' { '__vhttpd_websocket_upstream_handle' }
		'plugin' { '__vhttpd_plugin_handle' }
		'openai' { '__vhttpd_openai_handle' }
		'startup' { '__vhttpd_startup_handle' }
		'app_startup' { '__vhttpd_app_startup_handle' }
		'snapshot' { '__vhttpd_snapshot_handle' }
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

// VjsxLaneHost facade: thin host-side wrapper around the lane session. Keep
// executor call sites on host methods rather than long free-function chains.
fn (host VjsxLaneHost) context() &vjsx.Context {
	if isnil(host.session) {
		panic('inproc_vjsx_executor_session_missing')
	}
	return host.session.context()
}

// Resolve helpers
fn (host VjsxLaneHost) resolve_value(val vjsx.Value) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	return host.session.resolve_value(val)
}

fn (host VjsxLaneHost) pump_until_idle() {
	if isnil(host.session) || host.session.is_closed() {
		return
	}
	host.session.pump_until_idle()
}

// Direct handler invocation helpers
fn (host VjsxLaneHost) call_handler(handler vjsx.Value, args ...vjsx.AnyValue) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	return host.session.call(handler, ...args)
}

fn (host VjsxLaneHost) call_handler_resolved(handler vjsx.Value, args ...vjsx.AnyValue) !vjsx.Value {
	result := host.call_handler(handler, ...args)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}

fn (host VjsxLaneHost) call_global(name string, args ...vjsx.AnyValue) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	return host.session.call_global(name, ...args)
}

fn (host VjsxLaneHost) call_global_resolved(name string, args ...vjsx.AnyValue) !vjsx.Value {
	result := host.call_global(name, ...args)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}

// Entry lookup helpers
fn (host VjsxLaneHost) call_global_entry(kind string, arg vjsx.Value) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	ctx := host.context()
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
	return host.session.call(handler, arg)
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

fn (host VjsxLaneHost) call_module_entry(kind string, arg vjsx.Value) !vjsx.Value {
	if isnil(host.module_binding) {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	module_binding := host.module_binding
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

// Unified entry facade with module -> global fallback
fn (host VjsxLaneHost) call_entry(kind string, arg vjsx.Value) !vjsx.Value {
	if host.is_module_entry && !isnil(host.module_binding) {
		return host.call_module_entry(kind, arg) or {
			if err.msg() != 'inproc_vjsx_executor_missing_${kind}_handler' {
				return err
			}
			return host.call_global_entry(kind, arg)
		}
	}
	return host.call_global_entry(kind, arg)
}

fn (host VjsxLaneHost) call_entry_resolved(kind string, arg vjsx.Value) !vjsx.Value {
	result := host.call_entry(kind, arg)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
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
	lane_id := if idx < state.lanes.len { state.lanes[idx].id } else { '' }
	if lane_id != '' {
		state.lane_wakeup_by_id.delete(lane_id)
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
	for i in 0 .. state.lane_workers.len {
		if state.lane_workers[i].started {
			state.lane_workers[i].stop_ch <- true
			state.lane_workers[i].started = false
		}
	}
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
	state.lane_wakeup_by_id = map[string]VjsxLaneWakeup{}
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

fn inproc_vjsx_runtime_profile_kind_name(kind vjsx.RuntimeProfileKind) string {
	return match kind {
		.unknown { 'unknown' }
		.runtime_minimal { 'runtime_minimal' }
		.script { 'script' }
		.node_minimal { 'node_minimal' }
		.node { 'node' }
	}
}

fn inproc_vjsx_log_runtime_profile(lane_id string, idx int, runtime_profile string, ctx &vjsx.Context) {
	snapshot := vjsx.runtime_profile_snapshot(ctx)
	kind := snapshot.infer_kind()
	expected_kind := match runtime_profile {
		'', 'script' { vjsx.RuntimeProfileKind.script }
		'node' { vjsx.RuntimeProfileKind.node }
		else { vjsx.RuntimeProfileKind.unknown }
	}

	missing := if expected_kind == .unknown {
		[]string{}
	} else {
		snapshot.missing_for(expected_kind)
	}
	log.debug('[vhttpd] vjsx runtime profile lane=${lane_id} idx=${idx} configured=${runtime_profile} inferred=${inproc_vjsx_runtime_profile_kind_name(kind)} expected=${inproc_vjsx_runtime_profile_kind_name(expected_kind)} missing=${missing.join(',')} modules=${ctx.runtime_modules().join(',')}')
}

fn inproc_vjsx_log_runtime_diagnostic(diagnostic vjsx.RuntimeSessionDiagnostic) {
	log.warn('[vhttpd] vjsx runtime diagnostic session=${diagnostic.session_id} kind=${diagnostic.kind} generation=${diagnostic.wakeup_generation} at_ms=${diagnostic.at_ms} message=${diagnostic.message}')
}

fn (e InProcVjsxExecutor) ensure_lane_host(idx int) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := e.facade_snapshot().config
	source_signature := e.current_source_signature()
	mut needs_reset := false
	lane_id := if idx >= 0 && idx < state.lanes.len { state.lanes[idx].id } else { '' }
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
	log.debug('[vhttpd] ensure_lane_host start lane=${lane_id} idx=${idx} needs_reset=${needs_reset} app_entry=${config.app_entry}')
	if needs_reset {
		log.debug('[vhttpd] ensure_lane_host resetting lane=${lane_id} idx=${idx}')
		e.reset_lane_host(idx)
	}

	as_module := vjsx_entry_runs_as_module(config.app_entry)!
	temp_root := vjsx_lane_temp_root_for_signature(config, idx, source_signature)
	mut session := inproc_vjsx_new_runtime_session_ptr(config)!
	session.set_diagnostic_handler(inproc_vjsx_log_runtime_diagnostic)
	session.configure_event_loop(vjsx.RuntimeSessionEventLoopConfig{
		session_id:     lane_id
		wake_fn:        fn [mut state, lane_id] (req vjsx.RuntimeSessionWakeRequest) {
			state.schedule_lane_wakeup(lane_id, req.wake_at_ms, req.generation)
		}
		cancel_wake_fn: fn [mut state, lane_id] (req vjsx.RuntimeSessionWakeCancelRequest) {
			state.cancel_lane_wakeup(lane_id, req.generation)
		}
	})
	log.debug('[vhttpd] ensure_lane_host runtime ready lane=${lane_id} idx=${idx} module=${as_module} temp_root=${temp_root}')
	mut ctx := session.context()
	install_inproc_http_facade(mut ctx)!
	install_inproc_host_api(mut ctx, mut state, idx)
	inproc_vjsx_log_runtime_profile(lane_id, idx, config.runtime_profile, ctx)
	mut module_binding_ptr := &vjsx.ScriptModule(unsafe { nil })
	mut has_http_handler := false
	mut has_websocket_handler := false
	mut has_upstream_handler := false
	mut has_plugin_handler := false
	if as_module {
		if vjsx.is_typescript_file(config.app_entry)
			|| vjsx.is_runtime_module_file(config.app_entry) {
			runtimejs.install_typescript_runtime(ctx)!
		}
		log.debug('[vhttpd] ensure_lane_host importing module lane=${lane_id} idx=${idx}')
		module_entry_path := runtimejs.build_runtime_module_entry(ctx, config.app_entry, true,
			temp_root) or {
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
		has_plugin_handler = inproc_vjsx_module_has_callable(&module_binding_value, 'plugin')
			|| inproc_vjsx_module_has_callable(&module_binding_value, 'openai')
			|| inproc_vjsx_global_has_callable(ctx, 'plugin')
			|| inproc_vjsx_global_has_callable(ctx, 'openai')
		if !has_http_handler && !has_websocket_handler && !has_upstream_handler
			&& !has_plugin_handler {
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
			mut bound := session.call(bind_handlers, entry_exports) or {
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
		log.debug('[vhttpd] ensure_lane_host loading script entry lane=${lane_id} idx=${idx}')
		mut entry_exports := load_inproc_vjsx_entry(mut ctx, config, idx, source_signature, false) or {
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
			mut bound := session.call(bind_handlers, entry_exports) or {
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
		plugin_handler := ctx.js_global('__vhttpd_plugin_handle')
		openai_handler := ctx.js_global('__vhttpd_openai_handle')
		has_http_handler = !http_handler.is_undefined() && http_handler.is_function()
		has_websocket_handler = !websocket_handler.is_undefined() && websocket_handler.is_function()
		has_upstream_handler = !upstream_handler.is_undefined() && upstream_handler.is_function()
		has_plugin_handler = (!plugin_handler.is_undefined() && plugin_handler.is_function())
			|| (!openai_handler.is_undefined() && openai_handler.is_function())
		http_handler.free()
		websocket_handler.free()
		upstream_handler.free()
		plugin_handler.free()
		openai_handler.free()
		if !has_http_handler && !has_websocket_handler && !has_upstream_handler
			&& !has_plugin_handler {
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
	log.debug('[vhttpd] ensure_lane_host ready lane=${lane_id} idx=${idx} http=${has_http_handler} websocket=${has_websocket_handler} upstream=${has_upstream_handler} plugin=${has_plugin_handler}')
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

fn (e InProcVjsxExecutor) pump_all_lane_sessions() ! {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.mu.@lock()
	lanes := state.lanes.clone()
	state.mu.unlock()
	// WebSocket timers still live inside each lane-owned QuickJS session. Hosts
	// must explicitly pump them from the lane worker thread instead of touching
	// RuntimeSession from the caller thread.
	for lane in lanes {
		e.request_lane_pump(lane)!
	}
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

fn (e InProcVjsxExecutor) build_snapshot_runtime_payload(lane VjsxExecutionLane) string {
	config := e.facade_snapshot().config
	return json.encode(InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'snapshot'
		lane_id:                  lane.id
		request_id:               'snapshot_${lane.id}'
		trace_id:                 'snapshot_${lane.id}'
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
		request_target:           '/.well-known/vhttpd/snapshot'
		request_protocol_version: ''
		request_remote_addr:      ''
		request_server:           map[string]string{}
		method:                   'SNAPSHOT'
		path:                     '/.well-known/vhttpd/snapshot'
	})
}

fn inproc_vjsx_json_or_null(raw string) string {
	trimmed := raw.trim_space()
	if trimmed == '' || trimmed == 'undefined' {
		return 'null'
	}
	return trimmed
}

fn inproc_vjsx_aggregated_snapshot_item_json(lane_id string, available bool, snapshot_raw string, err_msg string) string {
	return '{"laneId":${json.encode(lane_id)},"available":${if available {
		'true'
	} else {
		'false'
	}},"snapshot":${inproc_vjsx_json_or_null(snapshot_raw)},"error":${json.encode(err_msg)}}'
}

fn inproc_vjsx_aggregated_snapshot_json(scope string, kind string, current_lane_id string, item_jsons []string) string {
	return '{"scope":${json.encode(scope)},"kind":${json.encode(kind)},"currentLaneId":${json.encode(current_lane_id)},"lanes":[${item_jsons.join(',')}]}'
}

fn (e InProcVjsxExecutor) execute_snapshot_hook(mut app App, idx int, lane VjsxExecutionLane) !string {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	e.ensure_lane_host(idx)!
	e.run_app_startup(mut app, idx, lane)!
	request_id := 'snapshot_${lane.id}'
	e.activate_lane_request_context(idx, mut app, lane.id, HttpLogicDispatchRequest{
		method:     'SNAPSHOT'
		path:       '/.well-known/vhttpd/snapshot'
		trace_id:   request_id
		request_id: request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	host := state.hosts[idx]
	state.mu.unlock()
	js_ctx_host := host.context()
	runtime_obj := js_ctx_host.json_parse(e.build_snapshot_runtime_payload(lane))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := js_ctx_host.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	mut js_runtime := js_ctx_host.call(create_runtime_fn, runtime_obj) or {
		return error('inproc_vjsx_executor_snapshot_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	mut result := if host.is_module_entry && !isnil(host.module_binding) {
		host.call_entry_resolved('snapshot', js_runtime) or {
			if err.msg() != 'inproc_vjsx_executor_missing_snapshot_handler' {
				return error('inproc_vjsx_executor_snapshot_failed:${err.msg()}')
			}
			return ''
		}
	} else {
		hook := js_ctx_host.js_global('__vhttpd_snapshot_handle')
		defer {
			hook.free()
		}
		if hook.is_undefined() || !hook.is_function() {
			return ''
		}
		host.call_handler_resolved(hook, js_runtime) or {
			return error('inproc_vjsx_executor_snapshot_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	raw := result.json_stringify().trim_space()
	if raw == '' || raw == 'undefined' || raw == 'null' {
		return ''
	}
	return raw
}

fn (e InProcVjsxExecutor) aggregate_runtime_lane_snapshots(mut app App, current_lane_id string) string {
	if isnil(e.state) {
		return inproc_vjsx_aggregated_snapshot_json('all_lanes', 'runtime', current_lane_id,
			[]string{})
	}
	mut state := e.state
	state.mu.@lock()
	lanes := state.lanes.clone()
	state.mu.unlock()
	mut items := []string{}
	for lane in lanes {
		items << inproc_vjsx_aggregated_snapshot_item_json(lane.id, true,
			json.encode(app.admin_runtime_snapshot()), '')
	}
	return inproc_vjsx_aggregated_snapshot_json('all_lanes', 'runtime', current_lane_id, items)
}

fn (e InProcVjsxExecutor) aggregate_app_lane_snapshots(mut app App, current_lane_id string, include_current bool) string {
	scope := if include_current { 'all_lanes' } else { 'other_lanes' }
	if isnil(e.state) {
		return inproc_vjsx_aggregated_snapshot_json(scope, 'app', current_lane_id, []string{})
	}
	mut state := e.state
	state.mu.@lock()
	lanes := state.lanes.clone()
	state.mu.unlock()
	mut items := []string{}
	for lane in lanes {
		if !include_current && lane.id == current_lane_id {
			continue
		}
		idx := e.lane_index_by_id(lane.id)
		if idx < 0 {
			items << inproc_vjsx_aggregated_snapshot_item_json(lane.id, false, '', 'lane_not_found')
			continue
		}
		lane_snapshot := e.request_lane_snapshot(mut app, lane) or {
			items << inproc_vjsx_aggregated_snapshot_item_json(lane.id, false, '', err.msg())
			continue
		}
		if lane_snapshot.trim_space() == '' {
			items << inproc_vjsx_aggregated_snapshot_item_json(lane.id, false, '', '')
			continue
		}
		items << inproc_vjsx_aggregated_snapshot_item_json(lane.id, true, lane_snapshot, '')
	}
	return inproc_vjsx_aggregated_snapshot_json(scope, 'app', current_lane_id, items)
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
		raw:     frame
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
	minimal_runtime := os.getenv('VHTTPD_VJSX_WS_MINIMAL_RUNTIME').trim_space().to_lower() in [
		'1',
		'true',
		'yes',
		'on',
	]
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
	request.set('server', websocket_js_value_from_json(ctx,
		json.encode(runtime_meta.request_server)))
	runtime.set('request', request)
	runtime.set('method', runtime_meta.method)
	runtime.set('path', runtime_meta.path)
	runtime.set('runtimeInitError', '')
	if minimal_runtime {
		return runtime
	}
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
	runtime.set('sessionStore', ctx.js_function(fn [ctx] (args []vjsx.Value) vjsx.Value {
		namespace := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		mut store := ctx.js_object()
		store.set('namespace', namespace)
		store.set('get', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
			if namespace == '' {
				return fallback
			}
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if host_api.is_undefined() || !host_api.is_object() || !host_api.has('sessionStore') {
				return fallback
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return fallback
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'get'
				key:       key
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return fallback }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return fallback
			}
			if !resp.ok || !resp.found || resp.value.trim_space() == '' {
				return fallback
			}
			return ctx.json_parse(resp.value)
		}))
		store.set('set', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			if namespace == '' || args.len == 0 {
				return ctx.js_bool(false)
			}
			key := args[0].to_string().trim_space()
			value := if args.len > 1 { args[1].json_stringify() } else { 'null' }
			mut ttl_ms := i64(0)
			if args.len > 2 && args[2].is_object() && args[2].has('ttlMs') {
				ttl_ms = args[2].get('ttlMs').to_i64()
			}
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if host_api.is_undefined() || !host_api.is_object() || !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'set'
				key:       key
				value:     value
				ttl_ms:    ttl_ms
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok)
		}))
		store.set('delete', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'delete'
				key:       key
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok)
		}))
		store.set('exists', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'exists'
				key:       key
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok && resp.found)
		}))
		store.set('keys', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			fallback := if args.len > 0 { args[0].dup_value() } else { ctx.js_array() }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return fallback
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return fallback
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'keys'
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return fallback }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return fallback
			}
			if !resp.ok || resp.value.trim_space() == '' {
				return fallback
			}
			return ctx.json_parse(resp.value)
		}))
		return store
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
		req := json.decode(InProcVjsxHostWebSocketDispatchRequest, req_raw) or { return fallback }
		result := app.execute_websocket_dispatch_commands_result(req.commands)
		response := if result.has_close {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:              true
				has_close:       true
				close_code:      result.close_frame.code
				close_reason:    result.close_frame.reason
				close_target_id: if result.close_frame.target_id != '' {
					result.close_frame.target_id
				} else {
					result.close_frame.id
				}
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
	accepted     bool
	closed       bool
	commands     []WorkerWebSocketFrame
	affinity_key string @[json: 'affinity_key']
	error        string
	error_class  string @[json: 'error_class']
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

fn websocket_response_from_json(raw string, frame WorkerWebSocketFrame) WorkerWebSocketDispatchResponse {
	if frame.event in ['open', 'message'] {
		log.debug('[vhttpd] websocket_response decode_begin event=${frame.event} request_id=${frame.request_id} raw_len=${raw.len}')
		if frame.event == 'open' {
			log.debug('[vhttpd] websocket_response decode_raw event=${frame.event} request_id=${frame.request_id} raw=${raw}')
		}
	}
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
	if frame.event in ['open', 'message'] {
		log.debug('[vhttpd] websocket_response decode_done event=${frame.event} request_id=${frame.request_id} accepted=${normalized.accepted} closed=${normalized.closed} commands=${normalized.commands.len} affinity_key=${normalized.affinity_key} error=${normalized.error} error_class=${normalized.error_class}')
	}
	return WorkerWebSocketDispatchResponse{
		mode:         'websocket_dispatch'
		event:        'result'
		id:           frame.id
		accepted:     normalized.accepted
		closed:       normalized.closed
		commands:     normalized.commands
		affinity_key: normalized.affinity_key
		error:        normalized.error
		error_class:  normalized.error_class
	}
}

fn inproc_vjsx_websocket_handler_missing_result(frame WorkerWebSocketFrame) string {
	return json.encode(WorkerWebSocketDispatchResponse{
		mode:     'websocket_dispatch'
		event:    'result'
		id:       frame.id
		accepted: false
		closed:   false
		commands: []WorkerWebSocketFrame{}
	})
}

struct InProcVjsxWebSocketCallbackContext {
	idx        int
	lane_id    string
	frame      WorkerWebSocketFrame
	ctx        &vjsx.Context
	js_runtime vjsx.Value
	js_frame   vjsx.Value
}

struct InProcVjsxWebSocketCallbackInput {
	request_ctx  HttpLogicDispatchRequest
	runtime_meta InProcVjsxRuntimeMeta
	frame        WorkerWebSocketFrame
}

fn (mut c InProcVjsxWebSocketCallbackContext) free() {
	c.js_frame.free()
	c.js_runtime.free()
}

fn (e InProcVjsxExecutor) websocket_callback_input(lane VjsxExecutionLane, frame WorkerWebSocketFrame) InProcVjsxWebSocketCallbackInput {
	return InProcVjsxWebSocketCallbackInput{
		request_ctx:  HttpLogicDispatchRequest{
			method:     frame.event
			path:       frame.path
			trace_id:   frame.trace_id
			request_id: frame.request_id
		}
		runtime_meta: e.websocket_runtime_meta(lane, frame)
		frame:        frame
	}
}

fn build_websocket_callback_payload(ctx &vjsx.Context, input InProcVjsxWebSocketCallbackInput, runtime_config_json string, mut app App) (vjsx.Value, vjsx.Value) {
	mut js_runtime :=
		build_websocket_js_runtime(ctx, input.runtime_meta, runtime_config_json, mut app)
	create_frame_fn := ctx.js_global('__vhttpd_create_websocket_frame')
	defer {
		create_frame_fn.free()
	}
	if create_frame_fn.is_function() {
		bundle_obj := ctx.json_parse(json.encode(InProcVjsxWebSocketFrameBundle{
			raw:     input.frame
			runtime: input.runtime_meta
		}))
		defer {
			bundle_obj.free()
		}
		mut js_frame := ctx.call(create_frame_fn, bundle_obj) or {
			build_websocket_js_frame(ctx, input.frame, js_runtime)
		}
		return js_runtime, js_frame
	}
	mut js_frame := build_websocket_js_frame(ctx, input.frame, js_runtime)
	return js_runtime, js_frame
}

fn (e InProcVjsxExecutor) prepare_websocket_callback_on_lane(mut app App, frame WorkerWebSocketFrame, lane VjsxExecutionLane) !InProcVjsxWebSocketCallbackContext {
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
	callback_input := e.websocket_callback_input(lane, frame)
	e.activate_lane_request_context(idx, mut app, lane.id, callback_input.request_ctx)
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.context()
	log.debug('[vhttpd] websocket_on_lane runtime_build lane=${lane.id} idx=${idx} event=${frame.event}')
	log.debug('[vhttpd] websocket_on_lane frame_build lane=${lane.id} idx=${idx} event=${frame.event}')
	mut js_runtime, mut js_frame := build_websocket_callback_payload(ctx, callback_input,
		app.runtime_config_json, mut app)
	return InProcVjsxWebSocketCallbackContext{
		idx:        idx
		lane_id:    lane.id
		frame:      frame
		ctx:        ctx
		js_runtime: js_runtime
		js_frame:   js_frame
	}
}

fn inproc_vjsx_invoke_websocket_callback(host VjsxLaneHost, ctx &vjsx.Context, js_frame vjsx.Value, lane VjsxExecutionLane, idx int, frame WorkerWebSocketFrame) !vjsx.Value {
	handler := ctx.js_global('__vhttpd_websocket_handle')
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		return error('inproc_vjsx_executor_missing_websocket_handler')
	}
	invoke_handler := ctx.js_global('__vhttpd_invoke_websocket_handle')
	defer {
		invoke_handler.free()
	}
	if !invoke_handler.is_function() {
		return error('inproc_vjsx_executor_websocket_invoker_missing')
	}
	log.debug('[vhttpd] websocket_on_lane invoke lane=${lane.id} idx=${idx} event=${frame.event}')
	invoke_arg := js_frame.dup_value()
	defer {
		invoke_arg.free()
	}
	mut result := host.call_handler(invoke_handler, invoke_arg) or {
		err_msg := inproc_vjsx_context_error_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_handler_failed')
		return error(err_msg)
	}
	if result.is_exception() {
		result.free()
		err_msg := inproc_vjsx_context_error_message(ctx, 'exception',
			'inproc_vjsx_executor_websocket_handler_failed')
		return error(err_msg)
	}
	return result
}

fn inproc_vjsx_normalize_websocket_callback_result(host VjsxLaneHost, ctx &vjsx.Context, js_frame vjsx.Value, mut result vjsx.Value, lane VjsxExecutionLane, idx int, frame WorkerWebSocketFrame) !string {
	normalize_fn := ctx.js_global('__vhttpd_normalize_websocket_result')
	defer {
		normalize_fn.free()
	}
	log.debug('[vhttpd] websocket_on_lane handler_ok lane=${lane.id} idx=${idx} event=${frame.event} promise=${result.instanceof('Promise')}')
	resolved := host.resolve_value(result) or {
		err_msg := inproc_vjsx_normalize_error_message(err.msg(),
			'inproc_vjsx_executor_websocket_handler_failed')
		return error(err_msg)
	}
	defer {
		resolved.free()
	}
	mut normalized := host.call_handler(normalize_fn, js_frame, resolved) or {
		err_msg := inproc_vjsx_normalize_error_message(err.msg(),
			'inproc_vjsx_executor_websocket_normalize_failed')
		return error('inproc_vjsx_executor_websocket_normalize_failed:${err_msg}')
	}
	defer {
		normalized.free()
	}
	return normalized.json_stringify()
}

fn (e InProcVjsxExecutor) execute_websocket_callback_on_lane(callback_ctx InProcVjsxWebSocketCallbackContext) !string {
	lane := VjsxExecutionLane{
		id: callback_ctx.lane_id
	}
	frame := callback_ctx.frame
	if frame.event == 'open' {
	}
	mut state := e.state
	state.mu.@lock()
	host := state.hosts[callback_ctx.idx]
	state.mu.unlock()
	mut callback_result := inproc_vjsx_invoke_websocket_callback(host, callback_ctx.ctx,
		callback_ctx.js_frame, lane, callback_ctx.idx, frame) or {
		if err.msg() == 'inproc_vjsx_executor_missing_websocket_handler' {
			e.record_lane_success(callback_ctx.lane_id)
			log.debug('[vhttpd] websocket_on_lane done lane=${callback_ctx.lane_id} idx=${callback_ctx.idx} event=${frame.event}')
			return inproc_vjsx_websocket_handler_missing_result(frame)
		}
		return error(err.msg())
	}
	if frame.event == 'open' {
	}
	defer {
		callback_result.free()
	}
	if frame.event == 'open' {
	}
	response_json := inproc_vjsx_normalize_websocket_callback_result(host, callback_ctx.ctx,
		callback_ctx.js_frame, mut callback_result, lane, callback_ctx.idx, frame) or {
		return error(err.msg())
	}
	if frame.event == 'open' {
	}
	if frame.event == 'open' {
		log.debug('[vhttpd] websocket_on_lane normalized event=${frame.event} lane=${callback_ctx.lane_id} idx=${callback_ctx.idx} request_id=${frame.request_id} response_json=${response_json}')
	}
	e.record_lane_success(callback_ctx.lane_id)
	log.debug('[vhttpd] websocket_on_lane done lane=${callback_ctx.lane_id} idx=${callback_ctx.idx} event=${frame.event}')
	return response_json
}

fn (e InProcVjsxExecutor) resolve_websocket_affinity_on_lane(mut app App, frame WorkerWebSocketFrame, lane VjsxExecutionLane) !WebSocketAffinityDecision {
	e.bootstrap_placeholder()!
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
		method:     'affinity'
		path:       frame.path
		trace_id:   frame.trace_id
		request_id: frame.request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.context()
	runtime_meta := e.websocket_runtime_meta(lane, frame)
	mut js_runtime :=
		build_websocket_js_runtime(ctx, runtime_meta, app.runtime_config_json, mut app)
	defer {
		js_runtime.free()
	}
	mut js_frame := build_websocket_js_frame(ctx, frame, js_runtime)
	defer {
		js_frame.free()
	}
	mut result := host.call_entry('websocket_affinity', js_frame) or {
		if err.msg() == 'inproc_vjsx_executor_missing_websocket_affinity_handler' {
			e.record_lane_success(lane.id)
			return WebSocketAffinityDecision{}
		}
		err_msg := inproc_vjsx_context_error_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_affinity_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	defer {
		result.free()
	}
	if result.is_exception() {
		err_msg := inproc_vjsx_context_error_message(ctx, 'exception',
			'inproc_vjsx_executor_websocket_affinity_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	resolved := host.resolve_value(result) or {
		err_msg := inproc_vjsx_context_error_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_affinity_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	defer {
		resolved.free()
	}
	decision := websocket_affinity_decision_from_app_result(resolved)
	e.record_lane_success(lane.id)
	return decision
}

fn (e InProcVjsxExecutor) resolve_websocket_actor_on_lane(mut app App, frame WorkerWebSocketFrame, lane VjsxExecutionLane) !WebSocketActorDecision {
	e.bootstrap_placeholder()!
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
		method:     'actor'
		path:       frame.path
		trace_id:   frame.trace_id
		request_id: frame.request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.context()
	runtime_meta := e.websocket_runtime_meta(lane, frame)
	mut js_runtime :=
		build_websocket_js_runtime(ctx, runtime_meta, app.runtime_config_json, mut app)
	defer {
		js_runtime.free()
	}
	mut js_frame := build_websocket_js_frame(ctx, frame, js_runtime)
	defer {
		js_frame.free()
	}
	mut result := host.call_entry('websocket_actor', js_frame) or {
		if err.msg() == 'inproc_vjsx_executor_missing_websocket_actor_handler' {
			e.record_lane_success(lane.id)
			return WebSocketActorDecision{}
		}
		err_msg := inproc_vjsx_context_error_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_actor_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	defer {
		result.free()
	}
	if result.is_exception() {
		err_msg := inproc_vjsx_context_error_message(ctx, 'exception',
			'inproc_vjsx_executor_websocket_actor_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	if result.instanceof('Promise') {
		err_msg := 'inproc_vjsx_executor_websocket_actor_async_not_supported'
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	decision := websocket_actor_decision_from_app_result(result)
	e.record_lane_success(lane.id)
	return decision
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
	log.debug('[vhttpd] startup_hook begin lane=${lane.id} idx=${idx} kind=${kind}')
	e.ensure_lane_host(idx)!
	mut state := e.state
	state.mu.@lock()
	host := state.hosts[idx]
	state.mu.unlock()
	js_ctx_host := host.context()
	hook_global_name := if kind == 'app_startup' {
		'__vhttpd_app_startup_handle'
	} else {
		'__vhttpd_startup_handle'
	}
	hook_probe := js_ctx_host.js_global(hook_global_name)
	if hook_probe.is_undefined() || !hook_probe.is_function() {
		log.debug('[vhttpd] startup_hook skip lane=${lane.id} idx=${idx} kind=${kind} reason=missing_handler')
		hook_probe.free()
		return
	}
	hook_probe.free()
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
	runtime_obj := js_ctx_host.json_parse(e.build_startup_runtime_payload(lane, kind))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := js_ctx_host.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	log.debug('[vhttpd] startup_hook runtime_create lane=${lane.id} idx=${idx} kind=${kind}')
	mut js_runtime := host.call_handler(create_runtime_fn, runtime_obj) or {
		return error('inproc_vjsx_executor_${kind}_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	mut result := if host.is_module_entry && !isnil(host.module_binding) {
		host.call_entry(kind, js_runtime) or {
			if err.msg() == 'inproc_vjsx_executor_missing_${kind}_handler' {
				return
			}
			return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
		}
	} else {
		hook := js_ctx_host.js_global(hook_global_name)
		defer {
			hook.free()
		}
		if hook.is_undefined() || !hook.is_function() {
			return
		}
		host.call_handler_resolved(hook, js_runtime) or {
			return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	log.debug('[vhttpd] startup_hook handler_ok lane=${lane.id} idx=${idx} kind=${kind} promise=${result.instanceof('Promise')}')
	normalize_fn := js_ctx_host.js_global('__vhttpd_normalize_startup_result')
	defer {
		normalize_fn.free()
	}
	resolved := host.resolve_value(result) or {
		return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	mut normalized := host.call_handler(normalize_fn, resolved) or {
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
	log.debug('[vhttpd] startup_hook done lane=${lane.id} idx=${idx} kind=${kind} commands=${commands.len}')
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
	log.debug('[vhttpd] startup_hooks begin lane=${lane.id} idx=${idx}')
	e.run_lane_startup(mut app, idx, lane)!
	e.run_app_startup(mut app, idx, lane)!
	log.debug('[vhttpd] startup_hooks done lane=${lane.id} idx=${idx}')
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
	ctx := host.context()
	request_obj := ctx.json_parse(build_inproc_request_payload(req))
	defer {
		request_obj.free()
	}
	runtime_obj := ctx.json_parse(e.build_runtime_payload(lane, req))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := ctx.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	mut js_runtime := host.call_handler(create_runtime_fn, runtime_obj) or {
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
	mut js_ctx := host.call_handler(create_ctx_fn, request_obj, js_runtime) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_ctx_create_failed:${err.msg()}')
	}
	defer {
		js_ctx.free()
	}
	mut result := host.call_entry('http', js_ctx) or {
		if err.msg() == 'inproc_vjsx_executor_missing_http_handler'
			|| err.msg() == 'inproc_vjsx_executor_missing_handler' {
			e.record_lane_error(lane.id, 'inproc_vjsx_executor_missing_handler')
			return error('inproc_vjsx_executor_missing_handler')
		}
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_handler_failed:${err.msg()}')
	}
	defer {
		result.free()
	}
	normalize_fn := ctx.js_global('__vhttpd_normalize_result')
	defer {
		normalize_fn.free()
	}
	resolved := host.resolve_value(result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_handler_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	mut normalized := host.call_handler(normalize_fn, js_ctx, resolved) or {
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
	e.remember_app(mut app)
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

fn (e InProcVjsxExecutor) call_plugin_once(mut app App, req PluginCallRequest) !PluginCallResponse {
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
		method:     req.op
		path:       '/_plugin/${req.capability}'
		trace_id:   req.trace_id
		request_id: req.request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.context()
	req_obj := ctx.json_parse(json.encode(req))
	defer {
		req_obj.free()
	}
	entry_kind := if req.capability.trim_space() == '' {
		'plugin'
	} else {
		req.capability.trim_space()
	}
	mut result := host.call_entry(entry_kind, req_obj) or {
		if err.msg() == 'inproc_vjsx_executor_missing_${entry_kind}_handler' {
			host.call_entry('plugin', req_obj) or {
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
			}
		} else {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	resolved := host.resolve_value(result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	raw := resolved.json_stringify()
	e.record_lane_success(lane.id)
	return PluginCallResponse{
		ok:     true
		result: raw
	}
}

pub fn (e InProcVjsxExecutor) call_plugin(mut app App, req PluginCallRequest) !PluginCallResponse {
	e.remember_app(mut app)
	mut last_err := 'inproc_vjsx_executor_plugin_call_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		resp := e.call_plugin_once(mut app, req) or {
			last_err = err.msg()
			if attempt + 1 < inproc_vjsx_dispatch_retry_attempts
				&& inproc_vjsx_should_retry_dispatch(last_err) {
				continue
			}
			return error(last_err)
		}
		return resp
	}
	return error(last_err)
}

fn (e InProcVjsxExecutor) call_plugin_stream_once(mut app App, req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
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
		method:     req.op
		path:       '/_plugin/${req.capability}'
		trace_id:   req.trace_id
		request_id: req.request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.context()
	req_obj := ctx.json_parse(json.encode(req))
	defer {
		req_obj.free()
	}
	entry_kind := if req.capability.trim_space() == '' {
		'plugin'
	} else {
		req.capability.trim_space()
	}
	mut result := host.call_entry(entry_kind, req_obj) or {
		if err.msg() == 'inproc_vjsx_executor_missing_${entry_kind}_handler' {
			host.call_entry('plugin', req_obj) or {
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
			}
		} else {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	if host.session.is_streamable_value(result) {
		completed := host.session.stream_value(result, fn [on_frame] (frame vjsx.Value) !bool {
			raw := frame.json_stringify()
			return on_frame(raw)!
		}) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_plugin_stream_failed:${err.msg()}')
		}
		e.record_lane_success(lane.id)
		return PluginStreamCallResponse{
			streamed: true
			response: PluginCallResponse{
				ok:     true
				result: '{"streamed":true,"completed":${completed}}'
			}
		}
	}
	resolved := host.resolve_value(result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	raw := resolved.json_stringify()
	e.record_lane_success(lane.id)
	return PluginStreamCallResponse{
		streamed: false
		response: PluginCallResponse{
			ok:     true
			result: raw
		}
	}
}

pub fn (e InProcVjsxExecutor) call_plugin_stream(mut app App, req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	e.remember_app(mut app)
	return e.call_plugin_stream_once(mut app, req, on_frame)
}

pub fn (e InProcVjsxExecutor) open_websocket_session(mut app App, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	e.remember_app(mut app)
	_ = app
	_ = req
	return inproc_vjsx_not_ready_error('open_websocket_session')
}

pub fn (e InProcVjsxExecutor) dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse {
	e.remember_app(mut app)
	_ = app
	_ = req
	return inproc_vjsx_not_ready_error('dispatch_stream')
}

pub fn (e InProcVjsxExecutor) dispatch_mcp(mut app App, req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	e.remember_app(mut app)
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
	ctx := host.context()
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
	mut js_runtime := host.call_handler(create_runtime_fn, runtime_obj) or {
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
	mut js_frame := host.call_handler(create_frame_fn, frame_obj, js_runtime) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_upstream_frame_create_failed:${err.msg()}')
	}
	defer {
		js_frame.free()
	}
	mut result := host.call_entry('websocket_upstream', js_frame) or {
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
	defer {
		result.free()
	}
	normalize_fn := ctx.js_global('__vhttpd_normalize_websocket_upstream_result')
	defer {
		normalize_fn.free()
	}
	resolved := host.resolve_value(result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_websocket_upstream_handler_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	mut normalized := host.call_handler(normalize_fn, js_frame, resolved) or {
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
	e.remember_app(mut app)
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

fn (e InProcVjsxExecutor) dispatch_websocket_callback_on_lane(mut app App, frame WorkerWebSocketFrame, lane VjsxExecutionLane) !string {
	e.bootstrap_placeholder()!
	idx := e.lane_index_by_id(lane.id)
	log.debug('[vhttpd] websocket_on_lane begin lane=${lane.id} idx=${idx} event=${frame.event} path=${frame.path} request_id=${frame.request_id} trace_id=${frame.trace_id}')
	mut callback_ctx := e.prepare_websocket_callback_on_lane(mut app, frame, lane) or {
		return error(err.msg())
	}
	defer {
		callback_ctx.free()
		e.clear_lane_request_context(callback_ctx.idx)
	}
	return e.execute_websocket_callback_on_lane(callback_ctx)
}

fn (e InProcVjsxExecutor) enqueue_websocket_task(task InProcVjsxWebSocketTask) ! {
	lane, _ := e.acquire_websocket_lane(task.frame)!
	e.bind_websocket_task_lane(task, lane.id)
	e.dispatch_websocket_task_to_lane(task, lane.id)!
}

fn inproc_vjsx_await_websocket_task_result(done_ch chan bool, mut slot InProcVjsxWebSocketTaskSlot) !InProcVjsxWebSocketTaskResult {
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_task_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_task_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
	return result
}

fn inproc_vjsx_await_websocket_task_start(started_ch chan bool) ! {
	select {
		_ := <-started_ch {}
		inproc_vjsx_websocket_queue_wait_timeout {
			return error('inproc_vjsx_executor_websocket_queue_timeout')
		}
	}
}

fn (e InProcVjsxExecutor) finalize_websocket_dispatch_response(frame WorkerWebSocketFrame, affinity_key string, lane_id string, actor_key string, actor_class string, actor_persist bool, result InProcVjsxWebSocketTaskResult) WorkerWebSocketDispatchResponse {
	if frame.event == 'open' {
	}
	response := websocket_response_from_json(result.response_json, frame)
	log.debug('[vhttpd] websocket dispatch reply affinity_key=${affinity_key} event=${frame.event} request_id=${frame.request_id} ok=${result.ok} error=${result.error} accepted=${response.accepted} closed=${response.closed} commands=${response.commands.len} response_affinity_key=${response.affinity_key} response_error=${response.error} response_error_class=${response.error_class}')
	if frame.event == 'open' {
		log.debug('[vhttpd] websocket finalize event=${frame.event} request_id=${frame.request_id} lane=${lane_id} input_affinity_key=${affinity_key} response_affinity_key=${response.affinity_key}')
	}
	if response.affinity_key.trim_space() != '' {
		if frame.event == 'open' {
			log.debug('[vhttpd] websocket finalize migrate event=${frame.event} request_id=${frame.request_id} lane=${lane_id} old_affinity_key=${affinity_key} new_affinity_key=${response.affinity_key}')
		}
		e.migrate_websocket_connection_affinity(frame, response.affinity_key, lane_id)
	} else if frame.event == 'open' {
		log.debug('[vhttpd] websocket finalize migrate_skip event=${frame.event} request_id=${frame.request_id} lane=${lane_id} old_affinity_key=${affinity_key} reason=empty_response_affinity_key')
	}
	if frame.event == 'close' {
		e.release_websocket_actor(frame)
		e.release_websocket_connection_affinity(frame)
	} else if actor_persist && actor_key.trim_space() != '' && frame.id.trim_space() != '' {
		e.cache_websocket_actor(frame, actor_key, actor_class)
	}
	if frame.event == 'open' {
	}
	return response
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	e.remember_app(mut app)
	e.bootstrap_placeholder()!
	if frame.event == 'open' {
	}
	if e.websocket_actor_enabled_for_frame(frame) {
		actor := e.resolve_websocket_actor(frame) or {
			if err.msg() == 'inproc_vjsx_executor_websocket_actor_key_missing' {
				return WorkerWebSocketDispatchResponse{
					mode:        'websocket_dispatch'
					event:       'result'
					id:          frame.id
					accepted:    false
					closed:      true
					commands:    []WorkerWebSocketFrame{}
					error:       'websocket_actor_key_missing'
					error_class: 'websocket_actor_key_missing'
				}
			}
			return error(err.msg())
		}
		if actor.key.trim_space() != '' {
			done_ch := chan bool{cap: 1}
			started_ch := chan bool{cap: 1}
			mut slot := &InProcVjsxWebSocketTaskSlot{}
			canonical_actor_key := websocket_actor_queue_key(actor.class_name, actor.key)
			if frame.event == 'open' {
			}
			task := InProcVjsxWebSocketTask{
				app:              app
				frame:            frame
				slot:             slot
				done:             done_ch
				started:          started_ch
				actor_key:        canonical_actor_key
				actor_class:      actor.class_name
				actor_priority:   actor.priority
				actor_persist:    actor.persist
				actor_serialized: true
			}
			e.enqueue_websocket_mailbox_task(task)
			inproc_vjsx_await_websocket_task_start(started_ch)!
			result := inproc_vjsx_await_websocket_task_result(done_ch, mut slot)!
			if frame.event == 'open' {
			}
			return e.finalize_websocket_dispatch_response(frame, '', '', actor.key,
				actor.class_name, actor.persist, result)
		}
	}
	affinity_key, affinity_priority, should_queue := e.resolve_websocket_dispatch_affinity(frame) or {
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
	done_ch := chan bool{cap: 1}
	started_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxWebSocketTaskSlot{}
	if should_queue {
		if frame.event == 'open' {
		}
		task := InProcVjsxWebSocketTask{
			app:               app
			frame:             frame
			slot:              slot
			done:              done_ch
			started:           started_ch
			affinity_key:      affinity_key
			affinity_priority: affinity_priority
		}
		e.enqueue_websocket_mailbox_task(task)
		inproc_vjsx_await_websocket_task_start(started_ch)!
		result := inproc_vjsx_await_websocket_task_result(done_ch, mut slot)!
		if frame.event == 'open' {
		}
		mut state := e.state
		state.mu.@lock()
		lane_id := state.websocket_connection_lane_by_id[frame.id] or {
			state.websocket_affinity_lane_by_key[affinity_key] or { '' }
		}
		state.mu.unlock()
		return e.finalize_websocket_dispatch_response(frame, affinity_key, lane_id, '', '', false,
			result)
	}
	lane, direct_affinity_key := e.acquire_websocket_lane(frame) or {
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
	if frame.event == 'open' {
	}
	task := InProcVjsxWebSocketTask{
		app:               app
		frame:             frame
		slot:              slot
		done:              done_ch
		started:           started_ch
		affinity_key:      direct_affinity_key
		affinity_priority: affinity_priority
	}
	e.bind_websocket_task_lane(task, lane.id)
	e.dispatch_websocket_task_to_lane(task, lane.id)!
	result := inproc_vjsx_await_websocket_task_result(done_ch, mut slot)!
	if frame.event == 'open' {
	}
	return e.finalize_websocket_dispatch_response(frame, direct_affinity_key, lane.id, '', '',
		false, result)
}
