module main

import executor
import worker

fn dispatch_non_worker_memory_batch(selection EngineDispatchSelection, count int) {
	mut facade := executor.AppFacade(executor.NoOpAppFacade{})
	for _ in 0 .. count {
		selection.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{}) or { continue }
		assert false, 'disabled executor should reject the request'
	}
}

fn test_non_worker_http_dispatch_does_not_retain_unused_worker_callbacks() {
	disabled := executor.DisabledLogicExecutor{}
	selection := EngineDispatchSelection{
		state:     &worker.WorkerState{ logic_executor: disabled }
		http_port: executor.logic_executor_http_port(disabled)
	}
	dispatch_non_worker_memory_batch(selection, 100)
	gc_collect()
	before := gc_memory_use()
	dispatch_non_worker_memory_batch(selection, 10000)
	gc_collect()
	after := gc_memory_use()
	if gc_is_enabled() {
		assert after <= before + 512 * 1024, 'HTTP requests retained unused worker callbacks: ${before} -> ${after}'
	}
}
