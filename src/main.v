module main

import json
import log
import net.http
import os
import time
import veb
import veb.request_id
import veb.sse
import upstream.transport

pub struct Context {
	veb.Context
	request_id.RequestIdContext
}

@[heap]
pub struct App {
	veb.Middleware[Context]
	veb.StaticHandler
	DataPlaneRuntime
pub mut:
	control_plane ControlPlaneRuntime
	lifecycle     ProcessLifecycle
}

fn runtime_trace(label string, fields map[string]string) {
	mut row := map[string]string{}
	row['ts'] = time.now().format_ss_milli()
	row['label'] = label
	row['pid'] = '${os.getpid()}'
	for k, v in fields {
		row[k] = v
	}
	mut f := os.open_append('/tmp/vhttpd_runtime_trace.log') or { return }
	defer {
		f.close()
	}
	f.writeln(json.encode(row)) or {}
}

fn dispatch_core(method string, path string) (int, string, string) {
	m := method.to_upper()
	p := transport.normalize_path(path)

	if p == '/panic' {
		return 500, 'Internal Server Error', 'text/plain; charset=utf-8'
	}

	if p == '/health' {
		if m == 'GET' {
			return 200, 'OK', 'text/plain; charset=utf-8'
		}
		return 405, 'Method Not Allowed', 'text/plain; charset=utf-8'
	}

	if p.starts_with('/users/') {
		if m != 'GET' {
			return 405, 'Method Not Allowed', 'text/plain; charset=utf-8'
		}
		user_id := p.all_after('/users/')
		return 200, '{"user":"${user_id}"}', 'application/json; charset=utf-8'
	}

	return 404, 'Not Found', 'text/plain; charset=utf-8'
}

fn resolve_trace_id(ctx Context, path string) string {
	_, query_str := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_str)
	if query['trace_id'] != '' {
		return query['trace_id']
	}
	headers := transport.header_map_from_request(ctx.req)
	for key in ['x-trace-id', 'x-request-id'] {
		if headers[key] != '' {
			return headers[key]
		}
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	return 'vhttpd-${time.now().unix_micro()}'
}

fn resolve_request_id(ctx Context, path string) string {
	_, query_str := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_str)
	if query['request_id'] != '' {
		return query['request_id']
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	headers := transport.header_map_from_request(ctx.req)
	header_rid := headers['x-request-id']
	if header_rid != '' {
		return header_rid
	}
	return 'req-${time.now().unix_micro()}'
}

fn (mut app App) emit(kind string, fields map[string]string) {
	if kind in ['server.started', 'server.failed', 'server.stopped', 'admin.started', 'admin.failed',
		'internal_admin.started', 'internal_admin.error', 'worker.select.failed'] {
		runtime_trace('emit.${kind}', fields)
	}
	app.control_plane.emit(kind, fields)
}

@[get]
pub fn (mut app App) health(mut ctx Context) veb.Result {
	log.info('[http] route health url=${ctx.req.url} method=GET')
	req_id := resolve_request_id(ctx, '/health')
	status, body, _ := dispatch_core('GET', '/health')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/health'
		'status':     '${status}'
		'request_id': req_id
	})
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(body)
}

@['/dispatch'; get]
pub fn (mut app App) dispatch(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	method := ctx.query['method'] or { 'GET' }
	path := ctx.query['path'] or { '/health' }
	req_id := resolve_request_id(ctx, path)
	if app.has_http_logic_executor() {
		return proxy_worker_response(mut app, mut ctx, method, path, 'Bad Gateway')
	}
	mut status := 200
	mut body := ''
	mut ctype := 'text/plain; charset=utf-8'
	status, body, ctype = dispatch_core(method, path)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.normalize_path(path)
		'status':      '${status}'
		'request_id':  req_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	ctx.res.set_status(http.status_from_int(status))
	ctx.set_content_type(ctype)
	return ctx.text(body)
}

@['/dispatch'; head]
pub fn (mut app App) dispatch_head(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	method := ctx.query['method'] or { 'GET' }
	path := ctx.query['path'] or { '/health' }
	req_id := resolve_request_id(ctx, path)
	if app.has_http_logic_executor() {
		return proxy_worker_response(mut app, mut ctx, method, path, '')
	}
	mut status := 200
	mut body := ''
	mut ctype := 'text/plain; charset=utf-8'
	status, body, ctype = dispatch_core(method, path)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.normalize_path(path)
		'status':      '${status}'
		'request_id':  req_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	ctx.res.set_status(http.status_from_int(status))
	ctx.set_content_type(ctype)
	return ctx.text(body)
}

@['/events/stream'; get]
pub fn (mut app App) events_stream(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/events/stream' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	mut count := (ctx.query['count'] or { '3' }).int()
	if count < 1 {
		count = 1
	}
	if count > 20 {
		count = 20
	}
	mut interval_ms := (ctx.query['interval_ms'] or { '150' }).int()
	if interval_ms < 0 {
		interval_ms = 0
	}
	if interval_ms > 1000 {
		interval_ms = 1000
	}

	ctx.takeover_conn()
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-accel-buffering', 'no') or {}
	mut stream := sse.start_connection(mut ctx.Context)
	stream.send_message(retry: 1000) or { return ctx.server_error_with_status(.not_implemented) }
	for i in 0 .. count {
		payload := json.encode({
			'request_id': req_id
			'trace_id':   trace_id
			'seq':        '${i + 1}'
			'ts':         '${time.now().unix()}'
		})
		stream.send_message(id: '${req_id}-${i + 1}', event: 'ping', data: payload) or {
			return veb.no_result()
		}
		if i + 1 < count && interval_ms > 0 {
			time.sleep(time.millisecond * interval_ms)
		}
	}
	stream.close()

	app.emit('http.request', {
		'method':      'GET'
		'path':        '/events/stream'
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	return veb.no_result()
}

@['/:path...'; get]
pub fn (mut app App) proxy_get(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'GET', path)
}

@['/:path...'; post]
pub fn (mut app App) proxy_post(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'POST', path)
}

@['/:path...'; put]
pub fn (mut app App) proxy_put(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'PUT', path)
}

@['/:path...'; patch]
pub fn (mut app App) proxy_patch(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'PATCH', path)
}

@['/:path...'; delete]
pub fn (mut app App) proxy_delete(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'DELETE', path)
}

@['/:path...'; head]
pub fn (mut app App) proxy_head(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'HEAD', path)
}
