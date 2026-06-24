module main

import dispatch
import json
import log
import time
import upstream.transport
import veb
import veb.sse

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

fn host_builtin_response(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64, status int, body string, content_type string) veb.Result {
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }, req_id,
		trace_id, start_ms), dispatch.response_outcome(status, {
		'content-type': content_type
	}, body), none)
}

@[get]
pub fn (mut app App) health(mut ctx Context) veb.Result {
	log.info('[http] route health url=${ctx.req.url} method=GET')
	start_ms := time.now().unix_milli()
	req_id := resolve_request_id(ctx, '/health')
	trace_id := resolve_trace_id(ctx, '/health')
	status, body, ctype := dispatch_core('GET', '/health')
	return host_builtin_response(mut app, mut ctx, 'GET', '/health', req_id, trace_id, start_ms,
		status, body, ctype)
}

@['/dispatch'; get]
pub fn (mut app App) dispatch(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	method := ctx.query['method'] or { 'GET' }
	path := ctx.query['path'] or { '/health' }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if app.has_http_logic_executor() {
		return proxy_worker_response(mut app, mut ctx, method, path, 'Bad Gateway')
	}
	status, body, ctype := dispatch_core(method, path)
	return host_builtin_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms,
		status, body, ctype)
}

@['/dispatch'; head]
pub fn (mut app App) dispatch_head(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	method := ctx.query['method'] or { 'GET' }
	path := ctx.query['path'] or { '/health' }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if app.has_http_logic_executor() {
		return proxy_worker_response(mut app, mut ctx, method, path, '')
	}
	status, body, ctype := dispatch_core(method, path)
	return host_builtin_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms,
		status, body, ctype)
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
