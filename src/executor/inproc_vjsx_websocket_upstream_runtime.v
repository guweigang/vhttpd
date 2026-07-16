module executor

import json
import upstream.transport

fn (e InProcVjsxExecutor) dispatch_websocket_upstream_once(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
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
			return transport.WorkerWebSocketUpstreamDispatchResponse{
				mode:     'websocket_upstream'
				event:    'result'
				id:       req.id
				handled:  false
				commands: []transport.WorkerWebSocketUpstreamCommand{}
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
	return InProcVjsxResponseCodec.websocket_upstream_from_js_value(normalized, req)
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	e.remember_app(mut app)
	mut last_err := 'inproc_vjsx_executor_dispatch_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		outcome := e.dispatch_websocket_upstream_once(mut app, req) or {
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
