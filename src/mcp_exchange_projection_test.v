module main

import api.mcp.protocol as mcp_protocol
import dispatch
import upstream.transport

fn test_mcp_dispatch_request_projects_to_exchange() {
	ctx := McpExchangeContext{
		request_id: 'req-1'
		trace_id:   'trace-1'
		ingress:    'listener:web'
		pipeline:   'mcp.pipeline'
	}
	ex := mcp_dispatch_request_exchange(transport.WorkerMcpDispatchRequest{
		event:            'request'
		http_method:      'POST'
		path:             '/mcp'
		headers:          {
			'accept': 'application/json, text/event-stream'
		}
		protocol_version: '2025-06-18'
		accept:           'application/json, text/event-stream'
		content_type:     'application/json'
		body:             '{"jsonrpc":"2.0","method":"initialize"}'
		remote_addr:      '127.0.0.1:50001'
		request_id:       'req-1'
		trace_id:         'trace-1'
		session_id:       'sess-1'
	}, ctx)
	assert ex.kind == .request
	assert ex.identity.id == 'sess-1:request'
	assert ex.identity.parent_id == 'sess-1'
	assert ex.identity.trace_id == 'trace-1'
	assert ex.headers['accept'] == 'application/json, text/event-stream'
	assert ex.metadata['mcp.source'] == 'worker'
	assert ex.metadata['mcp.protocol_version'] == '2025-06-18'
	assert ex.metadata['mcp.session_id'] == 'sess-1'
	assert ex.metadata['mcp.content_type'] == 'application/json'
	match ex.payload {
		dispatch.RequestPayload {
			assert ex.payload.method == 'POST'
			assert ex.payload.path == '/mcp'
			assert ex.payload.remote_addr == '127.0.0.1:50001'
			assert ex.payload.body.contains('"initialize"')
		}
		else {
			assert false
		}
	}
}

fn test_mcp_dispatch_response_projects_to_exchange() {
	ctx := McpExchangeContext{
		request_id:       'req-2'
		trace_id:         'trace-2'
		ingress:          'listener:web'
		pipeline:         'mcp.pipeline'
		session_id:       'sess-2'
		protocol_version: '2025-06-18'
	}
	ex := mcp_dispatch_response_exchange(transport.WorkerMcpDispatchResponse{
		event:      'response'
		handled:    true
		status:     202
		headers:    {
			'x-mcp': '1'
		}
		body:       '{"ok":true}'
		session_id: 'sess-2'
		messages:   ['{"jsonrpc":"2.0","method":"notifications/progress"}']
		commands:   [
			transport.WorkerWebSocketUpstreamCommand{
				event: 'send'
			},
		]
	}, ctx)
	assert ex.kind == .response
	assert ex.identity.id == 'sess-2:response'
	assert ex.metadata['mcp.source'] == 'worker'
	assert ex.metadata['mcp.handled'] == 'true'
	assert ex.metadata['mcp.message_count'] == '1'
	assert ex.metadata['mcp.command_count'] == '1'
	assert ex.headers['x-mcp'] == '1'
	match ex.payload {
		dispatch.ResponsePayload {
			assert ex.payload.status == 202
			assert ex.payload.body == '{"ok":true}'
		}
		else {
			assert false
		}
	}
}

fn test_mcp_session_stream_open_projects_to_stream_exchange() {
	ctx := McpExchangeContext{
		request_id: 'req-3'
		trace_id:   'trace-3'
		ingress:    'listener:web'
		pipeline:   'mcp.pipeline'
	}
	ex := mcp_session_stream_open_exchange('sess-3', '', ctx)
	assert ex.kind == .stream_open
	assert ex.identity.id == 'sess-3:stream-open'
	assert ex.headers['content-type'] == 'text/event-stream'
	assert ex.headers['mcp-session-id'] == 'sess-3'
	assert ex.headers['mcp-protocol-version'] == mcp_protocol.Session.default_protocol_version()
	assert ex.metadata['mcp.source'] == 'runtime'
	assert ex.metadata['mcp.event'] == 'session_stream_open'
	assert ex.metadata['session_transport'] == 'sse'
	match ex.payload {
		dispatch.StreamPayload {
			assert ex.payload.session_id == 'sess-3'
		}
		else {
			assert false
		}
	}
}

fn test_mcp_runtime_message_and_close_project_to_session_exchanges() {
	ctx := McpExchangeContext{
		request_id: 'req-4'
		trace_id:   'trace-4'
		ingress:    'listener:web'
		pipeline:   'mcp.pipeline'
		session_id: 'sess-4'
	}
	message := mcp_session_message_exchange(ctx, '{"jsonrpc":"2.0"}', {
		'queue': 'pending'
	})
	assert message.kind == .session_message
	assert message.identity.id == 'sess-4:message'
	assert message.metadata['mcp.event'] == 'session_message'
	assert message.metadata['queue'] == 'pending'
	match message.payload {
		dispatch.SessionPayload {
			assert message.payload.session_id == 'sess-4'
			assert message.payload.message == '{"jsonrpc":"2.0"}'
		}
		else {
			assert false
		}
	}

	close := mcp_session_close_exchange(ctx, 'deleted', map[string]string{})
	assert close.kind == .session_close
	assert close.identity.id == 'sess-4:close'
	assert close.metadata['mcp.reason'] == 'deleted'
	match close.payload {
		dispatch.SessionPayload {
			assert close.payload.session_id == 'sess-4'
			assert close.payload.message == 'deleted'
		}
		else {
			assert false
		}
	}
}
