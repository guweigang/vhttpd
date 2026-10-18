module main

import worker

fn (mut runtime EngineRuntime) drain_engine(kind string) !worker.DrainStatus {
	selected := runtime.lookup_engine(kind, .drain_pool) or { return error('unknown_executor_kind:${kind}') }
	mut state := selected.state
	return state.drain(if kind == '' { 'main' } else { kind })
}

fn (mut runtime EngineRuntime) engine_drain_status(kind string) !worker.DrainStatus {
	selected := runtime.lookup_engine(kind, .drain_pool) or { return error('unknown_executor_kind:${kind}') }
	mut state := selected.state
	return state.drain_status(if kind == '' { 'main' } else { kind })
}

fn (mut runtime EngineRuntime) resume_engine(kind string) !worker.DrainStatus {
	selected := runtime.lookup_engine(kind, .drain_pool) or { return error('unknown_executor_kind:${kind}') }
	mut state := selected.state
	return state.resume(if kind == '' { 'main' } else { kind })
}
