module executor

import log

fn (e InProcVjsxExecutor) start_lane_workers() {
	if isnil(e.state) {
		return
	}
	mut workers := []VjsxLaneWorker{}
	mut state := e.state
	state.mu.@lock()
	workers = state.lane_workers.clone()
	state.mu.unlock()
	for idx, worker in workers {
		if worker.started {
			continue
		}
		task_ch := worker.websocket_tasks
		snapshot_ch := worker.snapshot_tasks
		warmup_ch := worker.warmup_tasks
		pump_ch := worker.pump_tasks
		affinity_ch := worker.affinity_tasks
		stop_ch := worker.stop_ch
		lane_id := worker.lane_id
		mut thr := spawn InProcVjsxLaneWorkerRuntime.loop(e.state, lane_id, task_ch, snapshot_ch,
			warmup_ch, pump_ch, affinity_ch, stop_ch)
		state.mu.@lock()
		if idx >= 0 && idx < state.lane_workers.len {
			state.lane_workers[idx].thread = thr
			state.lane_workers[idx].started = true
		}
		state.mu.unlock()
	}
}

fn (e InProcVjsxExecutor) lane_worker_by_id(lane_id string) ?VjsxLaneWorker {
	if isnil(e.state) || lane_id == '' {
		return none
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for worker in state.lane_workers {
		if worker.lane_id == lane_id {
			return worker
		}
	}
	return none
}

fn (e InProcVjsxExecutor) lane_snapshot_by_id(lane_id string) ?VjsxExecutionLane {
	if isnil(e.state) || lane_id == '' {
		return none
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for lane in state.lanes {
		if lane.id == lane_id {
			return lane
		}
	}
	return none
}

fn (e InProcVjsxExecutor) dispatch_websocket_task_to_lane(task InProcVjsxWebSocketTask, lane_id string) ! {
	worker := e.lane_worker_by_id(lane_id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	if task.frame.event == 'open' {
	}
	log.debug('[vhttpd] websocket dispatch enqueue lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id}')
	worker.websocket_tasks <- task
	if task.frame.event == 'open' {
	}
}

fn (e InProcVjsxExecutor) request_lane_snapshot(mut app AppFacade, lane VjsxExecutionLane) !string {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneSnapshotTaskSlot{}
	worker.snapshot_tasks <- InProcVjsxLaneSnapshotTask{
		app:  app
		slot: slot
		done: done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_snapshot_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_snapshot_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
	return result.raw
}

fn (e InProcVjsxExecutor) request_lane_warmup(mut app AppFacade, lane VjsxExecutionLane) ! {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneWarmupTaskSlot{}
	log.debug('[vhttpd] warmup enqueue lane=${lane.id}')
	worker.warmup_tasks <- InProcVjsxLaneWarmupTask{
		app:  unsafe { &app }
		slot: slot
		done: done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_warmup_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_warmup_not_ready')
	}
	log.debug('[vhttpd] warmup reply lane=${lane.id} ok=${result.ok} error=${result.error}')
	if !result.ok {
		return error(result.error)
	}
}

fn (e InProcVjsxExecutor) request_lane_pump(lane VjsxExecutionLane) ! {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLanePumpTaskSlot{}
	worker.pump_tasks <- InProcVjsxLanePumpTask{
		slot: slot
		done: done_ch
	}
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_pump_timeout')
		}
	}
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_pump_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
}
