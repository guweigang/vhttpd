module worker

import upstream.transport

fn test_admin_snapshot_preserves_fields_and_is_detached_from_pool() {
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			sockets:         ['pool.sock']
			autostart:       true
			max_requests:    10
			managed_workers: [transport.ManagedWorker{
				id:                7
				socket_path:       'pool.sock'
				draining:          true
				inflight_requests: 2
				served_requests:   5
				restart_count:     3
				next_retry_ts:     100
			}]
		}
	}
	snapshot := state.admin_snapshot()
	state.worker_backend.sockets[0] = 'changed.sock'
	state.worker_backend.managed_workers[0].served_requests++
	assert snapshot.worker_sockets == ['pool.sock']
	assert snapshot.worker_pool_size == 1
	assert snapshot.worker_max_requests == 10
	assert snapshot.workers[0].id == 7
	assert snapshot.workers[0].draining
	assert snapshot.workers[0].inflight_requests == 2
	assert snapshot.workers[0].served_requests == 5
	assert snapshot.workers[0].restart_count == 3
	assert snapshot.workers[0].next_retry_ts == 100
	assert !snapshot.workers[0].alive
	assert snapshot.workers[0].pid == 0
}

fn test_restart_errors_remain_explicit_without_an_engine_registry() {
	mut disabled := WorkerState{}
	if _ := disabled.restart_by_id(LifecyclePort{}, 1) {
		assert false
	} else {
		assert err.msg() == 'worker pool is not enabled'
	}
	assert disabled.restart_all(LifecyclePort{}) == 0
	mut enabled := WorkerState{
		worker_backend: WorkerBackendRuntime{
			autostart:       true
			managed_workers: [transport.ManagedWorker{ id: 1 }]
		}
	}
	if _ := enabled.restart_by_id(LifecyclePort{}, 9) {
		assert false
	} else {
		assert err.msg() == 'worker id not found: 9'
	}
}
