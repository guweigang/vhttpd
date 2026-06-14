module main

import json
import log
import os
import time
import veb
import executor
import server_lifecycle

fn build_lifecycle_runtime_context(app &App) executor.LifecycleRuntimeContext {
	event_log_path := app.event_log
	return executor.LifecycleRuntimeContext{
		worker_backend_autostart: app.executors.worker.worker_backend.autostart
		worker_backend_cmd:       app.executors.worker.worker_backend.cmd
		worker_backend_env:       app.executors.worker.worker_backend.env.clone()
		worker_backend_sockets:   app.executors.worker.worker_backend.sockets.clone()
		worker_backend_workdir:   app.executors.worker.worker_backend.workdir
		worker_backend_managed_workers: app.executors.worker.worker_backend.managed_workers.clone()
		emit:                     fn [event_log_path] (kind string, fields map[string]string) {
			mut row := map[string]string{}
			row['type'] = kind
			row['ts'] = '${time.now().unix()}'
			for k, v in fields {
				row[k] = v
			}
			mut f := os.open_append(event_log_path) or { return }
			defer {
				f.close()
			}
			f.writeln(json.encode(row)) or {}
		}
	}
}

fn start_server_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	log.debug('[vhttpd] start_server_runtime: initializing app runtime site=${runtime_cfg.site_id}')
	AppStartupHooks.initialize_runtime(mut app, runtime_cfg.internal_admin_socket)
	log.debug('[vhttpd] start_server_runtime: starting executor lifecycle')
	mut lifecycle_ctx := build_lifecycle_runtime_context(app)
	runtime_cfg.executor_plan.lifecycle.start(mut lifecycle_ctx)
	app.executors.worker.worker_backend.managed_workers = lifecycle_ctx.worker_backend_managed_workers
	log.debug('[vhttpd] start_server_runtime: warming up executor kind=${app.logic_executor_kind()}')
	mut facade := app.as_facade()
	app.executors.worker.logic_executor.warmup(mut facade) or {
		err_msg := executor.InProcVjsxError.normalize_message(err.msg(),
			'logic_executor_warmup_failed')
		log.error('[vhttpd] logic executor warmup failed: ${err_msg}')
	}

	// 启动并预热所有附加常驻进程池与逻辑执行器
	for name, mut ws in app.additional_workers {
		log.debug('[vhttpd] start_server_runtime: starting additional executor lifecycle: ${name}')
		event_log_path := app.event_log
		mut sub_lifecycle_ctx := executor.LifecycleRuntimeContext{
			worker_backend_autostart: ws.worker_backend.autostart
			worker_backend_cmd:       ws.worker_backend.cmd
			worker_backend_env:       ws.worker_backend.env.clone()
			worker_backend_sockets:   ws.worker_backend.sockets.clone()
			worker_backend_workdir:   ws.worker_backend.workdir
			worker_backend_managed_workers: ws.worker_backend.managed_workers.clone()
			emit:                     fn [event_log_path] (kind string, fields map[string]string) {
				mut row := map[string]string{}
				row['type'] = kind
				row['ts'] = '${time.now().unix()}'
				for k, v in fields {
					row[k] = v
				}
				mut f := os.open_append(event_log_path) or { return }
				defer {
					f.close()
				}
				f.writeln(json.encode(row)) or {}
			}
		}
		spec := executor.builtin_executor_spec_find(name) or { continue }
		spec.lifecycle.start(mut sub_lifecycle_ctx)
		ws.worker_backend.managed_workers = sub_lifecycle_ctx.worker_backend_managed_workers
		
		log.debug('[vhttpd] start_server_runtime: warming up additional executor: ${name}')
		ws.logic_executor.warmup(mut facade) or {
			log.error('[vhttpd] additional logic executor warmup failed: ${err.msg()}')
		}
	}

	log.debug('[vhttpd] start_server_runtime: mounting assets')
	AppStartupHooks.mount_assets(mut app)
	log.debug('[vhttpd] start_server_runtime: installing middleware')
	AppStartupHooks.install_middleware(mut app)
	AppStartupHooks.emit_server_started(mut app, runtime_cfg.host, runtime_cfg.port,
		runtime_cfg.admin_enabled, runtime_cfg.admin_host, runtime_cfg.admin_port)
	log.debug('[vhttpd] start_server_runtime: starting admin plane')
	AppStartupHooks.start_admin_plane(mut app, runtime_cfg.admin_enabled, runtime_cfg.admin_host,
		runtime_cfg.admin_port, runtime_cfg.admin_token)
	log.debug('[vhttpd] start_server_runtime: starting upstream providers')
	AppStartupHooks.start_upstream_providers(mut app)
	AppStartupHooks.log_runtime_endpoints(app, runtime_cfg.host, runtime_cfg.port)
}

fn serve_server_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	veb.run_at[App, Context](mut app,
		host:                 runtime_cfg.host
		port:                 runtime_cfg.port
		family:               .ip
		show_startup_message: false
	) or {
		err_msg := err.msg()
		app.emit('server.failed', {
			'pid':   '${os.getpid()}'
			'error': err_msg
		})
		log.error('server failed: ${err_msg}')
	}
}
