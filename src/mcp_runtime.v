module main

import api.mcp.protocol as mcp_protocol
import dispatch
import time
import upstream.transport
import veb

struct McpRuntime {}

fn mcp_handle_post_http(mut app App, mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := transport.header_map_from_request(ctx.req)
	method := ctx.req.method.str().to_upper()
	if method != 'POST' {
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms, 405,
			'{"error":"Method Not Allowed"}', '', map[string]string{})
	}
	if !app.engines.has_socket_workers() {
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms, 501,
			'{"error":"MCP requires a configured logic executor"}', 'worker_unavailable',
			map[string]string{})
	}
	if !app.protocols.mcp.origin_allowed(headers) {
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms, 403,
			'{"error":"Forbidden Origin"}', 'origin_forbidden', map[string]string{})
	}
	mut protocol_version := headers['mcp-protocol-version'] or { '' }
	if protocol_version == '' {
		protocol_version = mcp_protocol.Session.default_protocol_version()
	}
	body := ctx.req.data
	if body.trim_space() == '' {
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms, 400,
			'{"error":"Empty JSON-RPC body"}', 'empty_body', map[string]string{})
	}
	request := app.kernel_mcp_dispatch_request(method, transport.normalize_path(path), headers,
		protocol_version, body, ctx.ip(), req_id, trace_id, headers['mcp-session-id'] or { '' }, app.protocols.mcp.client_capabilities_for_request(headers['mcp-session-id'] or {
		''
	}, body))
	outcome := app.kernel_dispatch_mcp_handled(request) or {
		err_msg := err.msg()
		failure := kernel_dispatch_transport_failure(err_msg)
		app.emit('mcp.dispatch.failed', {
			'request_id':   req_id
			'trace_id':     trace_id
			'error_class':  failure.error_class
			'error_detail': err_msg
		})
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms,
			failure.status, '{"error":"Bad Gateway"}', failure.error_class, {
			'error_detail': err_msg
		})
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
			session_id = mcp_protocol.Session.generate_id()
		}
	}
	if session_id != '' {
		session := app.protocols.mcp.ensure_session(session_id, if response.protocol_version != '' {
			response.protocol_version
		} else {
			protocol_version
		}, req_id, trace_id, '/mcp')
		session_id = session.id
		if body.contains('"method":"initialize"') || body.contains('"method": "initialize"') {
			client_capabilities_json := mcp_protocol.Session.extract_client_capabilities_json(body)
			if client_capabilities_json != '' {
				app.protocols.mcp.set_client_capabilities(session_id, client_capabilities_json)
			}
		}
	}
	for raw_message in response.messages {
		if session_id != '' {
			queue_result := McpRuntime.queue_message(mut app, session_id, raw_message)
			if queue_result.error {
				return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id,
					start_ms, 409, '{"error":"Sampling capability required"}',
					queue_result.error_class, map[string]string{})
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
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms, 500,
			'{"error":"Internal Server Error"}', response.error_class, map[string]string{})
	}
	if !response.handled {
		return mcp_json_response(mut app, mut ctx, method, path, req_id, trace_id, start_ms, 501,
			'{"error":"Not Implemented"}', '', map[string]string{})
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
	status := if response.status > 0 { response.status } else { 200 }
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, mcp_http_ingress_request(method,
		path, ctx.ip(), req_id, trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status,
		resp_headers, response.body), {
		'response_mode': 'mcp'
	}), none)
}

@['/mcp'; post]
pub fn (mut app App) mcp_post(mut ctx Context) veb.Result {
	return mcp_handle_post_http(mut app, mut ctx)
}
