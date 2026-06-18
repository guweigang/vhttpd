module main

import json
import log
import net
import net.openssl
import os
import time
import veb
import executor
import server_lifecycle

fn build_lifecycle_runtime_context(app &App) executor.LifecycleRuntimeContext {
	event_log_path := app.event_log
	return executor.LifecycleRuntimeContext{
		worker_backend_autostart:       app.executors.worker.worker_backend.autostart
		worker_backend_cmd:             app.executors.worker.worker_backend.cmd
		worker_backend_env:             app.executors.worker.worker_backend.env.clone()
		worker_backend_sockets:         app.executors.worker.worker_backend.sockets.clone()
		worker_backend_workdir:         app.executors.worker.worker_backend.workdir
		worker_backend_managed_workers: app.executors.worker.worker_backend.managed_workers.clone()
		emit:                           fn [event_log_path] (kind string, fields map[string]string) {
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

fn preflight_bind_addr(addr string) ! {
	mut listener := net.listen_tcp(.ip, addr) or {
		return error('bind preflight failed for ${addr}: ${err.msg()}')
	}
	listener.close() or {}
}

fn preflight_server_bind(runtime_cfg server_lifecycle.ServerRuntimeConfig) ! {
	host := runtime_cfg.host.trim_space()
	port := runtime_cfg.port
	if port <= 0 {
		return error('bind preflight failed: invalid port ${port}')
	}
	if runtime_cfg.ssl_enabled {
		if runtime_cfg.ssl_cert.trim_space() == '' {
			return error('https preflight failed: missing ssl cert')
		}
		if runtime_cfg.ssl_cert_key.trim_space() == '' {
			return error('https preflight failed: missing ssl cert key')
		}
		if !os.is_file(runtime_cfg.ssl_cert) {
			return error('https preflight failed: ssl cert not found: ${runtime_cfg.ssl_cert}')
		}
		if !os.is_file(runtime_cfg.ssl_cert_key) {
			return error('https preflight failed: ssl cert key not found: ${runtime_cfg.ssl_cert_key}')
		}
	}
	mut addrs := []string{}
	if host == '' {
		addrs << '0.0.0.0:${port}'
	} else {
		addrs << '${host}:${port}'
		if host != '0.0.0.0' && host != '::' {
			addrs << '0.0.0.0:${port}'
		}
	}
	for addr in addrs {
		preflight_bind_addr(addr)!
	}
}

fn start_server_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	log.debug('[vhttpd] start_server_runtime: initializing app runtime site=${runtime_cfg.site_id}')
	AppStartupHooks.initialize_runtime(mut app, runtime_cfg.internal_admin_socket)
	scheme := server_runtime_scheme(runtime_cfg)
	app.data_plane_scheme = scheme
	apply_runtime_scheme_to_worker_envs(mut app, scheme)
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
			worker_backend_autostart:       ws.worker_backend.autostart
			worker_backend_cmd:             ws.worker_backend.cmd
			worker_backend_env:             ws.worker_backend.env.clone()
			worker_backend_sockets:         ws.worker_backend.sockets.clone()
			worker_backend_workdir:         ws.worker_backend.workdir
			worker_backend_managed_workers: ws.worker_backend.managed_workers.clone()
			emit:                           fn [event_log_path] (kind string, fields map[string]string) {
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
	AppStartupHooks.emit_server_started(mut app, scheme, runtime_cfg.host, runtime_cfg.port,
		runtime_cfg.admin_enabled, runtime_cfg.admin_host, runtime_cfg.admin_port)
	log.debug('[vhttpd] start_server_runtime: starting admin plane')
	AppStartupHooks.start_admin_plane(mut app, runtime_cfg.admin_enabled, runtime_cfg.admin_host,
		runtime_cfg.admin_port, runtime_cfg.admin_token)
	log.debug('[vhttpd] start_server_runtime: starting upstream providers')
	AppStartupHooks.start_upstream_providers(mut app)
	AppStartupHooks.log_runtime_endpoints(app, scheme, runtime_cfg.host, runtime_cfg.port)
}

fn apply_runtime_scheme_to_worker_envs(mut app App, scheme string) {
	normalized := if scheme.trim_space() == 'https' { 'https' } else { 'http' }
	app.executors.worker.worker_backend.env['VHTTPD_SCHEME'] = normalized
	app.executors.worker.worker_backend.env['VHTTPD_REQUEST_SCHEME'] = normalized
	for _, mut ws in app.additional_workers {
		ws.worker_backend.env['VHTTPD_SCHEME'] = normalized
		ws.worker_backend.env['VHTTPD_REQUEST_SCHEME'] = normalized
	}
}

fn serve_server_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	if runtime_cfg.ssl_enabled && runtime_cfg.ssl_cert.trim_space() != ''
		&& runtime_cfg.ssl_cert_key.trim_space() != '' {
		veb.run_at[App, Context](mut app,
			host:                 runtime_cfg.host
			port:                 runtime_cfg.port
			family:               .ip
			show_startup_message: false
			ssl_config:           openssl.SSLConnectConfig{
				cert:     runtime_cfg.ssl_cert
				cert_key: runtime_cfg.ssl_cert_key
			}
		) or { report_server_runtime_failure(mut app, err.msg()) }
		return
	}
	veb.run_at[App, Context](mut app,
		host:                 runtime_cfg.host
		port:                 runtime_cfg.port
		family:               .ip
		show_startup_message: false
	) or { report_server_runtime_failure(mut app, err.msg()) }
}

fn report_server_runtime_failure(mut app App, err_msg string) {
	app.emit('server.failed', {
		'pid':   '${os.getpid()}'
		'error': err_msg
	})
	log.error('server failed: ${err_msg}')
}

fn server_runtime_scheme(runtime_cfg server_lifecycle.ServerRuntimeConfig) string {
	if runtime_cfg.ssl_enabled && runtime_cfg.ssl_cert.trim_space() != ''
		&& runtime_cfg.ssl_cert_key.trim_space() != '' {
		return 'https'
	}
	return 'http'
}
