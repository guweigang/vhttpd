module executor

fn (e InProcVjsxExecutor) bind_websocket_task_lane(task InProcVjsxWebSocketTask, lane_id string) {
	if lane_id.trim_space() == '' {
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
	if state.stopping { return }
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

struct WebSocketMailboxSelection {
	key  string                  @[required]
	task InProcVjsxWebSocketTask @[required]
}

// Pop one queue head and mark its mailbox running under the same lock.
fn (mut state VjsxExecutorState) take_websocket_mailbox_task() ?WebSocketMailboxSelection {
	mut selected_key := ''
	mut selected_task_handle := ?InProcVjsxWebSocketTask(none)
	mut selected_priority := -1000000000
	state.mu.@lock()
	if state.stopping || state.websocket_mailbox_pending_keys.len == 0 {
		state.mu.unlock()
		return none
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
			selected_task_handle = queue[0]
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
	task := selected_task_handle or { return none }
	return WebSocketMailboxSelection{ key: selected_key, task: task }
}

fn (e InProcVjsxExecutor) try_schedule_websocket_mailboxes() {
	mut scheduling_state := e.state
	scheduling_state.mu.@lock()
	if scheduling_state.stopping {
		scheduling_state.mu.unlock()
		return
	}
	scheduling_state.mailbox_schedulers++
	scheduling_state.mu.unlock()
	defer {
		scheduling_state.mu.@lock()
		scheduling_state.mailbox_schedulers--
		scheduling_state.mu.unlock()
	}
	for {
		mut state := e.state
		selection := state.take_websocket_mailbox_task() or { return }
		selected_key := selection.key
		selected_task := selection.task
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
			e.acquire_lane_by_id(preferred_lane_id, 0) or {
				e.restore_websocket_mailbox_task(selected_key, selected_task)
				return
			}
		} else {
			e.acquire_next_lane(0) or {
				e.restore_websocket_mailbox_task(selected_key, selected_task)
				return
			}
		}
		selected_lane_id := lane.id
		e.bind_websocket_task_lane(selected_task, selected_lane_id)
		e.dispatch_websocket_task_to_lane(selected_task, selected_lane_id) or {
			e.release_lane(selected_lane_id)
			e.restore_websocket_mailbox_task(selected_key, selected_task)
			return
		}
	}
}

fn (e InProcVjsxExecutor) enqueue_websocket_mailbox_task(task InProcVjsxWebSocketTask) {
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
	if state.stopping {
		state.mu.unlock()
		e.cancel_websocket_task(task)
		return
	}
	mut control := task.slot.control
	state.register_task_locked(mut control, '', false, task.done) or {
		state.mu.unlock()
		return
	}
	control.mu.@lock()
	control.started = task.started
	control.mailbox_key = key
	control.mu.unlock()
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

fn (e InProcVjsxExecutor) restore_websocket_mailbox_task(key string, task InProcVjsxWebSocketTask) {
	mut state := e.state
	state.mu.@lock()
	state.websocket_mailbox_running_by_key.delete(key)
	task.slot.control.mu.@lock()
	cancelled := task.slot.control.reason != ''
	task.slot.control.mu.unlock()
	if cancelled {
		state.mu.unlock()
		return
	}
	if state.stopping {
		state.mu.unlock()
		e.cancel_websocket_task(task)
		return
	}
	queue := state.websocket_mailbox_by_key[key] or { []InProcVjsxWebSocketTask{} }
	mut restored := [task]
	restored << queue
	state.websocket_mailbox_by_key[key] = restored
	if key !in state.websocket_mailbox_pending_keys { state.websocket_mailbox_pending_keys << key }
	state.mu.unlock()
}

fn (e InProcVjsxExecutor) cancel_websocket_task(original InProcVjsxWebSocketTask) {
	mut task := original
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxWebSocketTaskResult{ error: 'inproc_vjsx_executor_closed' }
	task.slot.ready = true
	task.slot.mu.unlock()
	// Also bind tasks rejected before admission; cancellation has one notifier.
	task.slot.control.mu.@lock()
	task.slot.control.done = task.done
	task.slot.control.started = task.started
	task.slot.control.mu.unlock()
	e.cancel_task(mut task.slot.control, 'inproc_vjsx_executor_closed')
}
