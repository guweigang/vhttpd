module main

import log

struct TransportStartupRuntime {}

fn TransportStartupRuntime.initialize(mut app App, internal_admin_socket string) {
	app.engines.set_primary_env('VHTTPD_INTERNAL_ADMIN_SOCKET', internal_admin_socket)
	if app.transport.db.enabled && app.transport.db.socket.trim_space() != '' {
		app.engines.set_primary_env('VHTTPD_DB_SOCKET', app.transport.db.socket)
	}
	if app.transport.cache.enabled && app.transport.cache.socket.trim_space() != '' {
		app.engines.set_primary_env('VHTTPD_CACHE_SOCKET', app.transport.cache.socket)
		go app.cache_runtime_server_run(app.transport.cache.socket)
	}
}

fn TransportStartupRuntime.log_endpoints(app &App) {
	if app.transport.db.enabled {
		log.info('[vhttpd] DB Upstream: unix://${app.transport.db.socket} (${app.transport.db.driver}, db=${app.transport.db.database}, pool=${app.transport.db.pool_size})')
	} else {
		log.info('[vhttpd] DB Upstream: disabled')
	}
	if app.transport.cache.enabled {
		log.info('[vhttpd] Cache Upstream: unix://${app.transport.cache.socket} (memory)')
	} else {
		log.info('[vhttpd] Cache Upstream: disabled')
	}
}
