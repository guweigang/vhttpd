module worker

import executor
import upstream.transport

fn test_pool_lifecycle_applies_workers_without_mutating_config() {
	mut state := WorkerState{
		worker_backend: WorkerBackendRuntime{
			env: {
				'original': 'value'
			}
		}
	}
	lifecycle := executor.LogicExecutorLifecycle{
		name_fn:              fn () string { return 'test' }
		prepare_bootstrap_fn: executor.disabled_executor_lifecycle().prepare_bootstrap_fn
		start_fn:             fn (mut ctx executor.LifecycleRuntimeContext) {
			ctx.worker_backend_env['original'] = 'changed'
			ctx.worker_backend_managed_workers << transport.ManagedWorker{ id: 8 }
		}
		stop_fn:              fn (mut ctx executor.LifecycleRuntimeContext) {
			ctx.worker_backend_managed_workers = []transport.ManagedWorker{}
		}
	}
	state.start_backend(lifecycle, LifecyclePort{})
	assert state.worker_backend.managed_workers.len == 1
	assert state.worker_backend.managed_workers[0].id == 8
	assert state.worker_backend.env['original'] == 'value'
	state.stop_backend(lifecycle, LifecyclePort{})
	assert state.worker_backend.managed_workers.len == 0
}

fn test_pool_metrics_and_scheme_are_state_owned() {
	mut state := WorkerState{
		worker_backend:            WorkerBackendRuntime{ sockets: ['one.sock'], queue_waiting_requests: 2, queue_capacity: 3 }
		stat_queue_waits_total:    4
		stat_queue_rejected_total: 5
		stat_queue_timeouts_total: 6
	}
	snapshot := state.metrics()
	assert snapshot.pool_size == 1
	assert snapshot.queue_depth == 2
	assert snapshot.queue_capacity == 3
	assert snapshot.queue_waits_total == 4
	assert snapshot.queue_rejected_total == 5
	assert snapshot.queue_timeouts_total == 6
	state.apply_scheme('https')
	assert state.worker_backend.env['VHTTPD_SCHEME'] == 'https'
	assert state.worker_backend.env['VHTTPD_REQUEST_SCHEME'] == 'https'
	state.apply_scheme('invalid')
	assert state.worker_backend.env['VHTTPD_SCHEME'] == 'http'
}
