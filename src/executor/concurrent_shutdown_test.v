module executor

import time
import upstream.transport

fn shutdown_wait_for_stop(exec InProcVjsxExecutor) {
	deadline := time.now().add(time.second * 3)
	for !exec.is_stopping() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
}

fn shutdown_close_and_signal(exec InProcVjsxExecutor, done chan bool) {
	exec.close()
	done <- true
}

fn shutdown_assert_pending(done chan bool) {
	select {
		_ := <-done {
			panic('close returned before its resources were released')
		}
		else {
		}
	}
}

fn shutdown_await(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('executor close did not finish')
		}
	}
}

fn test_concurrent_closers_wait_for_direct_lane_before_destroying_session() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	lane := exec.select_next_lane() or { panic(err) }
	mut session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{ runtime_profile: 'script' }) or { panic(err) }
	mut state := exec.state
	state.mu.@lock()
	state.hosts[0] = VjsxLaneHost{ session: session }
	state.mu.unlock()
	done := chan bool{cap: 2}
	spawn shutdown_close_and_signal(exec, done)
	shutdown_wait_for_stop(exec)
	spawn shutdown_close_and_signal(exec, done)
	assert !session.is_closed()
	shutdown_assert_pending(done)
	_ := exec.select_next_lane() or {
		assert err.msg() == 'inproc_vjsx_executor_closed'
		VjsxExecutionLane{}
	}
	exec.release_lane(lane.id)
	shutdown_await(done)
	shutdown_await(done)
	assert session.is_closed()
	state.mu.@lock()
	assert state.closed
	assert !state.lane_workers[0].started
	assert state.hosts[0].session_handle() == none
	state.mu.unlock()
	exec.close()
}

fn test_close_joins_worker_after_accepted_queue_completion() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	worker := exec.lane_worker_by_id(exec.lane_snapshot()[0].id) or { panic('worker missing') }
	mut slot := &InProcVjsxLanePumpTaskSlot{}
	completed := chan bool{cap: 1}
	slot.mu.@lock()
	exec.submit_pump_task(worker, InProcVjsxLanePumpTask{ slot: slot, done: completed }) or { panic(err) }
	done := chan bool{cap: 1}
	spawn shutdown_close_and_signal(exec, done)
	shutdown_wait_for_stop(exec)
	shutdown_assert_pending(done)
	slot.mu.unlock()
	shutdown_await(completed)
	shutdown_await(done)
	assert slot.ready
	assert slot.result.ok
	exec.submit_pump_task(worker, InProcVjsxLanePumpTask{ slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }) or {
		assert err.msg() == 'inproc_vjsx_executor_closed'
		return
	}
	panic('accepted task after close')
}

fn test_close_cancels_pending_mailbox_and_late_restore_without_resurrection() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut task := InProcVjsxWebSocketTask{
		app:          NoOpAppFacade{}
		slot:         &InProcVjsxWebSocketTaskSlot{}
		done:         chan bool{cap: 1}
		started:      chan bool{cap: 1}
		affinity_key: 'queued'
	}
	exec.enqueue_websocket_mailbox_task(task)
	exec.close()
	shutdown_await(task.started)
	shutdown_await(task.done)
	assert task.slot.ready
	assert task.slot.result.error == 'inproc_vjsx_executor_closed'
	mut late := InProcVjsxWebSocketTask{
		app:     NoOpAppFacade{}
		slot:    &InProcVjsxWebSocketTaskSlot{}
		done:    chan bool{cap: 1}
		started: chan bool{cap: 1}
	}
	exec.restore_websocket_mailbox_task('late', late)
	shutdown_await(late.started)
	shutdown_await(late.done)
	assert late.slot.result.error == 'inproc_vjsx_executor_closed'
	assert exec.state.websocket_mailbox_by_key.len == 0
	assert exec.state.websocket_mailbox_running_by_key.len == 0
	// Results may reach the caller after worker completion and teardown.
	frame := transport.WorkerWebSocketFrame{ id: 'late', event: 'open' }
	exec.cache_websocket_actor(frame, 'late-actor', 'class')
	exec.migrate_websocket_connection_affinity(frame, 'late-affinity', 'lane_0')
	assert exec.state.websocket_connection_actor_key_by_id.len == 0
	assert exec.state.websocket_connection_affinity_key_by_id.len == 0
}

fn test_full_lane_queue_rejects_without_blocking_lifecycle_lock() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	worker := VjsxLaneWorker{ pump_tasks: chan InProcVjsxLanePumpTask{cap: 1} }
	task := InProcVjsxLanePumpTask{ slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }
	exec.submit_pump_task(worker, task) or { panic(err) }
	exec.submit_pump_task(worker, task) or {
		assert err.msg() == 'inproc_vjsx_executor_lane_queue_full'
		exec.close()
		return
	}
	panic('accepted task into full queue')
}

fn shutdown_enqueue_mailbox(exec InProcVjsxExecutor, task InProcVjsxWebSocketTask, done chan bool) {
	exec.enqueue_websocket_mailbox_task(task)
	done <- true
}

fn test_close_cancels_busy_lane_mailbox_without_blocking_scheduler() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	lane := exec.select_next_lane() or { panic(err) }
	task := InProcVjsxWebSocketTask{
		app:          NoOpAppFacade{}
		slot:         &InProcVjsxWebSocketTaskSlot{}
		done:         chan bool{cap: 1}
		started:      chan bool{cap: 1}
		affinity_key: 'racing'
	}
	enqueued := chan bool{cap: 1}
	spawn shutdown_enqueue_mailbox(exec, task, enqueued)
	shutdown_await(enqueued)
	mut state := exec.state
	assert state.mailbox_schedulers == 0
	queue := state.websocket_mailbox_by_key['racing'] or { panic('missing pending task') }
	assert queue.len == 1
	done := chan bool{cap: 1}
	spawn shutdown_close_and_signal(exec, done)
	shutdown_wait_for_stop(exec)
	shutdown_await(task.started)
	shutdown_await(task.done)
	assert task.slot.result.error == 'inproc_vjsx_executor_closed'
	shutdown_assert_pending(done)
	exec.release_lane(lane.id)
	shutdown_await(done)
	assert state.mailbox_schedulers == 0
	assert state.websocket_mailbox_by_key.len == 0
}

fn test_close_drains_every_task_queue_and_releases_worker_lane_leases() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 3 })
	lanes := exec.lane_snapshot()
	worker := exec.lane_worker_by_id(lanes[0].id) or { panic('missing worker') }
	websocket_lane := exec.select_lane_by_id(lanes[1].id) or { panic(err) }
	affinity_lane := exec.select_lane_by_id(lanes[2].id) or { panic(err) }
	websocket_worker := exec.lane_worker_by_id(websocket_lane.id) or { panic('missing worker') }
	affinity_worker := exec.lane_worker_by_id(affinity_lane.id) or { panic('missing worker') }
	mut snapshot := &InProcVjsxLaneSnapshotTaskSlot{}
	mut warmup := &InProcVjsxLaneWarmupTaskSlot{}
	mut pump := &InProcVjsxLanePumpTaskSlot{}
	mut websocket := &InProcVjsxWebSocketTaskSlot{}
	mut affinity := &InProcVjsxLaneAffinityTaskSlot{}
	signals := [chan bool{cap: 1}, chan bool{cap: 1}, chan bool{cap: 1}, chan bool{cap: 1},
		chan bool{cap: 1}]
	started := chan bool{cap: 1}
	exec.submit_snapshot_task(worker, InProcVjsxLaneSnapshotTask{ app: NoOpAppFacade{}, slot: snapshot, done: signals[0] }) or { panic(err) }
	exec.submit_warmup_task(worker, InProcVjsxLaneWarmupTask{ app: NoOpAppFacade{}, slot: warmup, done: signals[1] }) or { panic(err) }
	exec.submit_pump_task(worker, InProcVjsxLanePumpTask{ slot: pump, done: signals[2] }) or { panic(err) }
	exec.submit_websocket_task(websocket_worker, InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, slot: websocket, done: signals[3], started: started }) or { panic(err) }
	exec.submit_affinity_task(affinity_worker, InProcVjsxLaneAffinityTask{ app: NoOpAppFacade{}, slot: affinity, done: signals[4] }) or { panic(err) }
	done := chan bool{cap: 1}
	spawn shutdown_close_and_signal(exec, done)
	for signal in signals { shutdown_await(signal) }
	shutdown_await(started)
	shutdown_await(done)
	assert snapshot.ready && warmup.ready && pump.ready && websocket.ready && affinity.ready
	for lane in exec.lane_snapshot() {
		assert lane.inflight == 0
	}
}
