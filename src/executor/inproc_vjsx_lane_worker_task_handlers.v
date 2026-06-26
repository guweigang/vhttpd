module executor

import log

fn InProcVjsxLaneWorkerRuntime.handle_snapshot_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLaneSnapshotTask) {
	mut task_app := task.app
	lane := worker_executor.lane_snapshot_by_id(lane_id) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneSnapshotTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_lane_not_found')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	idx := worker_executor.lane_index_by_id(lane.id)
	if idx < 0 {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneSnapshotTaskResult{
			ok:    false
			error: 'inproc_vjsx_executor_lane_not_found'
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	raw := worker_executor.execute_snapshot_hook(mut task_app, idx, lane) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneSnapshotTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_snapshot_failed')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLaneSnapshotTaskResult{
		ok:  true
		raw: raw
	}
	task.slot.ready = true
	task.slot.mu.unlock()
	task.done <- true
}

fn InProcVjsxLaneWorkerRuntime.handle_warmup_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLaneWarmupTask) {
	mut task_app := task.app
	lane := worker_executor.lane_snapshot_by_id(lane_id) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneWarmupTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_lane_not_found')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	idx := worker_executor.lane_index_by_id(lane.id)
	log.debug('[vhttpd] lane warmup begin lane=${lane.id} idx=${idx}')
	if idx < 0 {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneWarmupTaskResult{
			ok:    false
			error: 'inproc_vjsx_executor_lane_not_found'
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	worker_executor.ensure_lane_host(idx) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneWarmupTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_warmup_host_failed')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	worker_executor.run_startup_hooks(mut task_app, idx, lane) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneWarmupTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_warmup_startup_failed')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	log.debug('[vhttpd] lane warmup done lane=${lane.id} idx=${idx}')
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLaneWarmupTaskResult{
		ok: true
	}
	task.slot.ready = true
	task.slot.mu.unlock()
	task.done <- true
}

fn InProcVjsxLaneWorkerRuntime.handle_pump_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLanePumpTask) {
	idx := worker_executor.lane_index_by_id(lane_id)
	if idx < 0 {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLanePumpTaskResult{
			ok:    false
			error: 'inproc_vjsx_executor_lane_not_found'
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	mut state_pump := worker_executor.state
	state_pump.mu.@lock()
	host := state_pump.hosts[idx]
	state_pump.mu.unlock()
	host.pump_until_idle()
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLanePumpTaskResult{
		ok: true
	}
	task.slot.ready = true
	task.slot.mu.unlock()
	task.done <- true
}

fn InProcVjsxLaneWorkerRuntime.handle_affinity_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLaneAffinityTask) {
	mut task_app := task.app
	defer {
		worker_executor.release_lane(lane_id)
	}
	lane := worker_executor.lane_snapshot_by_id(lane_id) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneAffinityTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_lane_not_found')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		task.done <- true
		return
	}
	mut affinity_decision := WebSocketAffinityDecision{}
	mut actor_decision := WebSocketActorDecision{}
	if task.kind == 'actor' {
		actor_decision = worker_executor.resolve_websocket_actor_on_lane(mut task_app, task.frame, lane) or {
			task.slot.mu.@lock()
			task.slot.result = InProcVjsxLaneAffinityTaskResult{
				ok:    false
				error: InProcVjsxError.normalize_message(err.msg(),
					'inproc_vjsx_executor_websocket_actor_failed')
			}
			task.slot.ready = true
			task.slot.mu.unlock()
			task.done <- true
			return
		}
	} else {
		affinity_decision = worker_executor.resolve_websocket_affinity_on_lane(mut task_app,
			task.frame, lane) or {
			task.slot.mu.@lock()
			task.slot.result = InProcVjsxLaneAffinityTaskResult{
				ok:    false
				error: InProcVjsxError.normalize_message(err.msg(),
					'inproc_vjsx_executor_websocket_affinity_failed')
			}
			task.slot.ready = true
			task.slot.mu.unlock()
			task.done <- true
			return
		}
	}
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLaneAffinityTaskResult{
		ok:    true
		value: affinity_decision
		actor: actor_decision
	}
	task.slot.ready = true
	task.slot.mu.unlock()
	task.done <- true
}
