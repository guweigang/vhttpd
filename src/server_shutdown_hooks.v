module main

import os
import server_lifecycle
import executor

fn shutdown_app_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	app.emit('server.stopped', {
		'pid': '${os.getpid()}'
	})
	mut lifecycle_ctx := build_lifecycle_runtime_context(app)
	runtime_cfg.executor_plan.lifecycle.stop(mut lifecycle_ctx)
	app.executors.worker.logic_executor.close()

	// 关闭所有附加常驻进程池的生命周期并关闭执行器
	for name, mut ws in app.additional_workers {
		mut sub_lifecycle_ctx := executor.LifecycleRuntimeContext{
			worker_backend_autostart: ws.worker_backend.autostart
			worker_backend_cmd:       ws.worker_backend.cmd
			worker_backend_env:       ws.worker_backend.env.clone()
			worker_backend_sockets:   ws.worker_backend.sockets.clone()
			worker_backend_workdir:   ws.worker_backend.workdir
			worker_backend_managed_workers: ws.worker_backend.managed_workers.clone()
		}
		spec := executor.builtin_executor_spec_find(name) or { continue }
		spec.lifecycle.stop(mut sub_lifecycle_ctx)
		ws.logic_executor.close()
	}

	app.close_all_plugins()
	// Graceful provider shutdown is now spec/runtime-driven.
	app.stop_all_providers()
	os.rm(runtime_cfg.internal_admin_socket) or {}
	os.rm(runtime_cfg.pid_file) or {}
}
