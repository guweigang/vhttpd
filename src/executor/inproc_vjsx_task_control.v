module executor

import sync
import time
import vjsx

enum ExecutorTaskPhase {
	pending
	running
	completed
	cancelled
}

// Shared by every task copy. Lock order is executor state, then task control.
struct ExecutorTaskControl {
mut:
	mu          sync.Mutex
	phase       ExecutorTaskPhase
	reason      string
	lane_id     string
	owns_lane   bool
	done        chan bool = chan bool{cap: 1}
	started     chan bool = chan bool{cap: 1}
	mailbox_key string
	notified    bool
	session     ?&vjsx.RuntimeSession
}

fn task_control_id(control &ExecutorTaskControl) u64 { return u64(voidptr(control)) }

fn (mut state VjsxExecutorState) register_task_locked(mut control ExecutorTaskControl, lane_id string, owns_lane bool, done chan bool) ! {
	control.mu.@lock()
	defer { control.mu.unlock() }
	if control.reason != '' { return error(control.reason) }
	if control.phase != .pending { return error('inproc_vjsx_executor_task_already_started') }
	control.lane_id = lane_id
	control.owns_lane = owns_lane
	control.done = done
	state.tasks[task_control_id(control)] = control
}

fn (e InProcVjsxExecutor) begin_task(mut control ExecutorTaskControl, lane_id string) bool {
	mut state := e.state
	state.mu.@lock()
	control.mu.@lock()
	if control.phase != .pending || control.reason != '' {
		control.mu.unlock()
		state.mu.unlock()
		return false
	}
	// Maintenance tasks acquire their own lease at execution time. Never borrow
	// the session of a direct call or a WebSocket task that already owns this lane.
	if !control.owns_lane {
		for idx, lane in state.lanes {
			if lane.id != lane_id { continue }
			if lane.inflight > 0 {
				control.mu.unlock()
				state.mu.unlock()
				return false
			}
			state.lanes[idx].inflight++
			control.owns_lane = true
			break
		}
	}
	control.phase = .running
	state.active_task_by_lane[lane_id] = control
	for idx, lane in state.lanes {
		if lane.id == lane_id && idx < state.hosts.len {
			control.session = state.hosts[idx].session
		}
	}
	control.mu.unlock()
	state.mu.unlock()
	return true
}

fn (e InProcVjsxExecutor) finish_task(mut control ExecutorTaskControl) {
	mut state := e.state
	state.mu.@lock()
	control.mu.@lock()
	if control.phase != .running {
		control.mu.unlock()
		state.mu.unlock()
		return
	}
	lane_id := control.lane_id
	owns_lane := control.owns_lane
	control.owns_lane = false
	control.session = none
	state.active_task_by_lane.delete(lane_id)
	state.tasks.delete(task_control_id(control))
	control.mu.unlock()
	state.mu.unlock()
	// An interrupted runtime cannot be reused. Destroy it on its owning worker.
	idx := e.lane_index_by_id(lane_id)
	if idx >= 0 {
		state.mu.@lock()
		host := state.hosts[idx]
		state.mu.unlock()
		if session := host.session_handle() {
			if session.is_interrupted() { e.reset_lane_host(idx) }
		}
	}
	state.mu.@lock()
	if owns_lane {
		for i, lane in state.lanes {
			if lane.id == lane_id && lane.inflight > 0 { state.lanes[i].inflight-- }
		}
	}
	if control.mailbox_key != '' {
		state.websocket_mailbox_running_by_key.delete(control.mailbox_key)
	}
	state.mu.unlock()
	control.mu.@lock()
	control.phase = if control.reason == '' { .completed } else { .cancelled }
	control.mu.unlock()
	signal_task_completion(mut control)
	e.try_schedule_websocket_mailboxes()
}

fn (e InProcVjsxExecutor) cancel_task(mut control ExecutorTaskControl, reason string) bool {
	mut state := e.state
	state.mu.@lock()
	control.mu.@lock()
	if control.phase in [.completed, .cancelled] || control.reason != '' {
		control.mu.unlock()
		state.mu.unlock()
		return false
	}
	control.reason = reason
	pending := control.phase == .pending
	if pending {
		control.phase = .cancelled
		if control.owns_lane {
			if control.mailbox_key != '' {
				state.websocket_mailbox_running_by_key.delete(control.mailbox_key)
			}
			for i, lane in state.lanes {
				if lane.id == control.lane_id && lane.inflight > 0 { state.lanes[i].inflight-- }
			}
			control.owns_lane = false
		}
		state.tasks.delete(task_control_id(control))
		mut empty_keys := []string{}
		for key, queue in state.websocket_mailbox_by_key {
			mut remaining := []InProcVjsxWebSocketTask{}
			for task in queue {
				if task_control_id(task.slot.control) != task_control_id(control) {
					remaining << task
				}
			}
			if remaining.len == 0 {
				empty_keys << key
			} else {
				state.websocket_mailbox_by_key[key] = remaining
			}
		}
		for key in empty_keys {
			state.websocket_mailbox_by_key.delete(key)
			state.websocket_mailbox_pending_keys = state.websocket_mailbox_pending_keys.filter(it != key)
		}
	} else if session := control.session {
		// This is the vjsx atomic interrupt API; session close stays on the owner.
		session.cancel()
	}
	control.mu.unlock()
	state.mu.unlock()
	signal_task_completion(mut control)
	select {
		control.started <- true {
		}
		else {
		}
	}
	if pending { e.try_schedule_websocket_mailboxes() }
	return true
}

fn (e InProcVjsxExecutor) await_task(done chan bool, mut control ExecutorTaskControl, timeout time.Duration, timeout_error string) ! {
	select {
		_ := <-done {
		}
		timeout {
			e.cancel_task(mut control, timeout_error)
		}
	}
	task_completion_result(mut control, timeout_error)!
}

fn task_completion_result(mut control ExecutorTaskControl, timeout_error string) ! {
	control.mu.@lock()
	reason := control.reason
	phase := control.phase
	control.mu.unlock()
	if reason != '' { return error(reason) }
	if phase != .completed { return error(timeout_error) }
}

fn (e InProcVjsxExecutor) attach_task_session(lane_id string, session &vjsx.RuntimeSession) {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	mut control := state.active_task_by_lane[lane_id] or { return }
	control.mu.@lock()
	control.session = session
	if control.reason != '' { session.cancel() }
	control.mu.unlock()
}

fn (mut state VjsxExecutorState) detach_task_session_locked(lane_id string) {
	mut control := state.active_task_by_lane[lane_id] or { return }
	control.mu.@lock()
	control.session = none
	control.mu.unlock()
}

fn signal_task_completion(mut control ExecutorTaskControl) {
	control.mu.@lock()
	if control.notified {
		control.mu.unlock()
		return
	}
	control.notified = true
	done := control.done
	control.mu.unlock()
	select {
		done <- true {
		}
		else {
		}
	}
}

fn task_is_pending(control &ExecutorTaskControl) bool {
	mut task_control := unsafe { control }
	task_control.mu.@lock()
	defer { task_control.mu.unlock() }
	return task_control.phase == .pending && task_control.reason == ''
}

fn (mut state VjsxExecutorState) pending_mailbox_controls_locked(key string) []&ExecutorTaskControl {
	mut pending := []&ExecutorTaskControl{}
	for _, control in state.tasks {
		mut task := control
		task.mu.@lock()
		if task.mailbox_key == key && task.phase == .pending { pending << task }
		task.mu.unlock()
	}
	return pending
}

// Bootstrap errors complete the task without a phase notification. A buffered
// boundary also permits the worker to finish before the caller starts waiting.
fn (e InProcVjsxExecutor) await_lane_warmup(bootstrapped chan u64, done chan bool, mut control ExecutorTaskControl, bootstrap_timeout time.Duration, hook_timeout time.Duration) ! {
	select {
		started_at := <-bootstrapped {
			// Scheduling the waiter late must not grant a fresh hook budget.
			remaining := hook_timeout - time.Duration(time.sys_mono_now() - started_at)
			if remaining <= 0 {
				e.cancel_task(mut control, 'inproc_vjsx_executor_lane_warmup_timeout')
				task_completion_result(mut control, 'inproc_vjsx_executor_lane_warmup_timeout')!
				return
			}
			e.await_task(done, mut control, remaining, 'inproc_vjsx_executor_lane_warmup_timeout')!
		}
		_ := <-done {
			task_completion_result(mut control, 'inproc_vjsx_executor_lane_warmup_timeout')!
		}
		bootstrap_timeout {
			e.cancel_task(mut control, 'inproc_vjsx_executor_lane_bootstrap_timeout')
			task_completion_result(mut control, 'inproc_vjsx_executor_lane_bootstrap_timeout')!
		}
	}
}
