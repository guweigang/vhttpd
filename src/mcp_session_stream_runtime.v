module main

import api.mcp.protocol as mcp_protocol
import net
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
	start_ms := time.now().unix_milli()
	if !app.protocols.mcp.origin_allowed(headers) {
		return mcp_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id, start_ms, 403,
			'{"error":"Forbidden Origin"}', 'origin_forbidden', map[string]string{})
	}
	mut session_id := headers['mcp-session-id'] or { '' }
	if session_id == '' {
		session_id = (ctx.query['session_id'] or { '' }).trim_space()
	}
	if session_id == '' {
		return mcp_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id, start_ms, 400,
			'{"error":"Missing Mcp-Session-Id"}', 'missing_session_id', map[string]string{})
	}
	app.protocols.mcp.mu.@lock()
	session := app.protocols.mcp.sessions[session_id] or { mcp_protocol.Session{} }
	app.protocols.mcp.mu.unlock()
	if session.id == '' {
		return mcp_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id, start_ms, 404,
			'{"error":"Unknown Mcp-Session-Id"}', 'unknown_session_id', map[string]string{})
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
