module main

import net.http
import upstream.transport
import veb

@['/mcp'; delete]
pub fn (mut app App) mcp_delete(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	headers := transport.WorkerHttpRequestCodec.header_map_from_request(ctx.req)
	if !app.protocols.mcp.origin_allowed(headers) {
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
	deleted := app.protocols.mcp.delete_session(session_id)
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
