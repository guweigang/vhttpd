module main

import log
import net
import net.openssl
import os
import veb
import server_lifecycle

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
	addrs = preflight_server_bind_addrs(host, port)
	for addr in addrs {
		preflight_bind_addr(addr)!
	}
}

fn preflight_server_bind_addrs(host string, port int) []string {
	if host.trim_space() == '' {
		return ['0.0.0.0:${port}']
	}
	return ['${host.trim_space()}:${port}']
}

fn start_server_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	app.lifecycle.start(mut app, runtime_cfg)
}

fn (mut lifecycle ProcessLifecycle) start(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	log.debug('[vhttpd] start_server_runtime: initializing app runtime site=${runtime_cfg.site_id}')
	AppStartupHooks.initialize_runtime(mut app, runtime_cfg.internal_admin_socket)
	scheme := server_runtime_scheme(runtime_cfg)
	lifecycle.data_plane_scheme = scheme
	apply_runtime_scheme_to_worker_envs(mut app, scheme)
	log.debug('[vhttpd] start_server_runtime: starting executor lifecycle')
	port := app.build_engine_lifecycle_port()
	mut facade := app.as_facade()
	app.engines.start(runtime_cfg.executor_plan.lifecycle, port, mut facade)

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
	app.engines.apply_scheme(scheme)
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
