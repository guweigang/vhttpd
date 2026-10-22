module worker

import os
import time
import upstream.transport

fn worker_unix_fd_count() int { return (os.ls('/dev/fd') or { panic(err) }).len }

fn worker_unix_missing_path() string {
	return '/tmp/vhttpd-worker-dial-${os.getpid()}-${time.sys_mono_now()}.sock'
}

fn test_failed_worker_selection_and_diagnostics_do_not_retain_probe_fds() {
	path := worker_unix_missing_path()
	mut state := &WorkerState{ worker_backend: WorkerBackendRuntime{ sockets: [path], managed_workers: [transport.ManagedWorker{ socket_path: path }] } }
	before := worker_unix_fd_count()
	for _ in 0 .. 32 {
		if _ := state.select_request_core(LifecyclePort{}, 'php') {
			panic('selected absent worker')
		}
		diagnostics := state.selection_diagnostics()
		assert diagnostics.len == 1
		assert diagnostics[0].probe_error != ''
	}
	assert worker_unix_fd_count() == before
}

fn test_failed_lease_dials_release_fds_and_preserve_idempotent_accounting() {
	path := worker_unix_missing_path()
	mut state := &WorkerState{ worker_backend: WorkerBackendRuntime{ sockets: [path], managed_workers: [transport.ManagedWorker{ socket_path: path }] } }
	before := worker_unix_fd_count()
	for _ in 0 .. 32 {
		mut lease := state.lease_idle_request() or { panic('no lease') }
		for _ in 0 .. 2 {
			if mut unexpected := lease.connect() {
				unexpected.close() or {}
				panic('connected absent worker')
			}
		}
		assert !lease.dialed
		lease.release(LifecyclePort{})
		lease.release(LifecyclePort{})
		assert state.worker_backend.managed_workers[0].inflight_requests == 0
	}
	assert worker_unix_fd_count() == before
	assert state.worker_backend.managed_workers[0].served_requests == 0
}

fn test_worker_readiness_retries_do_not_retain_failed_dial_fds() {
	path := worker_unix_missing_path()
	before := worker_unix_fd_count()
	for _ in 0 .. 4 {
		mut failed := false
		transport.ManagedWorker.wait_for_socket(path, 1) or { failed = true }
		assert failed
	}
	assert worker_unix_fd_count() == before
}
