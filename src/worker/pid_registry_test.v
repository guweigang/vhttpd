module worker

import os
import process_runtime
import time
import upstream.transport

fn test_worker_restart_failure_and_retry_update_process_registry() {
	path := '/tmp/vhttpd-pid-${os.getpid()}-${time.now().unix_micro()}.sock'
	old := transport.ManagedWorker.launch_process('exec sleep 30', {}, '') or { panic(err) }
	old_pid := old.pid
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			autostart:       true
			managed_workers: [transport.ManagedWorker{ proc: old, worker_cmd: 'exit 0', socket_path: path }]
		}
	}
	assert old_pid in process_runtime.managed_process_pids()
	state.restart_slot(LifecyclePort{}, 0, 'test failure')
	assert old_pid !in process_runtime.managed_process_pids()
	assert state.worker_backend.managed_workers[0].proc == none
	assert process_runtime.managed_process_pids().len == 0
	state.worker_backend.managed_workers[0].next_retry_ts = 0
	state.ensure_slot(LifecyclePort{}, 0)
	assert state.worker_backend.managed_workers[0].proc == none
	assert process_runtime.managed_process_pids().len == 0
}

fn test_initial_worker_readiness_failure_removes_registered_pid() {
	path := '/tmp/vhttpd-initial-pid-${os.getpid()}-${time.now().unix_micro()}.sock'
	mut failed := false
	_ := transport.ManagedWorker.start(0, 'exit 0', {}, path, '', 1) or {
		failed = true
		transport.ManagedWorker{}
	}
	assert failed
	assert process_runtime.managed_process_pids().len == 0
}

fn test_successful_worker_restart_replaces_pid_and_stop_removes_it() {
	root := '/tmp/vhttpd-pid-restart-${os.getpid()}-${time.now().unix_micro()}'
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	script := root + '/worker.py'
	socket := root + '/worker.sock'
	os.write_file(script, 'import os, socket, sys\np = sys.argv[1]\nif os.path.exists(p): os.unlink(p)\ns = socket.socket(socket.AF_UNIX)\ns.bind(p)\ns.listen()\nwhile True:\n c, _ = s.accept()\n c.close()\n') or { panic(err) }
	slot := transport.ManagedWorker.build_slot(0, 'python3 ${script} {socket}', {}, socket, 1) or { panic(err) }
	mut state := WorkerState{ worker_backend: WorkerBackendRuntime{ autostart: true, managed_workers: [slot] } }
	defer { transport.ManagedWorkerPool.stop(mut state.worker_backend.managed_workers) }
	state.ensure_slot(LifecyclePort{}, 0)
	first := state.worker_backend.managed_workers[0].proc or {
		process_runtime.shutdown_managed_processes()
		panic('first worker missing')
	}
	assert first.pid in process_runtime.managed_process_pids()
	state.restart_slot(LifecyclePort{}, 0, 'test restart')
	second := state.worker_backend.managed_workers[0].proc or {
		process_runtime.shutdown_managed_processes()
		panic('replacement missing')
	}
	assert first.pid != second.pid
	assert first.pid !in process_runtime.managed_process_pids()
	assert process_runtime.managed_process_pids() == [second.pid]
	transport.ManagedWorkerPool.stop(mut state.worker_backend.managed_workers)
	assert process_runtime.managed_process_pids().len == 0
}
