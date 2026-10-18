module executor

import log

fn (e InProcVjsxExecutor) start_lane_workers() {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return }
	for idx, worker in state.lane_workers {
		if worker.started { continue }
		state.lane_workers[idx].thread = spawn InProcVjsxLaneWorkerRuntime.loop(e.state,
			worker.lane_id, worker.websocket_tasks, worker.snapshot_tasks, worker.warmup_tasks,
			worker.pump_tasks, worker.affinity_tasks, worker.stop_ch)
		state.lane_workers[idx].started = true
	}
}

fn (e InProcVjsxExecutor) lane_worker_by_id(lane_id string) ?VjsxLaneWorker {
	if lane_id == '' {
		return none
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for worker in state.lane_workers {
		if worker.lane_id == lane_id && worker.started {
			return worker
		}
	}
	return none
}

fn (e InProcVjsxExecutor) lane_snapshot_by_id(lane_id string) ?VjsxExecutionLane {
	if lane_id == '' {
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
	e.submit_websocket_task(worker, task)!
	if task.frame.event == 'open' {
	}
}

fn (e InProcVjsxExecutor) request_lane_snapshot(mut app EmbeddedHost, lane VjsxExecutionLane) !string {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneSnapshotTaskSlot{}
	e.submit_snapshot_task(worker, InProcVjsxLaneSnapshotTask{
		app:  app
		slot: slot
		done: done_ch
	})!
	e.await_task(done_ch, mut slot.control, inproc_vjsx_lane_task_timeout, 'inproc_vjsx_executor_lane_snapshot_timeout')!
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

fn (e InProcVjsxExecutor) request_lane_warmup(mut app EmbeddedHost, lane VjsxExecutionLane) ! {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLaneWarmupTaskSlot{}
	log.debug('[vhttpd] warmup enqueue lane=${lane.id}')
	e.submit_warmup_task(worker, InProcVjsxLaneWarmupTask{
		app:  app
		slot: slot
		done: done_ch
	})!
	e.await_lane_warmup(slot.bootstrapped, done_ch, mut slot.control,
		inproc_vjsx_lane_bootstrap_timeout, inproc_vjsx_lane_task_timeout)!
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
	e.request_lane_pump_owned(lane, none)!
}

fn (e InProcVjsxExecutor) request_lane_pump_owned(lane VjsxExecutionLane, owner ?&VjsxLaneWakeupOwner) ! {
	worker := e.lane_worker_by_id(lane.id) or {
		return error('inproc_vjsx_executor_lane_worker_missing')
	}
	done_ch := chan bool{cap: 1}
	mut slot := &InProcVjsxLanePumpTaskSlot{}
	e.submit_pump_task(worker, InProcVjsxLanePumpTask{
		wakeup_owner: owner
		slot: slot
		done: done_ch
	})!
	e.await_task(done_ch, mut slot.control, inproc_vjsx_lane_task_timeout, 'inproc_vjsx_executor_lane_pump_timeout')!
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
