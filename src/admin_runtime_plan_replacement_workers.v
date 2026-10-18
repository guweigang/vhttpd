module main

// The admitted admin workflow owns this batch through result recording. Its
// exclusive admission and shutdown scope keep engine routing alive and stable
// until all drain/resume accounting and events complete.
fn (mut app App) replacement_worker_pools(engine_ids []string) ![]string {
	app.mu.@lock()
	defer { app.mu.unlock() }
	if !app.replacement.operation_active {
		return error('runtime_plan_replacement_operation_required')
	}
	mut pools := []string{cap: engine_ids.len}
	for engine_id in engine_ids {
		pool := app.resolve_engine_worker_pool(engine_id)!
		// Resolve the complete batch before changing any worker. No borrowed
		// state reference escapes preflight, and no I/O/callback runs under App.mu.
		app.engines.lookup_engine(pool, .drain_pool) or {
			return error('unknown_executor_kind:${pool}')
		}
		pools << pool
	}
	return pools
}
