module main

import log
import os

struct ControlPlaneStartupRuntime {}

fn ControlPlaneStartupRuntime.emit_server_started(mut app App, scheme string, host string, port int, admin_enabled bool, admin_host string, admin_port int) {
	mut fields := app.engines.startup_fields()
	fields['scheme'] = scheme
	fields['host'] = host
	fields['port'] = '${port}'
	fields['pid'] = '${os.getpid()}'
	fields['admin_enabled'] = if admin_enabled { 'true' } else { 'false' }
	fields['admin_host'] = if admin_enabled { admin_host } else { '' }
	fields['admin_port'] = if admin_enabled { '${admin_port}' } else { '' }
	app.emit('server.started', fields)
}

fn ControlPlaneStartupRuntime.start_admin_plane(mut app App, admin_enabled bool, admin_host string, admin_port int, admin_token string) {
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
