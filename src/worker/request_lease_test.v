module worker

import executor
import upstream.transport
import os
import net.unix
import time

fn slot_fixture(label string) (string, &WorkerState) {
	root := os.join_path(os.temp_dir(), 'vhttpd-slot-${label}-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	python := os.find_abs_path_of_executable('python3') or { panic(err) }
	script := root + '/peer.py'
	path := root + '/worker.sock'
	os.write_file(script, 'import os,socket,sys\np=sys.argv[1]\nif os.path.exists(p): os.unlink(p)\ns=socket.socket(socket.AF_UNIX); s.bind(p); s.listen()\nwhile True:\n c,_=s.accept()\n try: c.sendall(str(os.getpid()).encode()); c.recv(1)\n except OSError: pass\n c.close()\n') or { panic(err) }
	slot := transport.ManagedWorker.build_slot(1, '"${python}" -S "${script}" "{socket}"', {}, path, 1) or { panic(err) }
	mut state := &WorkerState{ worker_backend: WorkerBackendRuntime{ autostart: true, sockets: [path], managed_workers: [slot], queue_capacity: 2, queue_timeout_ms: 2000, queue_poll_ms: 1 } }
	state.ensure_slot(LifecyclePort{ emit_fn: fn (kind string, fields map[string]string) { eprintln('lease fixture ${kind}: ${fields}') } }, 0)
	assert state.worker_backend.managed_workers[0].proc != none
	return root, state
}

fn slot_cleanup(mut state WorkerState, root string) {
	state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{})
	os.rmdir_all(root) or {}
}

fn slot_read_pid(mut conn unix.StreamConn) int {
	mut bytes := []u8{len: 64}
	n := conn.read(mut bytes) or { panic(err) }
	return bytes[..n].bytestr().int()
}

fn slot_current_pid(state &WorkerState) int {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return (state.worker_backend.managed_workers[0].proc or { panic('missing process') }).pid
}

fn test_slot_request_completion_cannot_decrement_replacement_lease() {
	root, mut state := slot_fixture('completion')
	defer { slot_cleanup(mut state, root) }
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	mut conn := old.connect() or { panic(err) }
	assert slot_read_pid(mut conn) == slot_current_pid(state)
	if _ := old.connect() {
		panic('request lease dialed twice')
	} else {
		assert err.msg() == 'worker_request_lease_connected'
	}
	conn.close() or {}
	before := slot_current_pid(state)
	state.restart_slot(LifecyclePort{}, 0, 'test')
	assert slot_current_pid(state) != before
	mut next := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	old.finish(LifecyclePort{})
	old.release(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.worker_backend.managed_workers[0].served_requests == 0
	next.finish(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 1
}

fn test_selected_old_slot_cannot_dial_reused_socket_after_restart() {
	root, mut state := slot_fixture('dial')
	defer { slot_cleanup(mut state, root) }
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	state.restart_slot(LifecyclePort{}, 0, 'test')
	if _ := old.connect() {
		panic('obsolete lease dialed new process')
	} else {
		assert err.msg() == 'worker_slot_restarted'
	}
	mut next := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	mut conn := next.connect() or { panic(err) }
	assert slot_read_pid(mut conn) == slot_current_pid(state)
	conn.close() or {}
	old.release(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	next.release(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].served_requests == 0
}

fn test_duplicate_concurrent_slot_completions_settle_once() {
	root, mut state := slot_fixture('duplicate')
	defer { slot_cleanup(mut state, root) }
	mut lease := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	done := chan bool{cap: 16}
	for _ in 0 .. 16 {
		spawn fn [mut lease, done] () {
			lease.finish(LifecyclePort{})
			done <- true
		}()
	}
	for _ in 0 .. 16 { _ := <-done }
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 1
	if _ := lease.connect() {
		panic('completed lease was reused')
	} else {
		assert err.msg() == 'worker_request_lease_completed'
	}
}

fn test_deferred_max_request_restart_does_not_restart_new_generation() {
	root, mut state := slot_fixture('max-requests')
	defer { slot_cleanup(mut state, root) }
	state.worker_backend.max_requests = 1
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	port := LifecyclePort{
		emit_fn: fn [mut state] (kind string, fields map[string]string) {
			if kind == 'worker.max_requests_reached' {
				state.restart_slot(LifecyclePort{}, 0, 'admin-won')
			}
		}
	}
	count := state.worker_backend.managed_workers[0].restart_count
	old.finish(port)
	assert state.worker_backend.managed_workers[0].restart_count == count + 1
	assert state.worker_backend.managed_workers[0].served_requests == 0
	assert !state.worker_backend.managed_workers[0].draining
}

fn test_failed_slot_restart_revokes_selection_and_clears_old_counts() {
	root, mut state := slot_fixture('failure')
	defer { slot_cleanup(mut state, root) }
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	state.worker_backend.managed_workers[0].worker_cmd = 'exit 0'
	// The exited replacement must not make the old slot selectable again.
	state.restart_slot(LifecyclePort{}, 0, 'expected_failure')
	assert state.worker_backend.managed_workers[0].proc == none
	assert state.lease_idle_request() == none
	old.finish(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 0
}

fn test_backend_stop_revokes_selected_slot_before_native_dial() {
	root, mut state := slot_fixture('stop')
	defer { os.rmdir_all(root) or {} }
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	state.stop_backend(executor.disabled_executor_lifecycle(), LifecyclePort{})
	if _ := old.connect() {
		panic('stopped slot was dialed')
	} else {
		assert err.msg() == 'worker_slot_restarted'
	}
	old.finish(LifecyclePort{})
	assert state.worker_backend.managed_workers.len == 0
}

fn test_queued_request_uses_new_slot_without_old_completion_releasing_it() {
	root, mut state := slot_fixture('queued')
	defer { slot_cleanup(mut state, root) }
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	result := chan &RequestLease{cap: 1}
	spawn fn [mut state, result] () {
		lease := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
		result <- lease
	}()
	deadline := time.now().add(time.second)
	for {
		state.mu.@lock()
		waiting := state.worker_backend.queue_waiting_requests
		state.mu.unlock()
		if waiting == 1 { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	state.restart_slot(LifecyclePort{}, 0, 'queued')
	mut acquired := ?&RequestLease(none)
	select {
		lease := <-result {
			acquired = lease
		}
		3 * time.second {
			panic('queued request did not acquire replacement')
		}
	}
	mut next := acquired or { panic('missing queued lease') }
	old.finish(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	next.finish(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].served_requests == 1
	assert state.worker_backend.queue_waiting_requests == 0
}

fn test_slot_retirement_waits_for_dial_fence_without_lock_inversion() {
	root, mut state := slot_fixture('fence')
	defer { slot_cleanup(mut state, root) }
	mut old := state.select_request_queued(LifecyclePort{}, 'php') or { panic(err) }
	old.generation.mu.@lock()
	mut released := false
	defer { if !released { old.generation.mu.unlock() } }
	done := chan bool{cap: 1}
	spawn fn [mut state, done] () {
		state.restart_slot(LifecyclePort{}, 0, 'fence')
		done <- true
	}()
	deadline := time.now().add(time.second)
	for {
		if state.mu.try_lock() { state.mu.unlock() } else { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	select {
		_ := <-done {
			panic('restart skipped active dial fence')
		}
		20 * time.millisecond {
		}
	}
	old.generation.mu.unlock()
	released = true
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('slot fence deadlocked')
		}
	}
	if _ := old.connect() { panic('retired fence admitted old dial') }
	old.release(LifecyclePort{})
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
}

fn test_concurrent_slot_finish_waits_until_accounting_has_completed() {
	mut state := &WorkerState{ worker_backend: WorkerBackendRuntime{ sockets: ['fake.sock'], managed_workers: [transport.ManagedWorker{ socket_path: 'fake.sock' }] } }
	mut lease := state.lease_idle_request() or { panic('lease') }
	state.mu.@lock()
	mut unlocked := false
	defer { if !unlocked { state.mu.unlock() } }
	first := chan bool{cap: 1}
	second := chan bool{cap: 1}
	spawn fn [mut lease, first] () {
		lease.finish(LifecyclePort{})
		first <- true
	}()
	deadline := time.now().add(time.second)
	for {
		lease.mu.@lock()
		claimed := lease.completed
		lease.mu.unlock()
		if claimed { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	spawn fn [mut lease, second] () {
		lease.finish(LifecyclePort{})
		second <- true
	}()
	select {
		_ := <-second {
			panic('duplicate finish skipped accounting join')
		}
		20 * time.millisecond {
		}
	}
	state.mu.unlock()
	unlocked = true
	select {
		_ := <-first {
		}
		time.second {
			panic('first completion did not finish')
		}
	}
	select {
		_ := <-second {
		}
		time.second {
			panic('duplicate completion did not join')
		}
	}
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 1
}
