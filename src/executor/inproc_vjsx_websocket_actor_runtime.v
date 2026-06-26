module executor

import upstream.transport

fn (e InProcVjsxExecutor) websocket_actor_probe_lane() !VjsxExecutionLane {
	return e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
}

fn (e InProcVjsxExecutor) request_lane_actor(mut app AppFacade, lane VjsxExecutionLane, frame transport.WorkerWebSocketFrame) !WebSocketActorDecision {
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
	return WebSocketActorPolicy.decision_from_affinity_result(result)
}

fn (e InProcVjsxExecutor) resolve_websocket_actor_from_app(mut app AppFacade, frame transport.WorkerWebSocketFrame) !WebSocketActorDecision {
	lane := e.websocket_actor_probe_lane()!
	defer {
		e.release_lane(lane.id)
	}
	return e.request_lane_actor(mut app, lane, frame)
}

fn (e InProcVjsxExecutor) websocket_actor_connection_cache(frame transport.WorkerWebSocketFrame) WebSocketActorDecision {
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

fn (e InProcVjsxExecutor) websocket_actor_enabled_for_frame(frame transport.WorkerWebSocketFrame) bool {
	if isnil(e.state) {
		return false
	}
	mut state := e.state
	config := state.facade.config.websocket_actor
	return config.enabled && WebSocketActorPolicy.events_include(config.events, frame.event)
}

pub fn (e InProcVjsxExecutor) resolve_websocket_actor(frame transport.WorkerWebSocketFrame) !WebSocketActorDecision {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := state.facade.config.websocket_actor
	if !config.enabled || !WebSocketActorPolicy.events_include(config.events, frame.event) {
		return WebSocketActorDecision{}
	}
	for source in config.sources {
		source_kind := WebSocketActorPolicy.normalize_source(source.typ)
		mut decision := WebSocketActorDecision{}
		if source_kind == 'connection_cache' {
			decision = e.websocket_actor_connection_cache(frame)
		} else if source_kind == 'app' {
			mut app_ref := AppFacade(unsafe { nil })
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
			decision = WebSocketActorPolicy.value_from_source(frame, source)
		}
		if decision.key.trim_space() != '' {
			return decision
		}
	}
	if WebSocketActorPolicy.normalize_fallback(config.fallback) == 'reject' {
		return error('inproc_vjsx_executor_websocket_actor_key_missing')
	}
	return WebSocketActorDecision{}
}

pub fn (e InProcVjsxExecutor) cache_websocket_actor(frame transport.WorkerWebSocketFrame, actor_key string, actor_class string) {
	if isnil(e.state) || frame.id.trim_space() == '' || actor_key.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_connection_actor_key_by_id[frame.id] = actor_key.trim_space()
	state.websocket_connection_actor_class_by_id[frame.id] = actor_class.trim_space()
	state.mu.unlock()
}

pub fn (e InProcVjsxExecutor) release_websocket_actor(frame transport.WorkerWebSocketFrame) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_connection_actor_key_by_id.delete(frame.id)
	state.websocket_connection_actor_class_by_id.delete(frame.id)
	state.mu.unlock()
}
