module executor

import log
import upstream.transport

pub fn (e InProcVjsxExecutor) release_websocket_connection_affinity(frame transport.WorkerWebSocketFrame) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	lane_id := state.websocket_connection_lane_by_id[frame.id] or { '' }
	affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	state.websocket_connection_lane_by_id.delete(frame.id)
	state.websocket_connection_affinity_key_by_id.delete(frame.id)
	if affinity_key == '' {
		return
	}
	if affinity_key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[affinity_key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(affinity_key)
			if lane_id != '' && !WebSocketAffinityPolicy.should_pin_lane(frame, affinity_key) {
				state.websocket_affinity_lane_by_key.delete(affinity_key)
			}
			state.websocket_mailbox_by_key.delete(affinity_key)
			state.websocket_mailbox_running_by_key.delete(affinity_key)
			mut next_pending_keys := []string{}
			for key in state.websocket_mailbox_pending_keys {
				if key != affinity_key {
					next_pending_keys << key
				}
			}
			state.websocket_mailbox_pending_keys = next_pending_keys
		} else {
			state.websocket_affinity_ref_count_by_key[affinity_key] = remaining
		}
	}
}

pub fn (e InProcVjsxExecutor) release_websocket_affinity_key(affinity_key string) {
	if isnil(e.state) {
		return
	}
	key := affinity_key.trim_space()
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(key)
			state.websocket_mailbox_by_key.delete(key)
			state.websocket_mailbox_running_by_key.delete(key)
			mut next_pending_keys := []string{}
			for pending_key in state.websocket_mailbox_pending_keys {
				if pending_key != key {
					next_pending_keys << pending_key
				}
			}
			state.websocket_mailbox_pending_keys = next_pending_keys
		} else {
			state.websocket_affinity_ref_count_by_key[key] = remaining
		}
	}
}

pub fn (e InProcVjsxExecutor) migrate_websocket_connection_affinity(frame transport.WorkerWebSocketFrame, affinity_key string, current_lane_id string) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	new_key := affinity_key.trim_space()
	if new_key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	old_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	if old_key == new_key {
		return
	}
	old_lane := state.websocket_connection_lane_by_id[frame.id] or { '' }
	if old_key != '' && old_key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[old_key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(old_key)
			if old_lane != '' && !WebSocketAffinityPolicy.should_pin_lane(frame, old_key) {
				state.websocket_affinity_lane_by_key.delete(old_key)
			}
		} else {
			state.websocket_affinity_ref_count_by_key[old_key] = remaining
		}
	}
	mut new_lane := if old_lane != '' {
		old_lane
	} else {
		state.websocket_affinity_lane_by_key[new_key] or { '' }
	}
	if new_lane == '' && current_lane_id.trim_space() != ''
		&& WebSocketAffinityPolicy.should_pin_lane(frame, new_key) {
		new_lane = current_lane_id.trim_space()
	}
	state.websocket_connection_affinity_key_by_id[frame.id] = new_key
	if new_lane != '' {
		state.websocket_connection_lane_by_id[frame.id] = new_lane
		state.websocket_affinity_lane_by_key[new_key] = new_lane
	}
	state.websocket_affinity_ref_count_by_key[new_key] = (state.websocket_affinity_ref_count_by_key[new_key] or {
		0
	}) + 1
	log.debug('[vhttpd] websocket affinity migrated socket=${frame.id} request_id=${frame.request_id} old_key=${old_key} new_key=${new_key} lane=${new_lane}')
}

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
	if frame.event == 'open' {
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
	if frame.event == 'close' {
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_connection_actor_key_by_id.delete(frame.id)
	state.websocket_connection_actor_class_by_id.delete(frame.id)
	state.mu.unlock()
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
