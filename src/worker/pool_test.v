module worker

import upstream.transport

fn test_round_robin_and_empty_pool() {
	mut state := WorkerState{}
	assert state.next_socket() == none
	state.worker_backend.sockets = ['one.sock', 'two.sock']
	assert state.next_socket() or { '' } == 'one.sock'
	assert state.next_socket() or { '' } == 'two.sock'
	assert state.next_socket() or { '' } == 'one.sock'
}

fn test_concurrent_leases_reserve_a_worker_once() {
	mut state := &WorkerState{
		worker_backend: WorkerBackendRuntime{
			sockets:         ['worker.sock']
			managed_workers: [transport.ManagedWorker{ socket_path: 'worker.sock' }]
		}
	}
	results := chan string{cap: 16}
	for _ in 0 .. 16 {
		spawn fn [mut state, results] () {
			socket := state.lease_idle_socket() or { '' }
			results <- socket
		}()
	}
	mut leases := 0
	for _ in 0 .. 16 {
		if <-results == 'worker.sock' {
			leases++
		}
	}
	assert leases == 1
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.request_released('worker.sock')
	assert state.worker_backend.managed_workers[0].served_requests == 0
	assert state.lease_idle_socket() or { '' } == 'worker.sock'
}

fn test_leasing_skips_busy_and_draining_workers() {
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			sockets:         ['busy.sock', 'draining.sock', 'idle.sock']
			managed_workers: [
				transport.ManagedWorker{ socket_path: 'busy.sock', inflight_requests: 1 },
				transport.ManagedWorker{ socket_path: 'draining.sock', draining: true },
				transport.ManagedWorker{ socket_path: 'idle.sock' },
			]
		}
	}
	assert state.lease_idle_socket() or { '' } == 'idle.sock'
	assert state.lease_idle_socket() == none
}
