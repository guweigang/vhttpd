module main

import api.mcp.protocol as mcp_protocol
import dispatch
import net.http
import time
import upstream.transport
import veb

struct McpRuntime {}

fn proxy_worker_mcp(mut app App, mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := transport.header_map_from_request(ctx.req)
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
	if !app.engines.has_socket_workers() {
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
	if !app.protocols.mcp.origin_allowed(headers) {
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
		protocol_version = mcp_protocol.Session.default_protocol_version()
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
	request := app.kernel_mcp_dispatch_request(method, transport.normalize_path(path), headers,
		protocol_version, body, ctx.ip(), req_id, trace_id, headers['mcp-session-id'] or { '' }, app.protocols.mcp.client_capabilities_for_request(headers['mcp-session-id'] or {
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
	status := if response.status > 0 { response.status } else { 200 }
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, HttpIngressRequest{
		method:        method
		path:          '/mcp'
		dispatch_path: transport.normalize_path(path)
		remote_addr:   ctx.ip()
		request_id:    req_id
		trace_id:      trace_id
		start_ms:      start_ms
	}, dispatch.outcome_with_metadata(dispatch.response_outcome(status, resp_headers, response.body),
		{
		'response_mode': 'mcp'
	}), none)
}

@['/mcp'; post]
pub fn (mut app App) mcp_post(mut ctx Context) veb.Result {
	return proxy_worker_mcp(mut app, mut ctx)
}
