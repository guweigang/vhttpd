module main

fn (mut app App) cache_runtime_server_run(socket string) {
	app.transport.cache.run(socket)
}
