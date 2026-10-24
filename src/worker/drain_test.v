module worker

import upstream.transport

fn test_drain_snapshot_and_resume_preserve_request_counters() {
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			managed_workers: [
				transport.ManagedWorker{ socket_path: 'busy.sock', inflight_requests: 2, served_requests: 7 },
				transport.ManagedWorker{ socket_path: 'idle.sock', served_requests: 3 },
			]
		}
	}
	status := state.drain('named-pool')
	assert status.engine == 'named-pool'
	assert status.changed
	assert status.draining_count == 2
	assert status.inflight_requests == 2
	assert status.ready_count == 1
	assert !state.drain_status('named-pool').changed
	assert !state.drain('named-pool').changed
	resumed := state.resume('named-pool')
	assert resumed.changed
	assert resumed.draining_count == 0
	assert resumed.inflight_requests == 2
	assert state.worker_backend.managed_workers[0].served_requests == 7
	assert state.worker_backend.managed_workers[1].served_requests == 3
	assert !state.resume('named-pool').changed
}
