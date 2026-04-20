module main

import log
import os
import veb

fn start_server_runtime(mut app App, runtime_cfg ServerRuntimeConfig) {
	log.debug('[vhttpd] start_server_runtime: initializing app runtime site=${runtime_cfg.site_id}')
	initialize_app_runtime(mut app, runtime_cfg.internal_admin_socket)
	log.debug('[vhttpd] start_server_runtime: starting executor lifecycle')
	runtime_cfg.executor_plan.lifecycle.start(mut app)
	log.debug('[vhttpd] start_server_runtime: warming up executor kind=${app.logic_executor_kind()}')
	app.logic_executor.warmup(mut app) or {
		err_msg := inproc_vjsx_normalize_error_message(err.msg(),
			'logic_executor_warmup_failed')
		log.error('[vhttpd] logic executor warmup failed: ${err_msg}')
	}
	log.debug('[vhttpd] start_server_runtime: mounting assets')
	mount_app_assets(mut app)
	log.debug('[vhttpd] start_server_runtime: installing middleware')
	install_app_middleware(mut app)
	emit_server_started_event(mut app, runtime_cfg.host, runtime_cfg.port, runtime_cfg.admin_enabled,
		runtime_cfg.admin_host, runtime_cfg.admin_port)
	log.debug('[vhttpd] start_server_runtime: starting admin plane')
	start_admin_plane(mut app, runtime_cfg.admin_enabled, runtime_cfg.admin_host, runtime_cfg.admin_port,
		runtime_cfg.admin_token)
	log.debug('[vhttpd] start_server_runtime: starting upstream providers')
	start_upstream_providers(mut app)
	log_server_runtime_endpoints(app, runtime_cfg.host, runtime_cfg.port)
}

fn serve_server_runtime(mut app App, runtime_cfg ServerRuntimeConfig) {
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
