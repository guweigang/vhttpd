module executor

import log
import time

fn InProcVjsxLaneWorkerRuntime.handle_snapshot_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLaneSnapshotTask) {
	mut task_app := task.app
	lane := worker_executor.lane_snapshot_by_id(lane_id) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneSnapshotTaskResult{
			ok:    false
			error: 'inproc_vjsx_executor_lane_not_found'
		}
		task.slot.ready = true
		task.slot.mu.unlock()
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
		return
	}
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLaneSnapshotTaskResult{
		ok:  true
		raw: raw
	}
	task.slot.ready = true
	task.slot.mu.unlock()
}

fn InProcVjsxLaneWorkerRuntime.handle_warmup_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLaneWarmupTask) {
	mut task_app := task.app
	lane := worker_executor.lane_snapshot_by_id(lane_id) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneWarmupTaskResult{
			ok:    false
			error: 'inproc_vjsx_executor_lane_not_found'
		}
		task.slot.ready = true
		task.slot.mu.unlock()
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
		return
	}
	mut phase_clock := time.new_stopwatch()
	worker_executor.ensure_lane_host(idx) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneWarmupTaskResult{
			ok:    false
			error: InProcVjsxError.normalize_message(err.msg(),
				'inproc_vjsx_executor_warmup_host_failed')
		}
		task.slot.ready = true
		task.slot.mu.unlock()
		return
	}
	log.debug('[vhttpd] lane bootstrap done lane=${lane.id} idx=${idx} elapsed_ms=${phase_clock.elapsed().milliseconds()}')
	phase_clock.restart()
	// Publish the phase boundary only after the module and its runtime are loaded.
	select {
		task.slot.bootstrapped <- time.sys_mono_now() {}
		else {}
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
		return
	}
	log.debug('[vhttpd] lane startup hooks done lane=${lane.id} idx=${idx} elapsed_ms=${phase_clock.elapsed().milliseconds()}')
	log.debug('[vhttpd] lane warmup done lane=${lane.id} idx=${idx}')
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLaneWarmupTaskResult{
		ok: true
	}
	task.slot.ready = true
	task.slot.mu.unlock()
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
		return
	}
	mut state_pump := worker_executor.state
	state_pump.mu.@lock()
	host := state_pump.hosts[idx]
	mut current := true
	if owner := task.wakeup_owner {
		current = false
		if bound := host.wakeup_owner {
			current = !state_pump.stopping && !owner.retired && voidptr(bound) == voidptr(owner)
		}
	}
	state_pump.mu.unlock()
	mut pump_error := ''
	if current {
		if mut session := host.session_handle() {
			// HTTP turns and idle wakeups can own the same lane on different
			// native threads. Settling a completion already enters QuickJS;
			// refresh its stack guard before draining, not only before pumping.
			session.runtime().update_stack_top()
			session.drain_host_async_events() or { pump_error = err.msg() }
		}
		if pump_error == '' { host.pump_until_idle() }
	}
	task.slot.mu.@lock()
	task.slot.result = InProcVjsxLanePumpTaskResult{
		ok: pump_error == ''
		error: pump_error
	}
	task.slot.ready = true
	task.slot.mu.unlock()
}

fn InProcVjsxLaneWorkerRuntime.handle_affinity_task(worker_executor InProcVjsxExecutor, lane_id string, mut task InProcVjsxLaneAffinityTask) {
	mut task_app := task.app
	lane := worker_executor.lane_snapshot_by_id(lane_id) or {
		task.slot.mu.@lock()
		task.slot.result = InProcVjsxLaneAffinityTaskResult{
			ok:    false
			error: 'inproc_vjsx_executor_lane_not_found'
		}
		task.slot.ready = true
		task.slot.mu.unlock()
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
}
