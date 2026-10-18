module main

import worker
import executor

fn test_engine_runtime_copies_share_primary_backend_admission_and_cleanup() {
	calls := chan string{cap: 8}
	lifecycle := executor.LogicExecutorLifecycle{
		...executor.disabled_executor_lifecycle()
		start_fn: fn [calls] (mut ctx executor.LifecycleRuntimeContext) { calls <- 'start' }
		stop_fn:  fn [calls] (mut ctx executor.LifecycleRuntimeContext) { calls <- 'stop' }
	}
	mut runtime := EngineRuntime{}
	mut copy := runtime
	assert voidptr(runtime.primary) == voidptr(copy.primary)
	runtime.primary.start_backend(lifecycle, worker.LifecyclePort{})
	copy.primary.start_backend(lifecycle, worker.LifecyclePort{})
	copy.primary.stop_backend(lifecycle, worker.LifecyclePort{})
	runtime.primary.stop_backend(lifecycle, worker.LifecyclePort{})
	runtime.primary.start_backend(lifecycle, worker.LifecyclePort{})
	assert <-calls == 'start'
	assert <-calls == 'stop'
	assert calls.len == 0
}

fn test_engine_lookup_retains_primary_generation_after_runtime_exchange() {
	mut runtime := EngineRuntime{
		primary: &worker.WorkerState{ worker_backend: worker.WorkerBackendRuntime{ sockets: ['old.sock'] } }
	}
	selected := runtime.lookup_engine('main', .dispatch_pool) or { panic('missing primary') }
	mut retained := selected.state
	mut old := runtime
	runtime = EngineRuntime{
		primary: &worker.WorkerState{ worker_backend: worker.WorkerBackendRuntime{ sockets: ['new.sock'] } }
	}
	assert voidptr(retained) == voidptr(old.primary)
	assert voidptr(retained) != voidptr(runtime.primary)
	assert (retained.next_socket() or { '' }) == 'old.sock'
	retained.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
	assert old.primary.next_socket() == none
	assert (runtime.primary.next_socket() or { '' }) == 'new.sock'
}
