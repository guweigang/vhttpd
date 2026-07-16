module executor

import time
import state_store

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
