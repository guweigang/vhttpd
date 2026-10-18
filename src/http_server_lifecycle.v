module main

import http_runtime
import veb
import ws

fn (mut app App) init_server(server &veb.Server) {
	// The TLS backend publishes a placeholder without lifecycle control. It
	// must not enter a shared App's ordinary HTTP handle group.
	server.wait_till_running(max_retries: 0, retry_period_ms: 1) or {
		if err.msg() == 'veb server lifecycle control is not available with SSL' { return }
	}
	app.lifecycle.http.publish(server)
}

fn (mut app App) before_accept_loop() { app.lifecycle.http.ready() }

fn (mut app AdminApp) init_server(server &veb.Server) {
	app.shared.lifecycle.admin_http.publish(server)
}

fn (mut app AdminApp) before_accept_loop() { app.shared.lifecycle.admin_http.ready() }

fn http_ingress_admitted(mut owner http_runtime.Owner, mut ctx Context) bool {
	if owner.accepting() { return true }
	ctx.res.set_status(.service_unavailable)
	ctx.set_custom_header('connection', 'close') or {}
	ctx.text('Server shutting down')
	return false
}

struct HttpIngressStop {
	data      &http_runtime.Owner @[required]
	admin     &http_runtime.Owner @[required]
	websocket &ws.IngressOwner    @[required]
}

fn (mut app App) request_http_ingress_stop() HttpIngressStop {
	app.websocket.state.ingress.request_stop()
	app.lifecycle.http.request_stop()
	app.lifecycle.admin_http.request_stop()
	return HttpIngressStop{ data: app.lifecycle.http, admin: app.lifecycle.admin_http, websocket: app.websocket.state.ingress }
}

fn (stop HttpIngressStop) wait() ! {
	mut data := stop.data
	mut admin := stop.admin
	mut failures := []string{}
	data.wait_stopped() or { failures << err.msg() }
	admin.wait_stopped() or { failures << err.msg() }
	mut ingress := stop.websocket
	ingress.wait()
	if failures.len > 0 { return error(failures.join('\n')) }
}

// Report each App separately, after joining every independent ingress ticket.
fn stop_http_ingresses(mut apps []&App) []string {
	mut stops := []HttpIngressStop{cap: apps.len}
	for mut app in apps { stops << app.request_http_ingress_stop() }
	mut failures := []string{len: stops.len}
	for index, stop in stops { stop.wait() or { failures[index] = err.msg() } }
	return failures
}

// Shared Apps can start several serving loops concurrently. Configure their
// middleware once, before any of those loops constructs its route tables.
fn install_http_ingress_admission(mut app App) {
	app.mu.@lock()
	defer { app.mu.unlock() }
	if app.lifecycle.http_admission_installed { return }
	mut owner := app.lifecycle.http
	app.use(
		handler: fn [mut owner] (mut ctx Context) bool {
			return http_ingress_admitted(mut owner, mut ctx)
		}
	)
	app.lifecycle.http_admission_installed = true
}
