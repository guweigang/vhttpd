module executor

import upstream.transport

fn (e InProcVjsxExecutor) websocket_affinity_probe_lane() !VjsxExecutionLane {
	return e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)
}

fn (e InProcVjsxExecutor) request_lane_affinity(mut app AppFacade, lane VjsxExecutionLane, frame transport.WorkerWebSocketFrame) !WebSocketAffinityDecision {
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

fn (e InProcVjsxExecutor) resolve_websocket_affinity_key_from_app(mut app AppFacade, frame transport.WorkerWebSocketFrame) !WebSocketAffinityDecision {
	lane := e.websocket_affinity_probe_lane()!
	return e.request_lane_affinity(mut app, lane, frame)
}

fn (e InProcVjsxExecutor) resolve_websocket_affinity(frame transport.WorkerWebSocketFrame) !WebSocketAffinityDecision {
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
		if WebSocketAffinityPolicy.normalize_source(config.source) == 'app' {
			mut app_ref := AppFacade(unsafe { nil })
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
			decision.key = WebSocketAffinityPolicy.value(frame, config)
		}
	}
	if decision.key == '' && config.enabled
		&& WebSocketAffinityPolicy.normalize_fallback(config.fallback) == 'reject' {
		return error('inproc_vjsx_executor_websocket_affinity_key_missing')
	}
	return decision
}

pub fn (e InProcVjsxExecutor) acquire_websocket_lane(frame transport.WorkerWebSocketFrame) !(VjsxExecutionLane, string) {
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
		if WebSocketAffinityPolicy.normalize_source(config.source) == 'app' {
			mut app_ref := AppFacade(unsafe { nil })
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
			affinity.key = WebSocketAffinityPolicy.value(frame, config)
		}
	}
	affinity_key := affinity.key
	if affinity_key == '' {
		if config.enabled && WebSocketAffinityPolicy.normalize_fallback(config.fallback) == 'reject' {
			return error('inproc_vjsx_executor_websocket_affinity_key_missing')
		}
		lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
		return lane, ''
	}
	should_pin_lane := WebSocketAffinityPolicy.should_pin_lane(frame, affinity_key)
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

fn (e InProcVjsxExecutor) resolve_websocket_dispatch_affinity(frame transport.WorkerWebSocketFrame) !(string, int, bool) {
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
		if WebSocketAffinityPolicy.normalize_source(config.source) == 'app' {
			mut app_ref := AppFacade(unsafe { nil })
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
			affinity.key = WebSocketAffinityPolicy.value(frame, config)
		}
	}
	affinity_key := affinity.key
	if affinity_key == '' {
		if config.enabled && WebSocketAffinityPolicy.normalize_fallback(config.fallback) == 'reject' {
			return error('inproc_vjsx_executor_websocket_affinity_key_missing')
		}
		return '', affinity.priority, false
	}
	return affinity_key, affinity.priority, WebSocketAffinityPolicy.should_pin_lane(frame,
		affinity_key)
}
