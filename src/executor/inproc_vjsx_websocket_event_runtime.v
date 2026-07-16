module executor

import log
import upstream.transport

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
