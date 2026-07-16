module executor

import upstream.transport

fn (e InProcVjsxExecutor) dispatch_http_once(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
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
	request_obj := ctx.json_parse(InProcVjsxRequestPayload.build(req))
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
		response: InProcVjsxResponseCodec.from_js_value(normalized, req.request_id)
	}
}

pub fn (e InProcVjsxExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	e.remember_app(mut app)
	mut last_err := 'inproc_vjsx_executor_dispatch_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		outcome := e.dispatch_http_once(mut app, req) or {
			last_err = err.msg()
			if attempt + 1 < inproc_vjsx_dispatch_retry_attempts
				&& InProcVjsxError.should_retry_dispatch(last_err) {
				continue
			}
			return error(last_err)
		}
		return outcome
	}
	return error(last_err)
}

pub fn (e InProcVjsxExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	e.remember_app(mut app)
	_ = app
	_ = req
	return InProcVjsxError.not_ready('open_websocket_session')
}

pub fn (e InProcVjsxExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	e.remember_app(mut app)
	_ = app
	_ = req
	return InProcVjsxError.not_ready('dispatch_stream')
}

pub fn (e InProcVjsxExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	e.remember_app(mut app)
	_ = app
	_ = req
	return InProcVjsxError.not_ready('dispatch_mcp')
}
