module worker

import executor
import net.unix
import os
import time
import upstream.transport
import process_runtime

fn backend_test_wait(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			assert false, 'backend operation did not complete'
		}
	}
}

fn backend_test_start(mut state WorkerState, lifecycle executor.LogicExecutorLifecycle, done chan bool) {
	state.start_backend(lifecycle, LifecyclePort{})
	done <- true
}

fn backend_test_stop(mut state WorkerState, lifecycle executor.LogicExecutorLifecycle, done chan bool) {
	state.stop_backend(lifecycle, LifecyclePort{})
	done <- true
}

fn test_backend_stop_waits_for_start_and_retires_late_process() {
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	stopped := chan bool{cap: 2}
	started := chan bool{cap: 1}
	pid_chan := chan int{cap: 1}
	mut state := &WorkerState{}
	lifecycle := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		start_fn: fn [entered, release, pid_chan] (mut ctx executor.LifecycleRuntimeContext) {
			entered <- true
			_ := <-release
			proc := transport.ManagedWorker.launch_process('exec sleep 30', {}, '') or { panic(err) }
			pid_chan <- proc.pid
			ctx.worker_backend_managed_workers = [transport.ManagedWorker{ id: 42, proc: proc }]
		}
		stop_fn:  fn (mut ctx executor.LifecycleRuntimeContext) {
			transport.ManagedWorkerPool.stop(mut ctx.worker_backend_managed_workers)
			ctx.worker_backend_managed_workers = []transport.ManagedWorker{}
		}
	}
	spawn backend_test_start(mut state, lifecycle, started)
	backend_test_wait(entered)
	spawn backend_test_stop(mut state, lifecycle, stopped)
	// The old implementation returns stop while startup still owns future resources.
	mut returned_early := false
	select {
		_ := <-stopped {
			returned_early = true
		}
		40 * time.millisecond {
		}
	}
	release <- true
	backend_test_wait(started)
	if !returned_early { backend_test_wait(stopped) }
	pid := <-pid_chan
	// Always clean up even on the old implementation before reporting the failure.
	state.mu.@lock()
	mut remaining := state.worker_backend.managed_workers.clone()
	count := remaining.len
	state.mu.unlock()
	leaked := pid in process_runtime.managed_process_pids()
	transport.ManagedWorkerPool.stop(mut remaining)
	assert !returned_early
	assert !leaked
	assert count == 0
}

fn test_backend_concurrent_start_is_once_and_waits_for_publication() {
	entered := chan bool{cap: 2}
	release := chan bool{cap: 2}
	done := chan bool{cap: 2}
	mut state := &WorkerState{}
	lifecycle := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		start_fn: fn [entered, release] (mut ctx executor.LifecycleRuntimeContext) {
			entered <- true
			_ := <-release
			ctx.worker_backend_managed_workers = [transport.ManagedWorker{ id: 17 }]
		}
	}
	spawn backend_test_start(mut state, lifecycle, done)
	backend_test_wait(entered)
	spawn backend_test_start(mut state, lifecycle, done)
	mut duplicate := false
	select {
		_ := <-entered {
			duplicate = true
		}
		40 * time.millisecond {
		}
	}
	release <- true
	release <- true
	backend_test_wait(done)
	backend_test_wait(done)
	assert !duplicate
	assert state.worker_backend.managed_workers.len == 1
	assert state.worker_backend.managed_workers[0].id == 17
	state.stop_backend(lifecycle, LifecyclePort{})
}

fn test_backend_stop_is_terminal_and_uses_starting_lifecycle() {
	calls := chan string{cap: 8}
	mut state := WorkerState{}
	owned := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		start_fn: fn [calls] (mut ctx executor.LifecycleRuntimeContext) { calls <- 'start' }
		stop_fn:  fn [calls] (mut ctx executor.LifecycleRuntimeContext) { calls <- 'owned_stop' }
	}
	other := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		stop_fn: fn [calls] (mut ctx executor.LifecycleRuntimeContext) { calls <- 'other_stop' }
	}
	state.start_backend(owned, LifecyclePort{})
	state.stop_backend(other, LifecyclePort{})
	state.stop_backend(other, LifecyclePort{})
	state.start_backend(owned, LifecyclePort{})
	assert <-calls == 'start'
	assert <-calls == 'owned_stop'
	assert calls.len == 0
}

fn test_stopped_backend_cannot_restart_slot_or_grant_lease() {
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			autostart:       true
			sockets:         ['retired.sock']
			managed_workers: [transport.ManagedWorker{ id: 1, socket_path: 'retired.sock' }]
		}
	}
	state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{})
	assert state.next_socket() == none
	assert state.lease_idle_socket() == none
	assert !state.request_started('retired.sock')
	if _ := state.select_socket_queued(LifecyclePort{}, 'php') {
		assert false
	} else {
		assert err.msg() == 'worker_backend_stopping'
	}
	assert state.worker_backend.managed_workers.len == 0
}

fn test_backend_concurrent_stops_join_one_detached_context() {
	entered := chan bool{cap: 2}
	release := chan bool{cap: 2}
	done := chan bool{cap: 2}
	mut state := &WorkerState{
		worker_backend: WorkerBackendRuntime{
			managed_workers: [transport.ManagedWorker{ id: 91 }]
		}
	}
	lifecycle := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		stop_fn: fn [mut state, entered, release] (mut ctx executor.LifecycleRuntimeContext) {
			assert ctx.worker_backend_managed_workers.len == 1
			assert ctx.worker_backend_managed_workers[0].id == 91
			assert state.metrics().queue_depth == 0
			assert state.drain_status('php').worker_count == 0
			entered <- true
			_ := <-release
		}
	}
	spawn backend_test_stop(mut state, lifecycle, done)
	backend_test_wait(entered)
	spawn backend_test_stop(mut state, lifecycle, done)
	mut returned_early := false
	select {
		_ := <-done {
			returned_early = true
		}
		40 * time.millisecond {
		}
	}
	release <- true
	backend_test_wait(done)
	if !returned_early { backend_test_wait(done) }
	assert !returned_early
	assert entered.len == 0
	assert state.worker_backend.managed_workers.len == 0
}

fn test_backend_stop_before_start_retires_custom_callback_leftovers() {
	proc := transport.ManagedWorker.launch_process('exec sleep 30', {}, '') or { panic(err) }
	pid := proc.pid
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			managed_workers: [transport.ManagedWorker{ id: 1, proc: proc }]
		}
	}
	state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{})
	assert pid !in process_runtime.managed_process_pids()
	assert state.worker_backend.managed_workers.len == 0
	calls := chan bool{cap: 1}
	lifecycle := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		start_fn: fn [calls] (mut ctx executor.LifecycleRuntimeContext) { calls <- true }
	}
	state.start_backend(lifecycle, LifecyclePort{})
	assert calls.len == 0
}

fn test_backend_start_context_is_exclusive_and_preserves_live_config() {
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	mut state := &WorkerState{
		worker_backend: WorkerBackendRuntime{
			sockets:         ['one.sock']
			env:             {
				'key': 'original'
			}
			managed_workers: [transport.ManagedWorker{ id: 71, socket_path: 'one.sock' }]
		}
	}
	lifecycle := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		start_fn: fn [mut state, entered, release] (mut ctx executor.LifecycleRuntimeContext) {
			assert ctx.worker_backend_managed_workers.len == 1
			assert ctx.worker_backend_managed_workers[0].id == 71
			assert state.metrics().pool_size == 1
			assert state.next_socket() == none
			assert !state.request_started('one.sock')
			assert state.drain_status('php').worker_count == 0
			entered <- true
			_ := <-release
			assert ctx.worker_backend_env['key'] == 'original'
			ctx.worker_backend_env['key'] = 'context-only'
			ctx.worker_backend_managed_workers[0].served_requests = 7
		}
	}
	spawn backend_test_start(mut state, lifecycle, done)
	backend_test_wait(entered)
	state.set_env('key', 'live')
	state.apply_scheme('https')
	if _ := state.select_socket_queued(LifecyclePort{}, 'php') {
		assert false
	} else {
		assert err.msg() == 'worker_backend_starting'
	}
	release <- true
	backend_test_wait(done)
	assert state.env_snapshot()['key'] == 'live'
	assert state.env_snapshot()['VHTTPD_SCHEME'] == 'https'
	assert state.worker_backend.managed_workers[0].served_requests == 7
	assert state.request_started('one.sock')
	state.stop_backend(lifecycle, LifecyclePort{})
}

fn backend_test_set_schemes(mut state WorkerState, done chan bool) {
	for i in 0 .. 2000 { state.apply_scheme(if i % 2 == 0 { 'https' } else { 'http' }) }
	done <- true
}

fn test_backend_scheme_snapshot_is_atomic_and_states_are_independent() {
	mut state := &WorkerState{}
	state.apply_scheme('http')
	done := chan bool{cap: 1}
	spawn backend_test_set_schemes(mut state, done)
	for _ in 0 .. 2000 {
		mut env := state.env_snapshot()
		assert env['VHTTPD_SCHEME'] == env['VHTTPD_REQUEST_SCHEME']
		env['VHTTPD_SCHEME'] = 'snapshot-only'
	}
	backend_test_wait(done)
	mut other := WorkerState{ worker_backend: WorkerBackendRuntime{ sockets: ['live.sock'] } }
	state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{})
	assert (other.next_socket() or { panic('missing other state socket') }) == 'live.sock'
	assert state.next_socket() == none
}

fn test_stopped_backend_connector_returns_without_retry() {
	calls := chan bool{cap: 20}
	ctx := ConnectorContext{
		connect_fn:       unix.connect_stream
		select_socket_fn: fn [calls] () !string {
			calls <- true
			return error('worker_backend_stopping')
		}
		release_fn:       fn (_socket string) {
			assert false
		}
		emit_fn:          fn (_kind string, _fields map[string]string) {
			assert false
		}
	}
	if _ := ConnectorRuntime.socket_with_retry(ctx) {
		assert false
	} else {
		assert err.msg() == 'worker_backend_stopping'
	}
	assert calls.len == 1
	if _, _ := ConnectorRuntime.connect_selected(ctx) {
		assert false
	} else {
		assert err.msg() == 'worker_backend_stopping'
	}
	assert calls.len == 2
}

fn test_backend_admin_restart_can_race_callback_stop_without_stale_index() {
	path := os.join_path(os.temp_dir(), 'vhttpd-backend-admin-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	proc := transport.ManagedWorker.launch_process('exec sleep 30', {}, '') or { panic(err) }
	mut state := &WorkerState{
		worker_backend: WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			managed_workers: [transport.ManagedWorker{
				id:          31
				socket_path: path
				worker_cmd:  'sleep 30'
				proc:        proc
			}]
		}
	}
	defer { state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{}) }
	port := LifecyclePort{
		emit_fn: fn [mut state] (_kind string, _fields map[string]string) {
			state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{})
		}
	}
	if _ := state.restart_by_id(port, 31) {
		assert false
	} else {
		assert err.msg() == 'worker_backend_stopping'
	}
	assert state.worker_backend.managed_workers.len == 0
	assert state.restart_all(port) == 0
}
