module executor

import os
import time
import vjsx
import upstream.transport
import config as app_config

fn cancel_test_executor() InProcVjsxExecutor {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut state := exec.state
	state.lanes = [VjsxExecutionLane{ id: 'lane_0' }]
	state.hosts = [VjsxLaneHost.empty()]
	state.lane_workers = [VjsxLaneWorker{
		lane_id:         'lane_0'
		websocket_tasks: chan InProcVjsxWebSocketTask{cap: 8}
		snapshot_tasks:  chan InProcVjsxLaneSnapshotTask{cap: 8}
		warmup_tasks:    chan InProcVjsxLaneWarmupTask{cap: 8}
		pump_tasks:      chan InProcVjsxLanePumpTask{cap: 8}
		affinity_tasks:  chan InProcVjsxLaneAffinityTask{cap: 8}
		stop_ch:         chan bool{cap: 1}
	}]
	return exec
}

fn test_pending_timeout_releases_one_lease_and_tombstone_cannot_release_next_lease() {
	exec := cancel_test_executor()
	lane := exec.select_next_lane() or { panic(err) }
	worker := exec.state.lane_workers[0]
	mut task := InProcVjsxLaneAffinityTask{ app: NoOpAppFacade{}, slot: &InProcVjsxLaneAffinityTaskSlot{}, done: chan bool{cap: 1} }
	exec.submit_affinity_task(worker, task) or { panic(err) }
	exec.await_task(task.done, mut task.slot.control, time.millisecond, 'expired') or { assert err.msg() == 'expired' }
	assert exec.state.lanes[0].inflight == 0
	assert exec.state.tasks.len == 0
	assert !exec.cancel_task(mut task.slot.control, 'again')
	next := exec.select_next_lane() or { panic(err) }
	assert !exec.begin_task(mut task.slot.control, lane.id)
	exec.finish_task(mut task.slot.control)
	assert exec.state.lanes[0].inflight == 1
	exec.release_lane(next.id)
	exec.start_lane_workers()
	exec.close()
}

fn test_mailbox_timeout_removes_pending_entry_and_late_restore_is_ignored() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut task := InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, affinity_key: 'expired', slot: &InProcVjsxWebSocketTaskSlot{}, done: chan bool{cap: 1}, started: chan bool{cap: 1} }
	exec.enqueue_websocket_mailbox_task(task)
	exec.await_task(task.done, mut task.slot.control, time.millisecond, 'queue_expired') or { assert err.msg() == 'queue_expired' }
	assert exec.state.websocket_mailbox_by_key.len == 0
	assert exec.state.websocket_mailbox_pending_keys.len == 0
	exec.restore_websocket_mailbox_task('expired', task)
	assert exec.state.websocket_mailbox_by_key.len == 0
	select {
		_ := <-task.started {
		}
		else {
			panic('cancel did not wake start waiter')
		}
	}
	exec.close()
}

fn test_cancelled_entries_in_all_five_queues_are_skipped_during_close() {
	exec := cancel_test_executor()
	worker := exec.state.lane_workers[0]
	mut snapshot := &InProcVjsxLaneSnapshotTaskSlot{}
	mut warmup := &InProcVjsxLaneWarmupTaskSlot{}
	mut pump := &InProcVjsxLanePumpTaskSlot{}
	mut websocket := &InProcVjsxWebSocketTaskSlot{}
	mut affinity := &InProcVjsxLaneAffinityTaskSlot{}
	done := chan bool{cap: 8}
	exec.submit_snapshot_task(worker, InProcVjsxLaneSnapshotTask{ app: NoOpAppFacade{}, slot: snapshot, done: done }) or { panic(err) }
	exec.submit_warmup_task(worker, InProcVjsxLaneWarmupTask{ app: NoOpAppFacade{}, slot: warmup, done: done }) or { panic(err) }
	exec.submit_pump_task(worker, InProcVjsxLanePumpTask{ slot: pump, done: done }) or { panic(err) }
	_ := exec.force_select_lane_by_id(worker.lane_id) or { panic(err) }
	exec.submit_websocket_task(worker, InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, slot: websocket, done: done, started: chan bool{cap: 1} }) or { panic(err) }
	_ := exec.force_select_lane_by_id(worker.lane_id) or { panic(err) }
	exec.submit_affinity_task(worker, InProcVjsxLaneAffinityTask{ app: NoOpAppFacade{}, slot: affinity, done: done }) or { panic(err) }
	mut controls := [snapshot.control, warmup.control, pump.control, websocket.control,
		affinity.control]
	for mut control in controls {
		assert exec.cancel_task(mut control, 'expired')
	}
	assert exec.state.lanes[0].inflight == 0
	exec.start_lane_workers()
	exec.close()
	assert !snapshot.ready && !warmup.ready && !pump.ready && !websocket.ready && !affinity.ready
	assert exec.state.tasks.len == 0
}

fn test_completion_wins_late_timeout_and_duplicate_cleanup() {
	exec := cancel_test_executor()
	worker := exec.state.lane_workers[0]
	mut task := InProcVjsxLaneAffinityTask{ app: NoOpAppFacade{}, slot: &InProcVjsxLaneAffinityTaskSlot{}, done: chan bool{cap: 1} }
	lane := exec.select_next_lane() or { panic(err) }
	exec.submit_affinity_task(worker, task) or { panic(err) }
	assert exec.begin_task(mut task.slot.control, lane.id)
	exec.finish_task(mut task.slot.control)
	assert !exec.cancel_task(mut task.slot.control, 'late_timeout')
	exec.await_task(task.done, mut task.slot.control, time.Duration(0), 'late_timeout') or { panic(err) }
	next := exec.select_next_lane() or { panic(err) }
	exec.finish_task(mut task.slot.control)
	assert exec.state.lanes[0].inflight == 1
	select {
		_ := <-task.done {
			panic('duplicate completion')
		}
		else {
		}
	}
	exec.release_lane(next.id)
	exec.start_lane_workers()
	exec.close()
}

fn test_running_javascript_cancel_retires_poisoned_session_and_unblocks_close() {
	root := os.join_path(os.temp_dir(), 'vhttpd-task-cancel-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.mjs')
	os.write_file(entry, 'export function websocket(frame) { globalThis.__cancel_test_started(); while (true) {} }') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1, app_entry: entry, module_root: root, runtime_profile: 'script' })
	exec.ensure_lane_host(0) or { panic(err) }
	session := exec.state.hosts[0].session_handle() or { panic('missing session') }
	entered := chan bool{cap: 1}
	ctx := session.context()
	ctx.install_host_api(vjsx.HostApiConfig{
		globals: [vjsx.HostGlobalBinding{
			name:  '__cancel_test_started'
			value: fn [entered] (ctx &vjsx.Context) vjsx.Value {
				return ctx.js_function(fn [ctx, entered] (_args []vjsx.Value) vjsx.Value {
					entered <- true
					return ctx.js_undefined()
				})
			}
		}]
	})
	lane := exec.select_next_lane() or { panic(err) }
	mut task := InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, slot: &InProcVjsxWebSocketTaskSlot{}, done: chan bool{cap: 1}, started: chan bool{cap: 1} }
	exec.dispatch_websocket_task_to_lane(task, lane.id) or { panic(err) }
	select {
		_ := <-task.started {
		}
		3 * time.second {
			panic('task did not start')
		}
	}
	select {
		_ := <-entered {
		}
		3 * time.second {
			panic('JS did not enter handler')
		}
	}
	exec.await_task(task.done, mut task.slot.control, time.millisecond * 5, 'execution_expired') or { assert err.msg() == 'execution_expired' }
	finished_by := time.now().add(time.second * 3)
	for {
		task.slot.control.mu.@lock()
		finished := task.slot.control.phase == .cancelled
		task.slot.control.mu.unlock()
		if finished { break }
		assert time.now() < finished_by
		time.sleep(time.millisecond)
	}
	assert session.is_closed()
	exec.ensure_lane_host(0) or { panic(err) }
	fresh := exec.state.hosts[0].session_handle() or { panic('session not rebuilt') }
	assert voidptr(fresh) != voidptr(session)
	assert !fresh.is_interrupted()
	closed := chan bool{cap: 1}
	spawn cancel_test_close(exec, closed)
	select {
		_ := <-closed {
		}
		3 * time.second {
			panic('cancelled JS blocked close')
		}
	}
	assert session.is_closed()
	select {
		_ := <-task.done {
		}
		else {
			panic('missing cancellation notification')
		}
	}
	select {
		_ := <-task.done {
			panic('duplicate cancellation completion')
		}
		else {
		}
	}
	assert exec.state.tasks.len == 0
	assert exec.state.active_task_by_lane.len == 0
	assert exec.state.lanes[0].inflight == 0
}

fn cancel_test_close(exec InProcVjsxExecutor, done chan bool) {
	exec.close()
	done <- true
}

fn test_cancel_dispatched_mailbox_clears_running_key_without_late_lease_release() {
	mut exec := cancel_test_executor()
	mut task := InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, affinity_key: 'pinned', slot: &InProcVjsxWebSocketTaskSlot{}, done: chan bool{cap: 1}, started: chan bool{cap: 1} }
	// A pre-start worker lets the scheduler transfer a lease into its bounded queue.
	exec.state.lane_workers[0].started = true
	exec.enqueue_websocket_mailbox_task(task)
	assert 'pinned' in exec.state.websocket_mailbox_running_by_key
	assert exec.state.lanes[0].inflight == 1
	assert exec.cancel_task(mut task.slot.control, 'expired')
	assert exec.state.websocket_mailbox_running_by_key.len == 0
	assert exec.state.lanes[0].inflight == 0
	next := exec.select_next_lane() or { panic(err) }
	assert !exec.begin_task(mut task.slot.control, next.id)
	assert exec.state.lanes[0].inflight == 1
	exec.release_lane(next.id)
	exec.state.lane_workers[0].started = false
	exec.start_lane_workers()
	exec.close()
}

fn test_maintenance_task_does_not_borrow_or_cancel_another_lane_owner() {
	exec := cancel_test_executor()
	lane := exec.select_next_lane() or { panic(err) }
	worker := exec.state.lane_workers[0]
	mut task := InProcVjsxLanePumpTask{ slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }
	exec.submit_pump_task(worker, task) or { panic(err) }
	exec.start_lane_workers()
	exec.await_task(task.done, mut task.slot.control, 5 * time.millisecond, 'maintenance_expired') or {
		assert err.msg() == 'maintenance_expired'
	}
	assert !task.slot.ready
	assert exec.state.lanes[0].inflight == 1
	assert task.slot.control.session == none
	exec.release_lane(lane.id)
	exec.close()
}

fn test_affinity_release_cancels_removed_mailbox_instead_of_leaving_waiters() {
	for variant in 0 .. 4 {
		release_connection := variant % 2 == 0
		exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
		mut task := InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, affinity_key: 'released', slot: &InProcVjsxWebSocketTaskSlot{}, done: chan bool{cap: 1}, started: chan bool{cap: 1} }
		exec.enqueue_websocket_mailbox_task(task)
		if variant >= 2 {
			mut selected_state := exec.state
			_ := selected_state.take_websocket_mailbox_task() or { panic('task not selected') }
		}
		mut state := exec.state
		state.websocket_affinity_ref_count_by_key['released'] = 1
		if release_connection {
			state.websocket_connection_affinity_key_by_id['conn'] = 'released'
			exec.release_websocket_connection_affinity(transport.WorkerWebSocketFrame{ id: 'conn' })
		} else {
			exec.release_websocket_affinity_key('released')
		}
		exec.await_task(task.done, mut task.slot.control, time.millisecond, 'unexpected_timeout') or { assert err.msg() == 'inproc_vjsx_executor_websocket_affinity_released' }
		select {
			_ := <-task.started {
			}
			else {
				panic('start waiter was left pending')
			}
		}
		assert state.tasks.len == 0
		assert state.websocket_mailbox_by_key.len == 0
		exec.close()
	}
}

fn test_busy_maintenance_task_resumes_after_direct_owner_releases_lane() {
	exec := cancel_test_executor()
	lane := exec.select_next_lane() or { panic(err) }
	worker := exec.state.lane_workers[0]
	mut task := InProcVjsxLanePumpTask{ slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }
	exec.submit_pump_task(worker, task) or { panic(err) }
	exec.start_lane_workers()
	time.sleep(10 * time.millisecond)
	assert task_is_pending(task.slot.control)
	assert exec.state.lanes[0].inflight == 1
	exec.release_lane(lane.id)
	exec.await_task(task.done, mut task.slot.control, time.second, 'resume_timeout') or { panic(err) }
	assert task.slot.ready && task.slot.result.ok
	assert exec.state.lanes[0].inflight == 0
	exec.close()
}

fn test_close_and_repeated_cancel_publish_one_terminal_notification() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut task := InProcVjsxWebSocketTask{ app: NoOpAppFacade{}, affinity_key: 'close', slot: &InProcVjsxWebSocketTaskSlot{}, done: chan bool{cap: 1}, started: chan bool{cap: 1} }
	exec.enqueue_websocket_mailbox_task(task)
	exec.close()
	select {
		_ := <-task.done {
		}
		else {
			panic('missing completion')
		}
	}
	select {
		_ := <-task.started {
		}
		else {
			panic('missing start wakeup')
		}
	}
	exec.cancel_websocket_task(task)
	select {
		_ := <-task.done {
			panic('duplicate completion')
		}
		else {
		}
	}
	select {
		_ := <-task.started {
			panic('duplicate start wakeup')
		}
		else {
		}
	}
	assert task.slot.control.reason == 'inproc_vjsx_executor_closed'
}

fn cancel_test_public_dispatch(exec InProcVjsxExecutor, frame transport.WorkerWebSocketFrame, errors chan string) {
	mut app := &NoOpAppFacade{}
	_ := exec.dispatch_websocket_event_with_host(mut app, frame) or {
		errors <- err.msg()
		return
	}
	errors <- 'unexpected_success'
}

fn test_cancelled_open_and_close_remove_connection_affinity_and_actor_bindings() {
	for event in ['open', 'close'] {
		root := os.join_path(os.temp_dir(), 'vhttpd-event-cancel-${os.getpid()}-${event}-${time.now().unix_micro()}')
		os.mkdir_all(root) or { panic(err) }
		entry := os.join_path(root, 'app.mjs')
		os.write_file(entry, 'export function websocket(frame) { globalThis.__event_cancel_started(); while (true) {} }') or { panic(err) }
		exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:       1
			app_entry:          entry
			module_root:        root
			runtime_profile:    'script'
			websocket_affinity: app_config.WebSocketAffinityConfig{ enabled: true, source: 'query', key: 'room', scope: 'lane' }
		})
		exec.ensure_lane_host(0) or { panic(err) }
		session := exec.state.hosts[0].session_handle() or { panic('missing session') }
		entered := chan bool{cap: 1}
		ctx := session.context()
		ctx.install_host_api(vjsx.HostApiConfig{
			globals: [vjsx.HostGlobalBinding{
				name:  '__event_cancel_started'
				value: fn [entered] (ctx &vjsx.Context) vjsx.Value {
					return ctx.js_function(fn [ctx, entered] (_args []vjsx.Value) vjsx.Value {
						entered <- true
						return ctx.js_undefined()
					})
				}
			}]
		})
		frame := transport.WorkerWebSocketFrame{
			id:    'conn'
			event: event
			query: {
				'room': 'room'
			}
		}
		mut state := exec.state
		if event == 'close' {
			state.websocket_connection_lane_by_id['conn'] = 'lane_0'
			state.websocket_connection_affinity_key_by_id['conn'] = 'room'
			state.websocket_affinity_ref_count_by_key['room'] = 1
		}
		exec.cache_websocket_actor(frame, 'actor', 'test')
		errors := chan string{cap: 1}
		spawn cancel_test_public_dispatch(exec, frame, errors)
		select {
			_ := <-entered {
			}
			3 * time.second {
				panic('event did not start')
			}
		}
		state.mu.@lock()
		mut control := state.active_task_by_lane['lane_0'] or { panic('missing active task') }
		state.mu.unlock()
		assert exec.cancel_task(mut control, 'event_cancelled')
		select {
			error := <-errors {
				assert error == 'event_cancelled'
			}
			3 * time.second {
				panic('event waiter was left pending')
			}
		}
		assert state.websocket_connection_lane_by_id.len == 0
		assert state.websocket_connection_affinity_key_by_id.len == 0
		assert state.websocket_affinity_ref_count_by_key.len == 0
		assert state.websocket_connection_actor_key_by_id.len == 0
		exec.close()
		os.rmdir_all(root) or { panic(err) }
	}
}
