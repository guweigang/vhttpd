module main

import executor
import worker
import upstream.transport

fn registry_test_runtime() EngineRuntime {
	return EngineRuntime{
		primary:    &worker.WorkerState{ worker_backend: worker.WorkerBackendRuntime{ read_timeout_ms: 10 } }
		additional: {
			'php':  &worker.WorkerState{ worker_backend: worker.WorkerBackendRuntime{ read_timeout_ms: 20 } }
			'main': &worker.WorkerState{ worker_backend: worker.WorkerBackendRuntime{ read_timeout_ms: 30 } }
		}
	}
}

fn test_registry_preserves_primary_and_named_precedence_by_policy() {
	runtime := registry_test_runtime()
	primary := runtime.lookup_engine('php', .worker_config) or { panic('missing primary') }
	assert primary.is_primary
	assert primary.state.worker_backend.read_timeout_ms == 10
	named := runtime.lookup_engine('php', .dispatch_pool) or { panic('missing named pool') }
	assert !named.is_primary
	assert named.state.worker_backend.read_timeout_ms == 20
	named_main := runtime.lookup_engine('main', .worker_config) or { panic('missing named main') }
	assert !named_main.is_primary
	assert runtime.read_timeout_ms('main') == 30
	for alias in ['', 'main', 'primary', 'php'] {
		selected := runtime.lookup_engine(alias, .drain_pool) or { panic('missing drain alias') }
		assert selected.is_primary
	}
}

fn test_registry_preserves_unknown_fallback_and_strict_errors() {
	mut runtime := registry_test_runtime()
	assert runtime.read_timeout_ms('missing') == 0
	assert runtime.worker_env('missing').len == 0
	assert runtime.dispatch_selection('missing').pool == 'main'
	assert runtime.lookup_engine('', .executor_kind) == none
	mut facade := executor.NoOpAppFacade{}
	if _ := runtime.dispatch_http_for_kind('missing', mut facade, executor.HttpLogicDispatchRequest{}) {
		assert false
	} else {
		assert err.msg() == 'missing_executor_unavailable'
	}
	if _ := runtime.drain_engine('missing') {
		assert false
	} else {
		assert err.msg() == 'unknown_executor_kind:missing'
	}
}

fn test_registry_resolves_live_primary_state_for_drain() {
	mut runtime := registry_test_runtime()
	runtime.primary.worker_backend.managed_workers = [transport.ManagedWorker{ id: 1 }]
	status := runtime.drain_engine('main') or { panic(err) }
	assert status.changed
	assert runtime.primary.worker_backend.managed_workers[0].draining
	assert (runtime.resume_engine('primary') or { panic(err) }).changed
	assert !runtime.primary.worker_backend.managed_workers[0].draining
}
