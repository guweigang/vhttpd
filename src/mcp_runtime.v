module main

import mcp_protocol
import net
import net.http
import time
import veb

// mcp type aliases
type McpSession = mcp_protocol.Session
type AdminMcpSessionSnapshot = mcp_protocol.SessionSnapshot
type AdminMcpRuntimeSnapshot = mcp_protocol.RuntimeSnapshot
type McpQueueResult = mcp_protocol.QueueResult

struct McpRuntime {}

fn McpRuntime.queue_message(mut app App, session_id string, raw string) McpQueueResult {
	if session_id == '' || raw == '' {
		return McpQueueResult{
			queued: false
		}
	}
	mut warn_sampling_capability := false
	mut drop_sampling_capability := false
	mut error_sampling_capability := false
	mut session_trace_id := ''
	mut session_request_id := ''
	policy :=
		mcp_protocol.McpState.normalize_sampling_capability_policy(app.mcp.sampling_capability_policy)
	app.mcp.mu.@lock()
	if mut session := app.mcp.sessions[session_id] {
		session.last_activity_unix = time.now().unix()
		session_trace_id = session.trace_id
		session_request_id = session.request_id
		if raw.contains('"method":"sampling/createMessage"')
			|| raw.contains('"method": "sampling/createMessage"')
			|| raw.contains('"method":"sampling\\/createMessage"')
			|| raw.contains('"method": "sampling\\/createMessage"') {
			if !session.client_capabilities_json.contains('"sampling"') {
				match policy {
					'drop' { drop_sampling_capability = true }
					'error' { error_sampling_capability = true }
					else { warn_sampling_capability = true }
				}
			}
		}
		if !drop_sampling_capability && !error_sampling_capability {
			session.pending << raw
			max_pending := if app.mcp.max_pending_messages > 0 {
				app.mcp.max_pending_messages
			} else {
				128
			}
			if session.pending.len > max_pending {
				drop_count := session.pending.len - max_pending
				session.pending = session.pending[drop_count..].clone()
				app.mu.@lock()
				app.mcp.stat_pending_dropped_total += drop_count
				app.mu.unlock()
			}
		}
		app.mcp.sessions[session_id] = session
	}
	app.mcp.mu.unlock()
	if warn_sampling_capability {
		app.mu.@lock()
		app.mcp.stat_sampling_capability_warnings_total
		app.mu.unlock()
		app.emit('mcp.capability.warning', {
			'session_id':    session_id
			'request_id':    session_request_id
			'trace_id':      session_trace_id
			'warning_class': 'sampling_without_client_capability'
		})
	}
	if drop_sampling_capability {
		app.mu.@lock()
		app.mcp.stat_sampling_capability_dropped_total
		app.mu.unlock()
		app.emit('mcp.capability.drop', {
			'session_id': session_id
			'request_id': session_request_id
			'trace_id':   session_trace_id
			'policy':     policy
			'drop_class': 'sampling_without_client_capability'
		})
		return McpQueueResult{
			queued: false
		}
	}
	if error_sampling_capability {
		app.mu.@lock()
		app.mcp.stat_sampling_capability_errors_total
		app.mu.unlock()
		app.emit('mcp.capability.error', {
			'session_id':  session_id
			'request_id':  session_request_id
			'trace_id':    session_trace_id
			'policy':      policy
			'error_class': 'sampling_without_client_capability'
		})
		return McpQueueResult{
			queued:      false
			error:       true
			error_class: 'sampling_capability_required'
		}
	}
	return McpQueueResult{
		queued: true
	}
}

fn McpRuntime.flush_session(mut app App, session_id string) bool {
	return app.mcp.flush_session(session_id)
}

fn (mut app App) admin_mcp_snapshot(details bool, limit int, offset int, session_filter string, protocol_filter string) AdminMcpRuntimeSnapshot {
	return app.mcp.snapshot(details, limit, offset, session_filter, protocol_filter)
}

fn McpRuntime.origin_allowed(app &App, headers map[string]string) bool {
	return app.mcp.origin_allowed(headers)
}

fn McpRuntime.delete_session(mut app App, session_id string) bool {
	return app.mcp.delete_session(session_id)
}

fn McpRuntime.client_capabilities_for_request(app &App, session_id string, raw string) string {
	return app.mcp.client_capabilities_for_request(session_id, raw)
}

fn proxy_worker_mcp(mut app App, mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := header_map_from_request(ctx.req)
	method := ctx.req.method.str().to_upper()
	if method != 'POST' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(405))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '405'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
		})
		return ctx.text('{"error":"Method Not Allowed"}')
	}
	if app.worker.worker_backend.sockets.len == 0 {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(501))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '501'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'worker_unavailable'
		})
		return ctx.text('{"error":"MCP requires a configured logic executor"}')
	}
	if !McpRuntime.origin_allowed(app, headers) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '403'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'origin_forbidden'
		})
		return ctx.text('{"error":"Forbidden Origin"}')
	}
	mut protocol_version := headers['mcp-protocol-version'] or { '' }
	if protocol_version == '' {
		protocol_version = McpSession.default_protocol_version()
	}
	body := ctx.req.data
	if body.trim_space() == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(400))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '400'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'empty_body'
		})
		return ctx.text('{"error":"Empty JSON-RPC body"}')
	}
	request := app.kernel_mcp_dispatch_request(method, normalize_path(path), headers,
		protocol_version, body, ctx.ip(), req_id, trace_id, headers['mcp-session-id'] or { '' }, McpRuntime.client_capabilities_for_request(app, headers['mcp-session-id'] or {
		''
	}, body))
	outcome := app.kernel_dispatch_mcp_handled(request) or {
		err_msg := err.msg()
		failure := kernel_dispatch_transport_failure(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', failure.error_class) or {}
		ctx.res.set_status(http.status_from_int(failure.status))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '${failure.status}'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   failure.error_class
			'error_detail':  err_msg
		})
		app.emit('mcp.dispatch.failed', {
			'request_id':   req_id
			'trace_id':     trace_id
			'error_class':  failure.error_class
			'error_detail': err_msg
		})
		return ctx.text('{"error":"Bad Gateway"}')
	}
	mut response := outcome.response
	mut session_id := response.session_id
	if session_id == '' {
		raw_session_id := headers['mcp-session-id'] or { '' }
		if raw_session_id != '' {
			session_id = raw_session_id
		}
	}
	if session_id == '' {
		if body.contains('"method":"initialize"') || body.contains('"method": "initialize"') {
			session_id = McpSession.generate_id()
		}
	}
	if session_id != '' {
		session := app.mcp.ensure_session(session_id, if response.protocol_version != '' {
			response.protocol_version
		} else {
			protocol_version
		}, req_id, trace_id, '/mcp')
		session_id = session.id
		if body.contains('"method":"initialize"') || body.contains('"method": "initialize"') {
			client_capabilities_json := McpSession.extract_client_capabilities_json(body)
			if client_capabilities_json != '' {
				app.mcp.set_client_capabilities(session_id, client_capabilities_json)
			}
		}
	}
	for raw_message in response.messages {
		if session_id != '' {
			queue_result := McpRuntime.queue_message(mut app, session_id, raw_message)
			if queue_result.error {
				ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
				ctx.set_custom_header('x-vhttpd-error-class', queue_result.error_class) or {}
				ctx.res.set_status(http.status_from_int(409))
				ctx.set_content_type('application/json; charset=utf-8')
				app.emit('http.request', {
					'method':        method
					'path':          '/mcp'
					'status':        '409'
					'request_id':    req_id
					'trace_id':      trace_id
					'duration_ms':   '${time.now().unix_milli() - start_ms}'
					'response_mode': 'mcp'
					'error_class':   queue_result.error_class
				})
				return ctx.text('{"error":"Sampling capability required"}')
			}
		}
	}
	command_snapshots := outcome.command_snapshots
	command_error := outcome.command_error
	if response.commands.len > 0 {
		app.emit('mcp.commands', {
			'request_id':    req_id
			'trace_id':      trace_id
			'session_id':    session_id
			'command_count': '${response.commands.len}'
			'result_count':  '${command_snapshots.len}'
			'status':        if command_error == '' { 'ok' } else { 'error' }
		})
	}
	if response.event == 'error' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', response.error_class) or {}
		ctx.res.set_status(http.status_from_int(500))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '500'
			'request_id':    req_id
			'trace_id':      trace_id
			'duration_ms':   '${time.now().unix_milli() - start_ms}'
			'response_mode': 'mcp'
			'error_class':   response.error_class
		})
		return ctx.text('{"error":"Internal Server Error"}')
	}
	if !response.handled {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(501))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        method
			'path':          '/mcp'
			'status':        '501'
			'request_id':    req_id
			'trace_id':      trace_id
			'duration_ms':   '${time.now().unix_milli() - start_ms}'
			'response_mode': 'mcp'
		})
		return ctx.text('{"error":"Not Implemented"}')
	}
	mut resp_headers := response.headers.clone()
	resp_headers['x-vhttpd-trace-id'] = trace_id
	if command_error != '' {
		resp_headers['x-vhttpd-command-error'] = command_error
	}
	if response.protocol_version != '' {
		resp_headers['mcp-protocol-version'] = response.protocol_version
	}
	if session_id != '' {
		resp_headers['mcp-session-id'] = session_id
	}
	apply_worker_headers(mut ctx, resp_headers)
	ctx.res.set_status(http.status_from_int(if response.status > 0 { response.status } else { 200 }))
	ctx.set_content_type(resp_headers['content-type'] or { 'application/json; charset=utf-8' })
	app.emit('http.request', {
		'method':        method
		'path':          '/mcp'
		'status':        '${if response.status > 0 { response.status } else { 200 }}'
		'request_id':    req_id
		'trace_id':      trace_id
		'duration_ms':   '${time.now().unix_milli() - start_ms}'
		'response_mode': 'mcp'
	})
	return ctx.text(response.body)
}

@['/mcp'; post]
pub fn (mut app App) mcp_post(mut ctx Context) veb.Result {
	return proxy_worker_mcp(mut app, mut ctx)
}

@['/mcp'; get]
pub fn (mut app App) mcp_get(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := header_map_from_request(ctx.req)
	if !McpRuntime.origin_allowed(app, headers) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        'GET'
			'path':          '/mcp'
			'status':        '403'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'origin_forbidden'
		})
		return ctx.text('{"error":"Forbidden Origin"}')
	}
	mut session_id := headers['mcp-session-id'] or { '' }
	if session_id == '' {
		session_id = (ctx.query['session_id'] or { '' }).trim_space()
	}
	if session_id == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(400))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        'GET'
			'path':          '/mcp'
			'status':        '400'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'missing_session_id'
		})
		return ctx.text('{"error":"Missing Mcp-Session-Id"}')
	}
	app.mcp.mu.@lock()
	session := app.mcp.sessions[session_id] or { McpSession{} }
	app.mcp.mu.unlock()
	if session.id == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(404))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        'GET'
			'path':          '/mcp'
			'status':        '404'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'unknown_session_id'
		})
		return ctx.text('{"error":"Unknown Mcp-Session-Id"}')
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	response_headers := {
		'x-request-id':         req_id
		'x-vhttpd-trace-id':    trace_id
		'x-accel-buffering':    'no'
		'mcp-session-id':       session_id
		'mcp-protocol-version': if session.protocol_version != '' {
			session.protocol_version
		} else {
			McpSession.default_protocol_version()
		}
	}
	WorkerHttpStreamWriter.write_headers(mut ctx, 200, 'text/event-stream', response_headers, false) or {
		return veb.no_result()
	}
	mut conn := ctx.conn
	spawn handle_mcp_session_stream(mut app, mut conn, session_id, req_id, trace_id)
	return veb.no_result()
}

fn handle_mcp_session_stream(mut app App, mut conn net.TcpConn, session_id string, req_id string, trace_id string) {
	app.mcp.bind_conn(session_id, conn)
	McpRuntime.flush_session(mut app, session_id)
	conn.write_string(': connected\n\n') or {
		app.mcp.unbind_conn(session_id, conn)
		conn.close() or {}
		return
	}
	mut last_keepalive_ms := time.now().unix_milli()
	for {
		time.sleep(200 * time.millisecond)
		if !McpRuntime.flush_session(mut app, session_id) {
			break
		}
		now_ms := time.now().unix_milli()
		if now_ms - last_keepalive_ms >= 15_000 {
			conn.write_string(': keepalive\n\n') or { break }
			last_keepalive_ms = now_ms
		}
	}
	app.mcp.unbind_conn(session_id, conn)
	conn.close() or {}
	app.emit('http.request', {
		'method':        'GET'
		'path':          '/mcp'
		'status':        '200'
		'request_id':    req_id
		'trace_id':      trace_id
		'response_mode': 'mcp'
	})
}

@['/mcp'; delete]
pub fn (mut app App) mcp_delete(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := header_map_from_request(ctx.req)
	if !McpRuntime.origin_allowed(app, headers) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method':        'DELETE'
			'path':          '/mcp'
			'status':        '403'
			'request_id':    req_id
			'trace_id':      trace_id
			'response_mode': 'mcp'
			'error_class':   'origin_forbidden'
		})
		return ctx.text('{"error":"Forbidden Origin"}')
	}
	mut session_id := headers['mcp-session-id'] or { '' }
	if session_id == '' {
		session_id = (ctx.query['session_id'] or { '' }).trim_space()
	}
	if session_id == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(400))
		ctx.set_content_type('application/json; charset=utf-8')
		return ctx.text('{"error":"Missing Mcp-Session-Id"}')
	}
	deleted := McpRuntime.delete_session(mut app, session_id)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.res.set_status(http.status_from_int(if deleted { 200 } else { 404 }))
	app.emit('http.request', {
		'method':        'DELETE'
		'path':          '/mcp'
		'status':        if deleted { '200' } else { '404' }
		'request_id':    req_id
		'trace_id':      trace_id
		'response_mode': 'mcp'
	})
	if deleted {
		return ctx.text('{"deleted":true}')
	}
	return ctx.text('{"error":"Unknown Mcp-Session-Id"}')
}
