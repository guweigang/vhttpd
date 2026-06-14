module main

import os
import server_lifecycle

fn shutdown_app_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	app.emit('server.stopped', {
		'pid': '${os.getpid()}'
	})
	mut lifecycle_ctx := build_lifecycle_runtime_context(app)
	runtime_cfg.executor_plan.lifecycle.stop(mut lifecycle_ctx)
	app.executors.worker.logic_executor.close()
	app.close_all_plugins()
	// Graceful provider shutdown is now spec/runtime-driven.
	app.stop_all_providers()
	os.rm(runtime_cfg.internal_admin_socket) or {}
	os.rm(runtime_cfg.pid_file) or {}
}
