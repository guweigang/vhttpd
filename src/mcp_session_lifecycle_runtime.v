module main

import time
import upstream.transport
import veb

@['/mcp'; delete]
pub fn (mut app App) mcp_delete(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	start_ms := time.now().unix_milli()
	headers := transport.WorkerHttpRequestCodec.header_map_from_request(ctx.req)
	if !app.protocols.mcp.origin_allowed(headers) {
		return mcp_json_response(mut app, mut ctx, 'DELETE', path, req_id, trace_id, start_ms, 403,
			'{"error":"Forbidden Origin"}', 'origin_forbidden', map[string]string{})
	}
	mut session_id := headers['mcp-session-id'] or { '' }
	if session_id == '' {
		session_id = (ctx.query['session_id'] or { '' }).trim_space()
	}
	if session_id == '' {
		return mcp_json_response(mut app, mut ctx, 'DELETE', path, req_id, trace_id, start_ms, 400,
			'{"error":"Missing Mcp-Session-Id"}', 'missing_session_id', map[string]string{})
	}
	deleted := app.protocols.mcp.delete_session(session_id)
	if deleted {
		return mcp_json_response(mut app, mut ctx, 'DELETE', path, req_id, trace_id, start_ms, 200,
			'{"deleted":true}', '', map[string]string{})
	}
	return mcp_json_response(mut app, mut ctx, 'DELETE', path, req_id, trace_id, start_ms, 404,
		'{"error":"Unknown Mcp-Session-Id"}', 'unknown_session_id', map[string]string{})
}
