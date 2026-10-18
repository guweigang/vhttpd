module process_runtime

import os
import time

fn test_retirement_unregisters_pid_and_rejects_stale_handle_identity() {
	mut registry := ManagedProcessRegistry{}
	mut proc := registry.launch(LaunchConfig{ command: 'exec sleep 30' }) or { panic(err) }
	assert registry.snapshot() == [proc.pid]
	mut stale := &os.Process{ pid: proc.pid }
	registry.retire(mut stale, false)
	assert registry.alive(mut proc)
	assert registry.snapshot() == [proc.pid]
	registry.retire(mut proc, false)
	assert registry.snapshot().len == 0
	registry.retire(mut proc, false)
	assert proc.status == .closed
}

fn test_natural_exit_is_pruned_and_reaped_before_pid_reuse() {
	mut registry := ManagedProcessRegistry{}
	mut proc := registry.launch(LaunchConfig{ command: 'exit 0' }) or { panic(err) }
	deadline := time.now().add(3 * time.second)
	for registry.alive(mut proc) && time.now() < deadline { time.sleep(10 * time.millisecond) }
	assert registry.snapshot().len == 0
	assert proc.status == .closed
}

fn test_shutdown_drains_registry_and_prevents_new_launches() {
	mut registry := ManagedProcessRegistry{}
	mut one := registry.launch(LaunchConfig{ command: 'exec sleep 30' }) or { panic(err) }
	mut two := registry.launch(LaunchConfig{ command: 'exec sleep 30' }) or { panic(err) }
	registry.shutdown()
	registry.shutdown()
	assert registry.snapshot().len == 0
	assert one.status == .closed
	assert two.status == .closed
	mut rejected := false
	_ := registry.launch(LaunchConfig{ command: 'exit 0' }) or {
		assert err.msg() == 'managed_process_registry_stopping'
		rejected = true
		&os.Process{}
	}
	assert rejected
}

fn test_concurrent_registration_and_retirement_leave_no_stale_pids() {
	mut registry := &ManagedProcessRegistry{}
	done := chan bool{cap: 8}
	for _ in 0 .. 8 {
		spawn fn [mut registry, done] () {
			mut proc := registry.launch(LaunchConfig{ command: 'exec sleep 30' }) or { panic(err) }
			assert registry.alive(mut proc)
			registry.retire(mut proc, false)
			done <- true
		}()
	}
	for _ in 0 .. 8 { _ := <-done }
	assert registry.snapshot().len == 0
}

fn test_signal_pipe_transfers_signal_without_registry_access() {
	fds := C.vhttpd_signal_pipe_create()
	assert fds.read_fd >= 0 && fds.write_fd >= 0
	defer {
		C.close(fds.read_fd)
		C.close(fds.write_fd)
	}
	C.vhttpd_signal_pipe_notify(fds.write_fd, int(os.Signal.term))
	C.vhttpd_signal_pipe_notify(fds.write_fd, int(os.Signal.int))
	assert C.vhttpd_signal_pipe_ready(fds.read_fd, 1000) == 1
	assert C.vhttpd_signal_pipe_wait(fds.read_fd) == int(os.Signal.term)
	assert C.vhttpd_signal_pipe_ready(fds.read_fd, 1000) == 1
	assert C.vhttpd_signal_pipe_wait(fds.read_fd) == int(os.Signal.int)
}
