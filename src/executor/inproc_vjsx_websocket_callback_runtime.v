module executor

import json
import log
import upstream.transport
import vjsx

struct InProcVjsxWebSocketCallbackContext {
	idx        int
	lane_id    string
	frame      transport.WorkerWebSocketFrame
	ctx        &vjsx.Context
	js_runtime vjsx.Value
	js_frame   vjsx.Value
}

struct InProcVjsxWebSocketCallbackInput {
	request_ctx  HttpLogicDispatchRequest
	runtime_meta InProcVjsxRuntimeMeta
	frame        transport.WorkerWebSocketFrame
}

fn (mut c InProcVjsxWebSocketCallbackContext) free() {
	c.js_frame.free()
	c.js_runtime.free()
}

fn (e InProcVjsxExecutor) websocket_callback_input(lane VjsxExecutionLane, frame transport.WorkerWebSocketFrame) InProcVjsxWebSocketCallbackInput {
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

struct InProcVjsxWebSocketCallback {}

fn InProcVjsxWebSocketCallback.build_payload(ctx &vjsx.Context, input InProcVjsxWebSocketCallbackInput, runtime_config_json string, mut app AppFacade) (vjsx.Value, vjsx.Value) {
	mut js_runtime :=
		InProcVjsxWebSocketJs.runtime(ctx, input.runtime_meta, runtime_config_json, mut app)
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
			InProcVjsxWebSocketJs.frame(ctx, input.frame, js_runtime)
		}
		return js_runtime, js_frame
	}
	mut js_frame := InProcVjsxWebSocketJs.frame(ctx, input.frame, js_runtime)
	return js_runtime, js_frame
}

fn (e InProcVjsxExecutor) prepare_websocket_callback_on_lane(mut app AppFacade, frame transport.WorkerWebSocketFrame, lane VjsxExecutionLane) !InProcVjsxWebSocketCallbackContext {
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
	mut js_runtime, mut js_frame := InProcVjsxWebSocketCallback.build_payload(ctx, callback_input,
		app.get_runtime_config_json(), mut app)
	return InProcVjsxWebSocketCallbackContext{
		idx:        idx
		lane_id:    lane.id
		frame:      frame
		ctx:        ctx
		js_runtime: js_runtime
		js_frame:   js_frame
	}
}

fn InProcVjsxWebSocketCallback.invoke(host VjsxLaneHost, ctx &vjsx.Context, js_frame vjsx.Value, lane VjsxExecutionLane, idx int, frame transport.WorkerWebSocketFrame) !vjsx.Value {
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
		err_msg := InProcVjsxError.context_message(ctx, err.msg(),
			'inproc_vjsx_executor_websocket_handler_failed')
		return error(err_msg)
	}
	if result.is_exception() {
		result.free()
		err_msg := InProcVjsxError.context_message(ctx, 'exception',
			'inproc_vjsx_executor_websocket_handler_failed')
		return error(err_msg)
	}
	return result
}

fn InProcVjsxWebSocketCallback.normalize_result(host VjsxLaneHost, ctx &vjsx.Context, js_frame vjsx.Value, mut result vjsx.Value, lane VjsxExecutionLane, idx int, frame transport.WorkerWebSocketFrame) !string {
	normalize_fn := ctx.js_global('__vhttpd_normalize_websocket_result')
	defer {
		normalize_fn.free()
	}
	log.debug('[vhttpd] websocket_on_lane handler_ok lane=${lane.id} idx=${idx} event=${frame.event} promise=${result.instanceof('Promise')}')
	resolved := host.resolve_value(result) or {
		err_msg := InProcVjsxError.normalize_message(err.msg(),
			'inproc_vjsx_executor_websocket_handler_failed')
		return error(err_msg)
	}
	defer {
		resolved.free()
	}
	mut normalized := host.call_handler(normalize_fn, js_frame, resolved) or {
		err_msg := InProcVjsxError.normalize_message(err.msg(),
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
	mut callback_result := InProcVjsxWebSocketCallback.invoke(host, callback_ctx.ctx,
		callback_ctx.js_frame, lane, callback_ctx.idx, frame) or {
		if err.msg() == 'inproc_vjsx_executor_missing_websocket_handler' {
			e.record_lane_success(callback_ctx.lane_id)
			log.debug('[vhttpd] websocket_on_lane done lane=${callback_ctx.lane_id} idx=${callback_ctx.idx} event=${frame.event}')
			return InProcVjsxResponseCodec.websocket_handler_missing_result(frame)
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
	response_json := InProcVjsxWebSocketCallback.normalize_result(host, callback_ctx.ctx,
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
