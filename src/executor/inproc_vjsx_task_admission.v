module executor

fn (e InProcVjsxExecutor) submit_websocket_task(worker VjsxLaneWorker, task InProcVjsxWebSocketTask) ! {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return error('inproc_vjsx_executor_closed') }
	mut control := task.slot.control
	if control.mailbox_key != ''
		&& (state.websocket_mailbox_running_by_key[control.mailbox_key] or { u64(0) }) != task_control_id(control) {
		return error('inproc_vjsx_executor_mailbox_retired')
	}
	state.register_task_locked(mut control, worker.lane_id, true, task.done)!
	control.mu.@lock()
	control.started = task.started
	control.mu.unlock()
	select {
		worker.websocket_tasks <- task {
		}
		else {
			state.tasks.delete(task_control_id(control))
			control.mu.@lock()
			control.owns_lane = false
			control.lane_id = ''
			control.mu.unlock()
			return error('inproc_vjsx_executor_lane_queue_full')
		}
	}
}

fn (e InProcVjsxExecutor) submit_snapshot_task(worker VjsxLaneWorker, task InProcVjsxLaneSnapshotTask) ! {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return error('inproc_vjsx_executor_closed') }
	mut control := task.slot.control
	state.register_task_locked(mut control, worker.lane_id, false, task.done)!
	select {
		worker.snapshot_tasks <- task {
		}
		else {
			state.tasks.delete(task_control_id(control))
			control.mu.@lock()
			control.owns_lane = false
			control.lane_id = ''
			control.mu.unlock()
			return error('inproc_vjsx_executor_lane_queue_full')
		}
	}
}

fn (e InProcVjsxExecutor) submit_warmup_task(worker VjsxLaneWorker, task InProcVjsxLaneWarmupTask) ! {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return error('inproc_vjsx_executor_closed') }
	mut control := task.slot.control
	state.register_task_locked(mut control, worker.lane_id, false, task.done)!
	select {
		worker.warmup_tasks <- task {
		}
		else {
			state.tasks.delete(task_control_id(control))
			control.mu.@lock()
			control.owns_lane = false
			control.lane_id = ''
			control.mu.unlock()
			return error('inproc_vjsx_executor_lane_queue_full')
		}
	}
}

fn (e InProcVjsxExecutor) submit_pump_task(worker VjsxLaneWorker, task InProcVjsxLanePumpTask) ! {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return error('inproc_vjsx_executor_closed') }
	mut control := task.slot.control
	state.register_task_locked(mut control, worker.lane_id, false, task.done)!
	select {
		worker.pump_tasks <- task {
		}
		else {
			state.tasks.delete(task_control_id(control))
			control.mu.@lock()
			control.owns_lane = false
			control.lane_id = ''
			control.mu.unlock()
			return error('inproc_vjsx_executor_lane_queue_full')
		}
	}
}

fn (e InProcVjsxExecutor) submit_affinity_task(worker VjsxLaneWorker, task InProcVjsxLaneAffinityTask) ! {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return error('inproc_vjsx_executor_closed') }
	mut control := task.slot.control
	state.register_task_locked(mut control, worker.lane_id, true, task.done)!
	select {
		worker.affinity_tasks <- task {
		}
		else {
			state.tasks.delete(task_control_id(control))
			control.mu.@lock()
			control.owns_lane = false
			control.lane_id = ''
			control.mu.unlock()
			return error('inproc_vjsx_executor_lane_queue_full')
		}
	}
}

fn (e InProcVjsxExecutor) is_stopping() bool {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.stopping
}
