module main

import api.mcp.protocol as mcp_protocol
import net
import time
import upstream.transport
import veb
import worker

@['/mcp'; get]
pub fn (mut app App) mcp_get(mut ctx Context) veb.Result {
	return mcp_handle_get_http(mut app, mut ctx)
}

fn mcp_handle_get_http(mut app App, mut ctx Context) veb.Result {
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
	delivery := mcp_session_delivery_outcome(session_id, session.protocol_version)
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut response_headers := delivery.headers.clone()
	response_headers['x-request-id'] = req_id
	response_headers['x-vhttpd-trace-id'] = trace_id
	content_type := delivery.headers['content-type'] or { 'text/event-stream' }
	status := if delivery.status > 0 { delivery.status } else { 200 }
	worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, content_type,
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
