module executor

fn (e InProcVjsxExecutor) bind_websocket_task_lane(task InProcVjsxWebSocketTask, lane_id string) {
	if isnil(e.state) || lane_id.trim_space() == '' {
		return
	}
	if task.actor_serialized {
		return
	}
	key := task.affinity_key.trim_space()
	if !WebSocketAffinityPolicy.should_pin_lane(task.frame, key) {
		return
	}
	if key == '' && task.frame.id.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if key != '' {
		state.websocket_affinity_lane_by_key[key] = lane_id
	}
	if task.frame.id.trim_space() != '' {
		state.websocket_connection_lane_by_id[task.frame.id] = lane_id
		if key != '' {
			state.websocket_connection_affinity_key_by_id[task.frame.id] = key
		}
	}
}

fn (e InProcVjsxExecutor) try_schedule_websocket_mailboxes() {
	if isnil(e.state) {
		return
	}
	for {
		mut selected_key := ''
		mut selected_task := InProcVjsxWebSocketTask{}
		mut selected_lane_id := ''
		mut selected_priority := -1000000000
		mut state := e.state
		state.mu.@lock()
		if state.websocket_mailbox_pending_keys.len == 0 {
			state.mu.unlock()
			return
		}
		mut filtered_pending_keys := []string{}
		for key in state.websocket_mailbox_pending_keys {
			if state.websocket_mailbox_running_by_key[key] or { false } {
				if key !in filtered_pending_keys {
					filtered_pending_keys << key
				}
				continue
			}
			queue := state.websocket_mailbox_by_key[key] or { []InProcVjsxWebSocketTask{} }
			if queue.len == 0 {
				continue
			}
			if key !in filtered_pending_keys {
				filtered_pending_keys << key
			}
			priority := if queue[0].actor_serialized {
				queue[0].actor_priority
			} else {
				queue[0].affinity_priority
			}
			if selected_key == '' || priority > selected_priority {
				selected_key = key
				selected_task = queue[0]
				selected_priority = priority
			}
		}
		state.websocket_mailbox_pending_keys = filtered_pending_keys
		if selected_key != '' {
			queue := state.websocket_mailbox_by_key[selected_key] or { []InProcVjsxWebSocketTask{} }
			remaining := if queue.len > 1 { queue[1..] } else { []InProcVjsxWebSocketTask{} }
			if remaining.len == 0 {
				state.websocket_mailbox_by_key.delete(selected_key)
				mut next_pending_keys := []string{}
				for key in state.websocket_mailbox_pending_keys {
					if key != selected_key {
						next_pending_keys << key
					}
				}
				state.websocket_mailbox_pending_keys = next_pending_keys
			} else {
				state.websocket_mailbox_by_key[selected_key] = remaining
			}
			state.websocket_mailbox_running_by_key[selected_key] = true
		}
		state.mu.unlock()
		if selected_key == '' {
			return
		}
		if selected_task.frame.event == 'open' {
		}
		mut preferred_lane_id := ''
		mut state_lane := e.state
		state_lane.mu.@lock()
		if !selected_task.actor_serialized {
			preferred_lane_id = state_lane.websocket_affinity_lane_by_key[selected_key] or { '' }
		}
		state_lane.mu.unlock()
		lane := if preferred_lane_id != '' {
			e.acquire_lane_by_id(preferred_lane_id, inproc_vjsx_lane_wait_timeout_ms) or {
				mut state_retry := e.state
				state_retry.mu.@lock()
				queue := state_retry.websocket_mailbox_by_key[selected_key] or {
					[]InProcVjsxWebSocketTask{}
				}
				mut restored := [selected_task]
				restored << queue
				state_retry.websocket_mailbox_by_key[selected_key] = restored
				if selected_key !in state_retry.websocket_mailbox_pending_keys {
					state_retry.websocket_mailbox_pending_keys << selected_key
				}
				state_retry.websocket_mailbox_running_by_key.delete(selected_key)
				state_retry.mu.unlock()
				return
			}
		} else {
			e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms) or {
				mut state_retry := e.state
				state_retry.mu.@lock()
				queue := state_retry.websocket_mailbox_by_key[selected_key] or {
					[]InProcVjsxWebSocketTask{}
				}
				mut restored := [selected_task]
				restored << queue
				state_retry.websocket_mailbox_by_key[selected_key] = restored
				if selected_key !in state_retry.websocket_mailbox_pending_keys {
					state_retry.websocket_mailbox_pending_keys << selected_key
				}
				state_retry.websocket_mailbox_running_by_key.delete(selected_key)
				state_retry.mu.unlock()
				return
			}
		}
		selected_lane_id = lane.id
		e.bind_websocket_task_lane(selected_task, selected_lane_id)
		e.dispatch_websocket_task_to_lane(selected_task, selected_lane_id) or {
			e.release_lane(selected_lane_id)
			mut state_retry := e.state
			state_retry.mu.@lock()
			queue := state_retry.websocket_mailbox_by_key[selected_key] or {
				[]InProcVjsxWebSocketTask{}
			}
			mut restored := [selected_task]
			restored << queue
			state_retry.websocket_mailbox_by_key[selected_key] = restored
			if selected_key !in state_retry.websocket_mailbox_pending_keys {
				state_retry.websocket_mailbox_pending_keys << selected_key
			}
			state_retry.websocket_mailbox_running_by_key.delete(selected_key)
			state_retry.mu.unlock()
			return
		}
	}
}

fn (e InProcVjsxExecutor) enqueue_websocket_mailbox_task(task InProcVjsxWebSocketTask) {
	if isnil(e.state) {
		return
	}
	key := if task.actor_serialized {
		task.actor_key.trim_space()
	} else {
		task.affinity_key.trim_space()
	}
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	mut queue := state.websocket_mailbox_by_key[key] or { []InProcVjsxWebSocketTask{} }
	queue << task
	state.websocket_mailbox_by_key[key] = queue
	if key !in state.websocket_mailbox_pending_keys {
		state.websocket_mailbox_pending_keys << key
	}
	state.mu.unlock()
	e.try_schedule_websocket_mailboxes()
}

fn (e InProcVjsxExecutor) finish_websocket_mailbox_task(affinity_key string) {
	if isnil(e.state) {
		return
	}
	key := affinity_key.trim_space()
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	state.websocket_mailbox_running_by_key.delete(key)
	state.mu.unlock()
	e.try_schedule_websocket_mailboxes()
}
