module main

fn (mut app App) cache_runtime_server_start(socket string) {
	app.transport.cache.start(socket)
}

fn (mut app App) cache_runtime_snapshot() string {
	return app.transport.cache.snapshot_json(app.transport.cache.enabled)
}
