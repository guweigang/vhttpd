module main

import log
import os
import time
import veb.request_id

fn initialize_app_runtime(mut app App, internal_admin_socket string) {
	app.worker_backend.env['VHTTPD_INTERNAL_ADMIN_SOCKET'] = internal_admin_socket
	go run_internal_admin_server(mut app, internal_admin_socket)
	if app.feishu_enabled {
		go app.feishu_runtime_run_buffer_flusher()
	}
	bootstrap_providers(mut app)
}

fn mount_app_assets(mut app App) {
	if app.assets_enabled && app.assets_root_real != '' {
		app.mount_static_folder_at(app.assets_root_real, app.assets_prefix) or {
			log.error('assets mount failed: ${err}')
		}
	}
}

fn install_app_middleware(mut app App) {
	app.use(request_id.middleware[Context](request_id.Config{
		header:    'X-Request-ID'
		generator: fn () string {
			return 'req-${time.now().unix_micro()}'
		}
	}))
	if app.assets_enabled && app.assets_cache_control.trim_space() != '' {
		assets_prefix_mw := app.assets_prefix
		cache_control := app.assets_cache_control
		app.use(
			handler: fn [assets_prefix_mw, cache_control] (mut ctx Context) bool {
				mut url := ctx.req.url
				if q := url.index('?') {
					url = url[..q]
				}
				if url == assets_prefix_mw || url.starts_with('${assets_prefix_mw}/') {
					ctx.set_custom_header('cache-control', cache_control) or {}
				}
				return true
			}
		)
	}
}

fn emit_server_started_event(mut app App, host string, port int, admin_enabled bool, admin_host string, admin_port int) {
	app.emit('server.started', {
		'host':                     host
		'port':                     '${port}'
		'pid':                      '${os.getpid()}'
		'worker_backend':           app.worker_backend.kind()
		'worker_backend_mode':      '${app.worker_backend_mode}'
		'logic_executor':           app.logic_executor_kind()
		'logic_executor_lifecycle': app.logic_executor_lifecycle
		'logic_executor_model':     '${app.logic_executor_model()}'
		'logic_provider':           app.logic_executor_provider()
		'worker_autostart':         if app.worker_backend.autostart { 'true' } else { 'false' }
		'worker_pool_size':         '${app.worker_backend.sockets.len}'
		'admin_enabled':            if admin_enabled { 'true' } else { 'false' }
		'admin_host':               if admin_enabled { admin_host } else { '' }
		'admin_port':               if admin_enabled { '${admin_port}' } else { '' }
	})
}

fn start_admin_plane(mut app App, admin_enabled bool, admin_host string, admin_port int, admin_token string) {
	if admin_enabled {
		go run_admin_server(mut app, admin_host, admin_port, admin_token)
		app.emit('admin.started', {
			'host': admin_host
			'port': '${admin_port}'
		})
		log.info('[vhttpd] Control Plane (admin): http://${admin_host}:${admin_port}/admin')
	} else {
		log.info('[vhttpd] Control Plane (admin): disabled (served on Data Plane /admin)')
	}
}

fn start_upstream_providers(mut app App) {
	mut upstream_launches := app.provider_runtime_upstream_launches()
	mut feishu_labels := []string{}
	mut started_any_upstream := false
	for launch in upstream_launches {
		if launch.instance == '' {
			if launch.provider == 'feishu' && launch.label != '' {
				feishu_labels = launch.label.split(', ').clone()
			}
			continue
		}
		started_any_upstream = true
		go run_websocket_upstream_provider(mut app, launch.provider, launch.instance)
		if launch.provider == 'codex' {
			log.info('[vhttpd] WebSocket Upstream: codex enabled (${launch.url})')
		}
	}
	if feishu_labels.len > 0 {
		log.info('[vhttpd] WebSocket Upstream: feishu enabled (${feishu_labels.join(', ')})')
	}
	if !started_any_upstream {
		log.info('[vhttpd] WebSocket Upstream: disabled')
	}
}

fn log_server_runtime_endpoints(app &App, host string, port int) {
	if app.assets_enabled && app.assets_root_real != '' {
		log.info('[vhttpd] Assets: ${app.assets_prefix} -> ${app.assets_root_real}')
	} else {
		log.info('[vhttpd] Assets: disabled')
	}
	log.info('[vhttpd] Data Plane: http://${host}:${port}/')
}
