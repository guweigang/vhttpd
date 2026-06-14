module main

import api.mcp.protocol as mcp_protocol
import net
import net.http
import time
import upstream.transport
import veb
import worker

@['/mcp'; get]
pub fn (mut app App) mcp_get(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	headers := transport.WorkerHttpRequestCodec.header_map_from_request(ctx.req)
	if !app.protocols.mcp.origin_allowed(headers) {
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
	app.protocols.mcp.mu.@lock()
	session := app.protocols.mcp.sessions[session_id] or { mcp_protocol.Session{} }
	app.protocols.mcp.mu.unlock()
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
			mcp_protocol.Session.default_protocol_version()
		}
	}
	worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, 200, 'text/event-stream',
		response_headers, false) or { return veb.no_result() }
	mut conn := ctx.conn
	spawn McpRuntime.handle_session_stream(mut app, mut conn, session_id, req_id, trace_id)
	return veb.no_result()
}

fn McpRuntime.handle_session_stream(mut app App, mut conn net.TcpConn, session_id string, req_id string, trace_id string) {
	app.protocols.mcp.bind_conn(session_id, conn)
	app.protocols.mcp.flush_session(session_id)
	conn.write_string(': connected\n\n') or {
		app.protocols.mcp.unbind_conn(session_id, conn)
		conn.close() or {}
		return
	}
	mut last_keepalive_ms := time.now().unix_milli()
	for {
		time.sleep(200 * time.millisecond)
		if !app.protocols.mcp.flush_session(session_id) {
			break
		}
		now_ms := time.now().unix_milli()
		if now_ms - last_keepalive_ms >= 15_000 {
			conn.write_string(': keepalive\n\n') or { break }
			last_keepalive_ms = now_ms
		}
	}
	app.protocols.mcp.unbind_conn(session_id, conn)
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
