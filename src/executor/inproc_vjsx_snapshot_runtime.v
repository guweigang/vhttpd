module executor

import json

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

fn (e InProcVjsxExecutor) execute_snapshot_hook(mut app AppFacade, idx int, lane VjsxExecutionLane) !string {
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

fn (e InProcVjsxExecutor) aggregate_runtime_lane_snapshots(mut app AppFacade, current_lane_id string) string {
	if isnil(e.state) {
		return InProcVjsxSnapshotJson.aggregate('all_lanes', 'runtime', current_lane_id, []string{})
	}
	mut state := e.state
	state.mu.@lock()
	lanes := state.lanes.clone()
	state.mu.unlock()
	mut items := []string{}
	for lane in lanes {
		items << InProcVjsxSnapshotJson.item(lane.id, true,
			json.encode(app.admin_runtime_snapshot()), '')
	}
	return InProcVjsxSnapshotJson.aggregate('all_lanes', 'runtime', current_lane_id, items)
}

fn (e InProcVjsxExecutor) aggregate_app_lane_snapshots(mut app AppFacade, current_lane_id string, include_current bool) string {
	scope := if include_current { 'all_lanes' } else { 'other_lanes' }
	if isnil(e.state) {
		return InProcVjsxSnapshotJson.aggregate(scope, 'app', current_lane_id, []string{})
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
			items << InProcVjsxSnapshotJson.item(lane.id, false, '', 'lane_not_found')
			continue
		}
		lane_snapshot := e.request_lane_snapshot(mut app, lane) or {
			items << InProcVjsxSnapshotJson.item(lane.id, false, '', err.msg())
			continue
		}
		if lane_snapshot.trim_space() == '' {
			items << InProcVjsxSnapshotJson.item(lane.id, false, '', '')
			continue
		}
		items << InProcVjsxSnapshotJson.item(lane.id, true, lane_snapshot, '')
	}
	return InProcVjsxSnapshotJson.aggregate(scope, 'app', current_lane_id, items)
}
