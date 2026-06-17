module main

import os
import log
import server_lifecycle
import executor

fn shutdown_app_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	log.info('[vhttpd] shutdown_app_runtime: emitting server.stopped event')
	app.emit('server.stopped', {
		'pid': '${os.getpid()}'
	})
	log.info('[vhttpd] shutdown_app_runtime: stopping main executor lifecycle')
	mut lifecycle_ctx := build_lifecycle_runtime_context(app)
	runtime_cfg.executor_plan.lifecycle.stop(mut lifecycle_ctx)
	log.info('[vhttpd] shutdown_app_runtime: closing main logic_executor')
	app.executors.worker.logic_executor.close()

	// 关闭所有附加常驻进程池的生命周期并关闭执行器
	log.info('[vhttpd] shutdown_app_runtime: stopping additional worker lifecycles')
	for name, mut ws in app.additional_workers {
		log.info('[vhttpd] shutdown_app_runtime: stopping additional worker: ${name}')
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
		log.info('[vhttpd] shutdown_app_runtime: closing additional logic_executor: ${name}')
		ws.logic_executor.close()
	}

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
