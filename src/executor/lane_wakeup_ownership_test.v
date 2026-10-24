module executor

import os
import time
import vjsx

fn wakeup_published_owner(mut state VjsxExecutorState, lane_id string) !&VjsxLaneWakeupOwner {
	mut owner := state.new_lane_wakeup_owner(lane_id)!
	state.mu.@lock()
	owner.published = true
	state.mu.unlock()
	return owner
}

fn wakeup_assert_counts(mut state VjsxExecutorState, jobs int, pending int, owners int) {
	state.mu.@lock()
	defer { state.mu.unlock() }
	assert state.lane_wakeup_workers == jobs
	assert state.lane_wakeup_by_id.len == pending
	assert state.lane_wakeup_owners.len == owners
}

fn wakeup_await(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('wakeup cleanup did not finish')
		}
	}
}

fn test_identical_timer_replacement_has_distinct_identity_and_one_completion() {
	mut state := &VjsxExecutorState{}
	owner := wakeup_published_owner(mut state, 'lane') or { panic(err) }
	at := time.now().unix_milli() + 60_000
	mut old := owner.reserve(at, 0) or { panic('missing old job') }
	mut next := owner.reserve(at, 0) or { panic('missing new job') }
	assert voidptr(old) != voidptr(next)
	assert !old.claim()
	old.finish()
	old.finish()
	wakeup_assert_counts(mut state, 1, 1, 1)
	assert next.claim()
	assert !next.claim()
	next.finish()
	owner.retire()
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn test_retired_session_callbacks_cannot_cancel_or_reschedule_replacement_timer() {
	mut state := &VjsxExecutorState{}
	old := wakeup_published_owner(mut state, 'lane') or { panic(err) }
	mut old_job := old.reserve(100, 1) or { panic('missing old job') }
	next := wakeup_published_owner(mut state, 'lane') or { panic(err) }
	mut next_job := next.reserve(100, 1) or { panic('missing new job') }
	old.cancel(1)
	old.retire()
	old.schedule(100, 1)
	assert old.reserve(100, 1) == none
	assert !old_job.claim()
	old_job.finish()
	wakeup_assert_counts(mut state, 1, 1, 1)
	assert next_job.claim()
	next_job.finish()
	next.retire()
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn test_timer_generation_cancellation_preserves_other_generations() {
	mut state := &VjsxExecutorState{}
	owner := wakeup_published_owner(mut state, 'lane') or { panic(err) }
	mut job := owner.reserve(100, 3) or { panic('missing job') }
	owner.cancel(2)
	wakeup_assert_counts(mut state, 1, 1, 1)
	owner.cancel(3)
	assert !job.claim()
	job.finish()
	owner.retire()
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn test_concurrent_close_waits_for_reserved_wakeup_before_spawn() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	mut state := exec.state
	owner := wakeup_published_owner(mut state, 'lane_0') or { panic(err) }
	job := owner.reserve(time.now().unix_milli() + 60_000, 1) or { panic('missing job') }
	done := chan bool{cap: 2}
	for _ in 0 .. 2 {
		spawn fn [exec, done] () {
			exec.close()
			done <- true
		}()
	}
	deadline := time.now().add(time.second)
	for !exec.is_stopping() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	wakeup_assert_counts(mut state, 1, 0, 0)
	assert owner.reserve(0, 1) == none
	select {
		_ := <-done {
			panic('close skipped delayed wakeup task')
		}
		20 * time.millisecond {
		}
	}
	spawn job.deliver()
	wakeup_await(done)
	wakeup_await(done)
	wakeup_assert_counts(mut state, 0, 0, 0)
	state.mu.@lock()
	assert state.closed
	state.mu.unlock()
}

fn test_close_joins_long_sleepers_and_replaced_wakeup_jobs() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	mut state := exec.state
	owner := wakeup_published_owner(mut state, 'lane_0') or { panic(err) }
	for i in 0 .. 100 { owner.schedule(time.now().unix_milli() + 60_000, u64(i)) }
	done := chan bool{cap: 1}
	spawn fn [exec, done] () {
		exec.close()
		done <- true
	}()
	wakeup_await(done)
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn test_lane_reset_retires_callback_scope_before_destroying_old_host() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	defer { exec.close() }
	mut state := exec.state
	owner := wakeup_published_owner(mut state, 'lane_0') or { panic(err) }
	mut job := owner.reserve(time.now().unix_milli() + 60_000, 1) or { panic('missing job') }
	state.mu.@lock()
	state.hosts[0].wakeup_owner = owner
	state.mu.unlock()
	exec.reset_lane_host(0)
	assert owner.reserve(0, 1) == none
	assert !job.claim()
	job.finish()
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn wakeup_js_number(mut session_context vjsx.Context) int {
	mut value := session_context.eval('globalThis.pumped') or { panic(err) }
	defer { value.free() }
	return value.to_int()
}

fn wakeup_prepare_cross_thread_completion(host VjsxLaneHost) vjsx.RuntimeHostAsyncCompletionPort {
	ctx := host.context()
	mut session := host.session_handle() or { panic('missing session') }
	operation := session.start_host_async_operation(kind: 'cross-thread-wakeup') or { panic(err) }
	global := ctx.js_global()
	global.set('__wakeupPromise', operation.promise)
	global.free()
	operation.promise.free()
	setup := ctx.eval('globalThis.pumped = 0; __wakeupPromise.then(() => { globalThis.pumped = 1; });') or { panic(err) }
	setup.free()
	return operation.completion
}

fn wakeup_complete_on_another_thread(exec InProcVjsxExecutor, port vjsx.RuntimeHostAsyncCompletionPort) {
	assert port.resolve_text('ready')
	mut task := InProcVjsxLanePumpTask{ slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }
	InProcVjsxLaneWorkerRuntime.handle_pump_task(exec, 'lane_0', mut task)
	assert task.slot.ready && task.slot.result.ok
	host := exec.state.hosts[0]
	mut ctx := host.context()
	assert wakeup_js_number(mut ctx) == 1
}

fn test_idle_async_completion_refreshes_stack_when_lane_changes_native_thread() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	defer { exec.close() }
	session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{ runtime_profile: 'script' }) or { panic(err) }
	// Keep a real stack guard, small enough that distinct native thread stacks
	// cannot accidentally share the default 16 MiB allowance on ARM runners.
	session.runtime().set_max_stack_size_bytes(128 * 1024)
	mut state := exec.state
	state.mu.@lock()
	state.hosts[0] = VjsxLaneHost{ session: session }
	host := state.hosts[0]
	state.mu.unlock()
	port := wakeup_prepare_cross_thread_completion(host)
	worker := spawn wakeup_complete_on_another_thread(exec, port)
	worker.wait()
	// Exercise the reverse transfer too: stack address ordering varies by OS.
	producer := spawn wakeup_prepare_cross_thread_completion(host)
	next := producer.wait()
	wakeup_complete_on_another_thread(exec, next)
}

fn test_queued_old_scope_pump_cannot_run_replacement_session_jobs() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	defer { exec.close() }
	mut state := exec.state
	old := wakeup_published_owner(mut state, 'lane_0') or { panic(err) }
	next := wakeup_published_owner(mut state, 'lane_0') or { panic(err) }
	mut session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{ runtime_profile: 'script' }) or { panic(err) }
	mut ctx := session.context()
	mut value := ctx.eval('globalThis.pumped = 0; Promise.resolve().then(() => globalThis.pumped = 1);') or { panic(err) }
	value.free()
	state.mu.@lock()
	state.hosts[0] = VjsxLaneHost{ session: session, wakeup_owner: next }
	state.mu.unlock()
	mut stale := InProcVjsxLanePumpTask{ wakeup_owner: old, slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }
	InProcVjsxLaneWorkerRuntime.handle_pump_task(exec, 'lane_0', mut stale)
	assert stale.slot.ready && stale.slot.result.ok
	assert wakeup_js_number(mut ctx) == 0
	mut current := InProcVjsxLanePumpTask{ wakeup_owner: next, slot: &InProcVjsxLanePumpTaskSlot{}, done: chan bool{cap: 1} }
	InProcVjsxLaneWorkerRuntime.handle_pump_task(exec, 'lane_0', mut current)
	assert current.slot.ready && current.slot.result.ok
	assert wakeup_js_number(mut ctx) == 1
}

fn test_failed_host_bootstrap_retires_its_timer_callback_scope() {
	root := os.join_path(os.temp_dir(), 'vhttpd-wakeup-failure-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'entry.js')
	os.write_file(entry, 'setTimeout(() => {}, 60000); throw new Error("bootstrap failed");') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1, app_entry: entry, module_root: root, runtime_profile: 'node' })
	mut failed := false
	exec.ensure_lane_host(0) or { failed = true }
	assert failed
	exec.close()
	mut state := exec.state
	wakeup_assert_counts(mut state, 0, 0, 0)
	state.mu.@lock()
	assert state.hosts[0].wakeup_owner == none
	assert state.hosts[0].session_handle() == none
	state.mu.unlock()
}

fn test_due_timer_waits_for_host_publication_before_dispatch() {
	mut state := &VjsxExecutorState{}
	mut owner := state.new_lane_wakeup_owner('building') or { panic(err) }
	job := owner.reserve(time.now().unix_milli() - 1, 1) or { panic('missing job') }
	assert !job.claim()
	done := chan bool{cap: 1}
	spawn fn [job, done] () {
		job.deliver()
		done <- true
	}()
	select {
		_ := <-done {
			panic('timer ran before host publication')
		}
		20 * time.millisecond {
		}
	}
	wakeup_assert_counts(mut state, 1, 1, 1)
	state.mu.@lock()
	owner.published = true
	state.mu.unlock()
	wakeup_await(done)
	owner.retire()
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn test_async_wakeup_is_coalesced_without_replacing_or_cancelling_timer() {
	mut state := &VjsxExecutorState{}
	// Unpublished ownership keeps the async worker from dispatching while this
	// test checks the two independently protected pending slots.
	owner := state.new_lane_wakeup_owner('building') or { panic(err) }
	mut timer := owner.reserve(time.now().unix_milli() + 60_000, 3) or { panic('missing timer') }
	owner.schedule_async()
	owner.schedule_async()
	state.mu.@lock()
	async_job := owner.async_job or { panic('missing async job') }
	assert state.lane_wakeup_workers == 2
	assert timer.current_locked()
	assert async_job.current_locked()
	state.mu.unlock()
	owner.cancel(3)
	state.mu.@lock()
	assert !timer.current_locked()
	assert async_job.current_locked()
	state.mu.unlock()
	owner.retire()
	timer.finish()
	deadline := time.now().add(time.second)
	for {
		state.mu.@lock()
		pending := state.lane_wakeup_workers
		state.mu.unlock()
		if pending == 0 { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	owner.schedule_async()
	wakeup_assert_counts(mut state, 0, 0, 0)
}

fn test_old_async_ready_callback_cannot_replace_new_session_completion_wakeup() {
	mut state := &VjsxExecutorState{}
	old := state.new_lane_wakeup_owner('lane') or { panic(err) }
	old.schedule_async()
	next := state.new_lane_wakeup_owner('lane') or { panic(err) }
	next.schedule_async()
	state.mu.@lock()
	job := next.async_job or { panic('missing replacement async job') }
	state.mu.unlock()
	old.schedule_async()
	old.cancel(0)
	old.retire()
	state.mu.@lock()
	assert job.current_locked()
	state.mu.unlock()
	next.retire()
	deadline := time.now().add(time.second)
	for {
		state.mu.@lock()
		pending := state.lane_wakeup_workers
		state.mu.unlock()
		if pending == 0 { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	wakeup_assert_counts(mut state, 0, 0, 0)
}
