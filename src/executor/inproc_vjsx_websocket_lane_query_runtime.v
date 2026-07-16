module executor

import upstream.transport

fn (e InProcVjsxExecutor) resolve_websocket_affinity_on_lane(mut app AppFacade, frame transport.WorkerWebSocketFrame, lane VjsxExecutionLane) !WebSocketAffinityDecision {
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
	mut js_runtime := InProcVjsxWebSocketJs.runtime(ctx, runtime_meta,
		app.get_runtime_config_json(), mut app)
	defer {
		js_runtime.free()
	}
	mut js_frame := InProcVjsxWebSocketJs.frame(ctx, frame, js_runtime)
	defer {
		js_frame.free()
	}
	mut result := host.call_entry('websocket_affinity', js_frame) or {
		if err.msg() == 'inproc_vjsx_executor_missing_websocket_affinity_handler' {
			e.record_lane_success(lane.id)
			return WebSocketAffinityDecision{}
		}
		err_msg := InProcVjsxError.context_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_affinity_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	defer {
		result.free()
	}
	if result.is_exception() {
		err_msg := InProcVjsxError.context_message(ctx, 'exception',
			'inproc_vjsx_executor_websocket_affinity_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	resolved := host.resolve_value(result) or {
		err_msg := InProcVjsxError.context_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_affinity_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	defer {
		resolved.free()
	}
	decision := WebSocketAffinityPolicy.decision_from_app_result(resolved)
	e.record_lane_success(lane.id)
	return decision
}

fn (e InProcVjsxExecutor) resolve_websocket_actor_on_lane(mut app AppFacade, frame transport.WorkerWebSocketFrame, lane VjsxExecutionLane) !WebSocketActorDecision {
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
	mut js_runtime := InProcVjsxWebSocketJs.runtime(ctx, runtime_meta,
		app.get_runtime_config_json(), mut app)
	defer {
		js_runtime.free()
	}
	mut js_frame := InProcVjsxWebSocketJs.frame(ctx, frame, js_runtime)
	defer {
		js_frame.free()
	}
	mut result := host.call_entry('websocket_actor', js_frame) or {
		if err.msg() == 'inproc_vjsx_executor_missing_websocket_actor_handler' {
			e.record_lane_success(lane.id)
			return WebSocketActorDecision{}
		}
		err_msg := InProcVjsxError.context_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_actor_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	defer {
		result.free()
	}
	if result.is_exception() {
		err_msg := InProcVjsxError.context_message(ctx, 'exception',
			'inproc_vjsx_executor_websocket_actor_failed')
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	if result.instanceof('Promise') {
		err_msg := 'inproc_vjsx_executor_websocket_actor_async_not_supported'
		e.record_lane_error(lane.id, err_msg)
		return error(err_msg)
	}
	decision := WebSocketActorPolicy.decision_from_app_result(result)
	e.record_lane_success(lane.id)
	return decision
}
