module worker

import connection_runtime
import listener_runtime
import os
import process_runtime
import time
import upstream.transport

fn readiness_foreign_path() string {
	return '/private/tmp/vhttpd-foreign-worker-${os.getpid()}-${time.sys_mono_now()}.sock'
}

fn readiness_preserved_listener(path string) ! {
	mut conn := connection_runtime.dial_unix(path)!
	conn.close()!
	assert os.exists(path)
}

fn test_initial_worker_does_not_claim_an_unrelated_listener() ! {
	path := readiness_foreign_path()
	mut listener := listener_runtime.listen(path)!
	defer { listener.close() or {} }
	before := process_runtime.managed_process_pids()
	mut accepted := false
	if mut candidate := transport.ManagedWorker.start(0, 'exec sleep 30 # {socket}', {
		'PATH': os.getenv('PATH')
	}, path, '', 1) {
		accepted = true
		candidate.stop()
	}
	readiness_preserved_listener(path)!
	assert process_runtime.managed_process_pids() == before
	assert !accepted, 'a live foreign listener is not managed worker readiness'
}

fn test_delayed_slot_start_does_not_publish_an_unrelated_listener() ! {
	path := readiness_foreign_path()
	mut listener := listener_runtime.listen(path)!
	defer { listener.close() or {} }
	slot := transport.ManagedWorker.build_slot(0, 'exec sleep 30 # {socket}', {
		'PATH': os.getenv('PATH')
	}, path, 1)!
	mut state := WorkerState{ worker_backend: WorkerBackendRuntime{ autostart: true, managed_workers: [slot] } }
	defer { transport.ManagedWorkerPool.stop(mut state.worker_backend.managed_workers) }
	state.ensure_slot(LifecyclePort{}, 0)
	readiness_preserved_listener(path)!
	has_process := state.worker_backend.managed_workers[0].proc != none
	assert !has_process
	assert state.worker_backend.managed_workers[0].next_retry_ts > 0
}

fn test_slot_restart_does_not_publish_an_unrelated_listener() ! {
	path := readiness_foreign_path()
	mut listener := listener_runtime.listen(path)!
	defer { listener.close() or {} }
	old := transport.ManagedWorker.launch_process('exec sleep 30', {
		'PATH': os.getenv('PATH')
	}, '')!
	mut state := WorkerState{ worker_backend: WorkerBackendRuntime{ autostart: true, managed_workers: [transport.ManagedWorker{ proc: old, worker_cmd: 'exec sleep 30 # {socket}', worker_env: {
		'PATH': os.getenv('PATH')
	}, socket_path: path }] } }
	defer { transport.ManagedWorkerPool.stop(mut state.worker_backend.managed_workers) }
	state.restart_slot(LifecyclePort{}, 0, 'readiness owner test')
	readiness_preserved_listener(path)!
	has_process := state.worker_backend.managed_workers[0].proc != none
	assert !has_process
	assert state.worker_backend.managed_workers[0].next_retry_ts > 0
	assert old.pid !in process_runtime.managed_process_pids()
}

fn test_initial_worker_accepts_listener_in_its_descendant_process_group() ! {
	root := '/private/tmp/vhttpd-worker-peer-${os.getpid()}-${time.sys_mono_now()}'
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	script := root + '/worker.py'
	path := root + '/worker.sock'
	os.write_file(script, 'import os,socket,sys,time\nif os.fork():\n time.sleep(30)\nelse:\n s=socket.socket(socket.AF_UNIX)\n s.bind(sys.argv[1])\n s.listen()\n time.sleep(30)\n')!
	mut candidate := transport.ManagedWorker.start(0, 'python3 ${script} {socket}', {
		'PATH': os.getenv('PATH')
	}, path, '', 1)!
	defer { candidate.stop() }
	assert candidate.process_alive()
	has_process := candidate.proc != none
	assert has_process
	candidate.stop()
	still_owned := candidate.proc != none
	assert !still_owned
}
