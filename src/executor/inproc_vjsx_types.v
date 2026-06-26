module executor

import sync
import time
import config as app_config
import state_store
import vjsx

const inproc_vjsx_lane_wait_timeout_ms = 1000
const inproc_vjsx_lane_wait_poll_ms = 5
const inproc_vjsx_lane_task_timeout = 10 * time.second
const inproc_vjsx_websocket_queue_wait_timeout = 30 * time.second
const inproc_vjsx_dispatch_retry_attempts = 2
const inproc_vjsx_startup_wait_poll_ms = 5
const inproc_vjsx_signature_probe_poll_ms = 100
const inproc_vjsx_signature_refresh_debounce_ms = 200
const inproc_vjsx_signature_full_refresh_ms = 1000
const inproc_vjsx_http_facade_source = $embed_file('src/inproc_vjsx_http_facade.js')

pub struct VjsxRuntimeFacadeConfig {
pub:
	app_entry                  string
	module_root                string
	build_root                 string
	signature_root             string
	signature_include          []string
	signature_exclude          []string
	runtime_profile            string
	thread_count               int
	max_requests               int
	enable_fs                  bool
	enable_process             bool
	enable_network             bool
	enable_item_render_streams bool = true
	websocket_affinity         app_config.WebSocketAffinityConfig
	websocket_actor            app_config.WebSocketActorConfig
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
pub mut:
	served_requests i64
	healthy         bool = true
	dirty           bool
	inflight        int
	last_error      string
}

pub struct VjsxExecutorState {
pub mut:
	mu sync.Mutex
mut:
	app_ref                                 AppFacade = NoOpAppFacade{}
	facade                                  VjsxRuntimeFacade
	session_store                           state_store.MemoryStateStore[string]
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

struct VjsxLaneHost {
mut:
	initialized       bool
	startup_completed bool
	dirty             bool
	source_signature  string
	is_module_entry   bool
	temp_root         string
	app_ref           AppFacade            = NoOpAppFacade{}
	session           &vjsx.RuntimeSession = unsafe { nil }
	module_binding    &vjsx.ScriptModule   = unsafe { nil }
	request_ctx       InProcVjsxRequestContext
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

struct InProcVjsxRequestContext {
mut:
	active     bool
	app        AppFacade = NoOpAppFacade{}
	lane_id    string
	request_id string
	trace_id   string
	method     string
	path       string
}

pub struct InProcVjsxExecutor {
pub:
	provider_name string = 'vjsx'
	kind_name     string = 'vjsx'
pub mut:
	state &VjsxExecutorState = unsafe { nil }
}

pub fn (e InProcVjsxExecutor) remember_app(mut app AppFacade) {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.mu.@lock()
	state.app_ref = app
	state.mu.unlock()
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
		hosts << VjsxLaneHost.empty()
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
		config.source_probe()
	} else {
		''
	}
	initial_signature := if config.app_entry.trim_space() != '' {
		config.source_signature()
	} else {
		''
	}
	now_ms := time.now().unix_milli()
	mut runner := InProcVjsxExecutor{
		state: &VjsxExecutorState{
			facade:                                  VjsxRuntimeFacade{
				config: config
			}
			session_store:                           state_store.MemoryStateStore.new[string]()
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
	runner.start_lane_workers()
	return runner
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
