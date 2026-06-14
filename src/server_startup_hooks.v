module main

import log
import os

struct AppStartupHooks {}

fn AppStartupHooks.initialize_runtime(mut app App, internal_admin_socket string) {
	app.executors.worker.worker_backend.env['VHTTPD_INTERNAL_ADMIN_SOCKET'] = internal_admin_socket
	if app.transport.db.enabled && app.transport.db.socket.trim_space() != '' {
		app.executors.worker.worker_backend.env['VHTTPD_DB_SOCKET'] = app.transport.db.socket
	}
	app.feishu_card_bridge_apply_env_fallbacks()
	go InternalAdminRuntime.serve(mut app, internal_admin_socket)
	if app.providers.feishu.enabled {
		go app.feishu_runtime_run_buffer_flusher()
	}
	if app.feishu_card_bridge_enabled() {
		go FeishuCardBridgeRuntime.run_client(mut app)
	}
	app.bootstrap_providers()
}

fn AppStartupHooks.mount_assets(mut app App) {
	if app.assets.enabled && app.assets.root_real != '' {
		app.mount_static_folder_at(app.assets.root_real, app.assets.prefix) or {
			log.error('assets mount failed: ${err}')
		}
	}
}

fn AppStartupHooks.install_middleware(mut app App) {
	if app.assets.enabled && app.assets.cache_control.trim_space() != '' {
		assets_prefix_mw := app.assets.prefix
		cache_control := app.assets.cache_control
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

fn AppStartupHooks.emit_server_started(mut app App, host string, port int, admin_enabled bool, admin_host string, admin_port int) {
	app.emit('server.started', {
		'host':                     host
		'port':                     '${port}'
		'pid':                      '${os.getpid()}'
		'worker_backend':           app.executors.worker.worker_backend.kind()
		'worker_backend_mode':      '${app.executors.worker.worker_backend_mode}'
		'logic_executor':           app.logic_executor_kind()
		'logic_executor_lifecycle': app.executors.worker.lifecycle
		'logic_executor_model':     '${app.logic_executor_model()}'
		'logic_provider':           app.logic_executor_provider()
		'worker_autostart':         if app.executors.worker.worker_backend.autostart {
			'true'
		} else {
			'false'
		}
		'worker_pool_size':         '${app.executors.worker.worker_backend.sockets.len}'
		'admin_enabled':            if admin_enabled { 'true' } else { 'false' }
		'admin_host':               if admin_enabled { admin_host } else { '' }
		'admin_port':               if admin_enabled { '${admin_port}' } else { '' }
	})
}

fn AppStartupHooks.start_admin_plane(mut app App, admin_enabled bool, admin_host string, admin_port int, admin_token string) {
	if admin_enabled {
		go AdminPlaneRuntime.serve(mut app, admin_host, admin_port, admin_token)
		app.emit('admin.started', {
			'host': admin_host
			'port': '${admin_port}'
		})
		log.info('[vhttpd] Control Plane (admin): http://${admin_host}:${admin_port}/admin')
	} else {
		log.info('[vhttpd] Control Plane (admin): disabled (served on Data Plane /admin)')
	}
}

fn AppStartupHooks.start_upstream_providers(mut app App) {
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
		if launch.provider == 'codex' && app.logic_executor_kind() == 'vjsx' {
			log.info('[vhttpd] WebSocket Upstream: codex deferred to vjsx app_startup (${launch.label})')
			continue
		}
		started_any_upstream = true
		_ = app.ensure_websocket_upstream_provider_running(launch.provider, launch.instance)
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

fn AppStartupHooks.log_runtime_endpoints(app &App, host string, port int) {
	if app.assets.enabled && app.assets.root_real != '' {
		log.info('[vhttpd] Assets: ${app.assets.prefix} -> ${app.assets.root_real}')
	} else {
		log.info('[vhttpd] Assets: disabled')
	}
	if app.transport.db.enabled {
		log.info('[vhttpd] DB Upstream: unix://${app.transport.db.socket} (${app.transport.db.driver}, db=${app.transport.db.database}, pool=${app.transport.db.pool_size})')
	} else {
		log.info('[vhttpd] DB Upstream: disabled')
	}
	log.info('[vhttpd] Data Plane: http://${host}:${port}/')
}
