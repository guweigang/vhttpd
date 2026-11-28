module main

fn websocket_context_memory_batch(mut app App, count int) {
	for _ in 0 .. count {
		rt := app.build_websocket_runtime_context()
		assert rt.rooms('probe').len == 0
		assert rt.command_result([]).failures.len == 0
		assert app.execute_websocket_dispatch_commands_result([]).failures.len == 0
	}
}

fn test_completed_websocket_contexts_do_not_retain_native_callback_sets() {
	mut app := &App{}
	websocket_context_memory_batch(mut app, 16)
	gc_collect()
	before := gc_memory_use()
	websocket_context_memory_batch(mut app, 512)
	gc_collect()
	after := gc_memory_use()
	assert !gc_is_enabled() || after <= before + 1024 * 1024, 'Completed hub contexts retained native callbacks: ${before} -> ${after}'
}
