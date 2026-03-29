module main

import os

fn shutdown_app_runtime(mut app App, runtime_cfg ServerRuntimeConfig) {
	app.emit('server.stopped', {
		'pid': '${os.getpid()}'
	})
	runtime_cfg.executor_plan.lifecycle.stop(mut app)
	app.logic_executor.close()
	// Graceful provider shutdown is now spec/runtime-driven.
	app.stop_all_providers()
	os.rm(runtime_cfg.internal_admin_socket) or {}
	os.rm(runtime_cfg.pid_file) or {}
}
