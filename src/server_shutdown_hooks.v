module main

import os
import log
import server_lifecycle

fn shutdown_app_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	app.lifecycle.stop(mut app, runtime_cfg)
}

fn (mut lifecycle ProcessLifecycle) stop(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	_ = lifecycle
	log.info('[vhttpd] shutdown_app_runtime: emitting server.stopped event')
	app.emit('server.stopped', {
		'pid': '${os.getpid()}'
	})
	log.info('[vhttpd] shutdown_app_runtime: stopping engine runtimes')
	port := app.build_engine_lifecycle_port()
	app.engines.stop(runtime_cfg.executor_plan.lifecycle, port)

	log.info('[vhttpd] shutdown_app_runtime: closing all plugins')
	app.close_all_plugins()
	log.info('[vhttpd] shutdown_app_runtime: stopping all providers')
	app.stop_all_providers()
	if app.transport.cache.enabled {
		log.info('[vhttpd] shutdown_app_runtime: stopping cache upstream')
		app.mu.@lock()
		mut cache_listener := app.transport.cache.request_stop()
		app.mu.unlock()
		if !isnil(cache_listener) {
			cache_listener.close() or {}
		}
	}
	log.info('[vhttpd] shutdown_app_runtime: cleaning runtime files')
	os.rm(runtime_cfg.internal_admin_socket) or {}
	os.rm(runtime_cfg.pid_file) or {}
	log.info('[vhttpd] shutdown_app_runtime: complete')
}
