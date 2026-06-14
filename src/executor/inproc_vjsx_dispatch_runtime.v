module executor

import json
import log
import upstream.transport
import vjsx

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

fn (e InProcVjsxExecutor) call_plugin_once(mut app AppFacade, req PluginCallRequest) !PluginCallResponse {
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

pub fn (e InProcVjsxExecutor) call_plugin(mut app AppFacade, req PluginCallRequest) !PluginCallResponse {
	e.remember_app(mut app)
	mut last_err := 'inproc_vjsx_executor_plugin_call_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		resp := e.call_plugin_once(mut app, req) or {
			last_err = err.msg()
			if attempt + 1 < inproc_vjsx_dispatch_retry_attempts
				&& InProcVjsxError.should_retry_dispatch(last_err) {
				continue
			}
			return error(last_err)
		}
		return resp
	}
	return error(last_err)
}

fn (e InProcVjsxExecutor) call_plugin_stream_once(mut app AppFacade, req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
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

pub fn (e InProcVjsxExecutor) call_plugin_stream(mut app AppFacade, req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	e.remember_app(mut app)
	return e.call_plugin_stream_once(mut app, req, on_frame)
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

fn (e InProcVjsxExecutor) dispatch_websocket_callback_on_lane(mut app AppFacade, frame transport.WorkerWebSocketFrame, lane VjsxExecutionLane) !string {
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

fn (e InProcVjsxExecutor) finalize_websocket_dispatch_response(frame transport.WorkerWebSocketFrame, affinity_key string, lane_id string, actor_key string, actor_class string, actor_persist bool, result InProcVjsxWebSocketTaskResult) transport.WorkerWebSocketDispatchResponse {
	if frame.event == 'open' {
	}
	response := InProcVjsxResponseCodec.websocket_from_json(result.response_json, frame)
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

pub fn (e InProcVjsxExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	e.remember_app(mut app)
	e.bootstrap_placeholder()!
	if frame.event == 'open' {
	}
	if e.websocket_actor_enabled_for_frame(frame) {
		actor := e.resolve_websocket_actor(frame) or {
			if err.msg() == 'inproc_vjsx_executor_websocket_actor_key_missing' {
				return transport.WorkerWebSocketDispatchResponse{
					mode:        'websocket_dispatch'
					event:       'result'
					id:          frame.id
					accepted:    false
					closed:      true
					commands:    []transport.WorkerWebSocketFrame{}
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
			canonical_actor_key := WebSocketActorPolicy.queue_key(actor.class_name, actor.key)
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
			InProcVjsxWebSocketTaskAwaiter.start(started_ch)!
			result := InProcVjsxWebSocketTaskAwaiter.result(done_ch, mut slot)!
			if frame.event == 'open' {
			}
			return e.finalize_websocket_dispatch_response(frame, '', '', actor.key,
				actor.class_name, actor.persist, result)
		}
	}
	affinity_key, affinity_priority, should_queue := e.resolve_websocket_dispatch_affinity(frame) or {
		if err.msg() == 'inproc_vjsx_executor_websocket_affinity_key_missing' {
			return transport.WorkerWebSocketDispatchResponse{
				mode:        'websocket_dispatch'
				event:       'result'
				id:          frame.id
				accepted:    false
				closed:      true
				commands:    []transport.WorkerWebSocketFrame{}
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
		InProcVjsxWebSocketTaskAwaiter.start(started_ch)!
		result := InProcVjsxWebSocketTaskAwaiter.result(done_ch, mut slot)!
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
			return transport.WorkerWebSocketDispatchResponse{
				mode:        'websocket_dispatch'
				event:       'result'
				id:          frame.id
				accepted:    false
				closed:      true
				commands:    []transport.WorkerWebSocketFrame{}
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
	result := InProcVjsxWebSocketTaskAwaiter.result(done_ch, mut slot)!
	if frame.event == 'open' {
	}
	return e.finalize_websocket_dispatch_response(frame, direct_affinity_key, lane.id, '', '',
		false, result)
}
