module worker

import os
import time
import upstream.transport

@[heap]
struct LifecycleEventProbe {
mut:
	calls int
}

fn exercise_worker_lifecycle_event(restart bool, ready bool) {
	root := os.join_path(os.temp_dir(), 'le-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := root + '/worker.sock'
	script := root + '/peer.py'
	os.write_file(script, 'import socket,sys\ns=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen()\nwhile True:\n c,_=s.accept(); c.close()\n') or { panic(err) }
	// Readiness requires the managed child itself to own the socket.
	command := if ready { 'python3 "${script}" "${path}"' } else { 'sleep 30' }
	// An overlong address fails before native connect allocates a descriptor.
	socket := if ready { path } else { '/tmp/' + 'x'.repeat(200) }
	mut state := &WorkerState{
		worker_backend: WorkerBackendRuntime{
			autostart:       true
			sockets:         [socket]
			managed_workers: [transport.ManagedWorker{
				id:          7
				socket_path: socket
				worker_cmd:  command
			}]
		}
	}
	defer {
		mut w := state.worker_backend.managed_workers[0]
		w.stop()
	}
	if restart {
		proc := transport.ManagedWorker.launch_process('exec sleep 30', {}, '') or { panic(err) }
		state.worker_backend.managed_workers[0].proc = proc
	}
	mut probe := &LifecycleEventProbe{}
	port := LifecyclePort{
		emit_fn: fn [mut state, mut probe, restart, ready, socket] (kind string, fields map[string]string) {
			// Fail deterministically on the old lock ownership without deadlocking the test.
			unlocked := state.mu.try_lock()
			if unlocked { state.mu.unlock() }
			assert unlocked
			assert state.metrics().pool_size == 1
			state.mu.@lock()
			defer { state.mu.unlock() }
			assert fields['worker_id'] == '7'
			assert fields['socket'] == socket
			assert fields['restart_count'] == '1'
			assert state.worker_backend.managed_workers[0].restart_count == 1
			if ready {
				assert kind == if restart { 'worker.restarted' } else { 'worker.started' }
				assert state.worker_backend.managed_workers[0].process_alive()
				assert state.worker_backend.managed_workers[0].next_retry_ts == 0
				// Reentrant state mutation must survive returning from the callback.
				state.worker_backend.managed_workers[0].draining = true
			} else {
				assert kind == 'worker.restart_scheduled'
				assert fields['reason'].contains('worker socket not ready')
				assert state.worker_backend.managed_workers[0].proc == none
				assert state.worker_backend.managed_workers[0].next_retry_ts > 0
			}
			probe.calls++
		}
	}
	if restart { state.restart_slot(port, 0, 'test_restart') } else { state.ensure_slot(port, 0) }
	assert probe.calls == 1
	assert state.worker_backend.managed_workers[0].draining == ready
}

fn test_worker_started_event_can_reenter_state() {
	exercise_worker_lifecycle_event(false, true)
}

fn test_worker_restarted_event_can_reenter_state() {
	exercise_worker_lifecycle_event(true, true)
}

fn test_worker_start_failure_event_observes_retired_process() {
	exercise_worker_lifecycle_event(false, false)
}

fn test_worker_restart_failure_event_observes_retired_process() {
	exercise_worker_lifecycle_event(true, false)
}
