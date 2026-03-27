module main

pub enum KernelDispatchKind {
	stream
	mcp
	websocket_upstream
	websocket_dispatch
}

pub struct KernelDispatchEnvelope {
pub:
	kind    KernelDispatchKind
	context DispatchContext
}

pub struct KernelDispatchTransportFailure {
pub:
	status      int
	error_class string
}

pub struct KernelWebSocketUpstreamDispatchOutcome {
pub:
	response          WorkerWebSocketUpstreamDispatchResponse
	command_snapshots []WebSocketUpstreamCommandActivity
	command_error     string
}

pub struct KernelMcpDispatchOutcome {
pub:
	response          WorkerMcpDispatchResponse
	command_snapshots []WebSocketUpstreamCommandActivity
	command_error     string
}

pub struct KernelStreamDispatchFailure {
pub:
	error       string
	error_class string
}

pub fn KernelDispatchEnvelope.from_stream_dispatch(req StreamDispatchRequest) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind: .stream
		context: DispatchContext.from_stream_dispatch(req)
	}
}

pub fn KernelDispatchEnvelope.from_mcp_dispatch(req WorkerMcpDispatchRequest) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind: .mcp
		context: DispatchContext.from_mcp_dispatch(req)
	}
}

pub fn KernelDispatchEnvelope.from_websocket_upstream(req WorkerWebSocketUpstreamDispatchRequest) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind: .websocket_upstream
		context: DispatchContext.from_websocket_upstream(req)
	}
}

pub fn KernelDispatchEnvelope.from_websocket_dispatch(frame WorkerWebSocketFrame) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind: .websocket_dispatch
		context: DispatchContext.from_websocket_dispatch(frame)
	}
}

fn (mut app App) kernel_dispatch_stream(req StreamDispatchRequest) !StreamDispatchResponse {
	_ = KernelDispatchEnvelope{
		kind: .stream
		context: DispatchContext.from_stream_dispatch_provider(req, app.logic_executor_provider())
	}
	return app.logic_executor.dispatch_stream(mut app, req)
}

fn kernel_stream_dispatch_failure(resp StreamDispatchResponse) ?KernelStreamDispatchFailure {
	if resp.event != 'error' {
		return none
	}
	return KernelStreamDispatchFailure{
		error: resp.error
		error_class: if resp.error_class != '' { resp.error_class } else { 'worker_runtime_error' }
	}
}

fn (mut app App) kernel_dispatch_mcp(req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	_ = KernelDispatchEnvelope{
		kind: .mcp
		context: DispatchContext.from_mcp_dispatch_provider(req, app.logic_executor_provider())
	}
	return app.logic_executor.dispatch_mcp(mut app, req)
}

fn (mut app App) kernel_dispatch_mcp_handled(req WorkerMcpDispatchRequest) !KernelMcpDispatchOutcome {
	resp := app.kernel_dispatch_mcp(req)!
	if resp.error != '' || resp.commands.len == 0 {
		return KernelMcpDispatchOutcome{
			response:          resp
			command_snapshots: []WebSocketUpstreamCommandActivity{}
			command_error:     ''
		}
	}
	ctx := DispatchContext.from_mcp_dispatch_provider(req, app.logic_executor_provider())
	command_snapshots, command_error := app.execute_command_envelopes(req.id, ctx, resp.commands)
	return KernelMcpDispatchOutcome{
		response:          resp
		command_snapshots: command_snapshots
		command_error:     command_error
	}
}

fn (mut app App) kernel_dispatch_websocket_upstream(req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	_ = KernelDispatchEnvelope.from_websocket_upstream(req)
	return app.logic_executor.dispatch_websocket_upstream(mut app, req)
}

fn (mut app App) kernel_dispatch_websocket_upstream_handled(req WorkerWebSocketUpstreamDispatchRequest) !KernelWebSocketUpstreamDispatchOutcome {
	resp := app.kernel_dispatch_websocket_upstream(req)!
	if resp.error != '' || resp.commands.len == 0 {
		return KernelWebSocketUpstreamDispatchOutcome{
			response:          resp
			command_snapshots: []WebSocketUpstreamCommandActivity{}
			command_error:     ''
		}
	}
	ctx := DispatchContext.from_websocket_upstream(req)
	command_snapshots, command_error := app.execute_command_envelopes(req.id, ctx, resp.commands)
	return KernelWebSocketUpstreamDispatchOutcome{
		response:          resp
		command_snapshots: command_snapshots
		command_error:     command_error
	}
}

fn (mut app App) kernel_dispatch_websocket_event(frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	_ = KernelDispatchEnvelope{
		kind: .websocket_dispatch
		context: DispatchContext.from_websocket_dispatch_provider(frame, app.logic_executor_provider())
	}
	return app.logic_executor.dispatch_websocket_event(mut app, frame)
}

fn kernel_dispatch_transport_failure(err_msg string) KernelDispatchTransportFailure {
	status, error_class := classify_worker_error(err_msg)
	return KernelDispatchTransportFailure{
		status: status
		error_class: error_class
	}
}

fn (mut app App) kernel_stream_dispatch_open_request(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) StreamDispatchRequest {
	return StreamDispatchRequest{
		mode: 'stream'
		strategy: 'dispatch'
		event: 'open'
		id: req_id
		method: method.to_upper()
		path: path
		body: body
		remote_addr: remote_addr
		request_id: req_id
		trace_id: trace_id
		query: query.clone()
		headers: headers.clone()
		state: map[string]string{}
	}
}

fn (mut app App) kernel_stream_dispatch_open(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !StreamDispatchResponse {
	return app.kernel_dispatch_stream(app.kernel_stream_dispatch_open_request(method, path, body,
		remote_addr, req_id, trace_id, query, headers))
}

fn (mut app App) kernel_stream_dispatch_next_request(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) StreamDispatchRequest {
	return StreamDispatchRequest{
		mode: 'stream'
		strategy: 'dispatch'
		event: 'next'
		id: req_id
		method: method.to_upper()
		path: path
		body: ''
		remote_addr: remote_addr
		request_id: req_id
		trace_id: trace_id
		query: query.clone()
		headers: headers.clone()
		state: state.clone()
	}
}

fn (mut app App) kernel_stream_dispatch_next(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !StreamDispatchResponse {
	return app.kernel_dispatch_stream(app.kernel_stream_dispatch_next_request(method, path,
		remote_addr, req_id, trace_id, query, headers, state))
}

fn (mut app App) kernel_stream_dispatch_close_request(req_id string, trace_id string, state map[string]string, reason string) StreamDispatchRequest {
	return StreamDispatchRequest{
		mode: 'stream'
		strategy: 'dispatch'
		event: 'close'
		id: req_id
		request_id: req_id
		trace_id: trace_id
		state: state.clone()
		reason: reason
	}
}

fn (mut app App) kernel_stream_dispatch_close(req_id string, trace_id string, state map[string]string, reason string) !StreamDispatchResponse {
	return app.kernel_dispatch_stream(app.kernel_stream_dispatch_close_request(req_id, trace_id,
		state, reason))
}

fn (mut app App) kernel_mcp_dispatch_request(method string, path string, headers map[string]string, protocol_version string, body string, remote_addr string, req_id string, trace_id string, session_id string, client_capabilities_json string) WorkerMcpDispatchRequest {
	return WorkerMcpDispatchRequest{
		mode: 'mcp'
		event: 'message'
		id: req_id
		http_method: method
		path: path
		headers: headers.clone()
		protocol_version: protocol_version
		accept: headers['accept'] or { '' }
		content_type: headers['content-type'] or { '' }
		body: body
		jsonrpc_raw: body
		remote_addr: remote_addr
		request_id: req_id
		trace_id: trace_id
		session_id: session_id
		client_capabilities_json: client_capabilities_json
	}
}

fn (mut app App) kernel_websocket_upstream_dispatch_request(activity_id string, provider string, instance string, trace_id string, event_type string, message_id string, target string, target_type string, payload string, received_at i64, metadata map[string]string) WorkerWebSocketUpstreamDispatchRequest {
	return app.kernel_websocket_upstream_dispatch_request_with_event('message', activity_id,
		provider, instance, trace_id, event_type, message_id, target, target_type, payload,
		received_at, metadata)
}

fn (mut app App) kernel_websocket_upstream_dispatch_request_with_event(event string, activity_id string, provider string, instance string, trace_id string, event_type string, message_id string, target string, target_type string, payload string, received_at i64, metadata map[string]string) WorkerWebSocketUpstreamDispatchRequest {
	return WorkerWebSocketUpstreamDispatchRequest{
		mode: 'websocket_upstream'
		event: event
		id: activity_id
		provider: provider
		instance: instance
		trace_id: trace_id
		event_type: event_type
		message_id: message_id
		target: target
		target_type: target_type
		payload: payload
		received_at: received_at
		metadata: metadata.clone()
	}
}

fn (mut app App) kernel_websocket_dispatch_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, room_members map[string][]string, member_metadata map[string]map[string]string, room_counts map[string]int, presence_users map[string][]string) WorkerWebSocketFrame {
	return WorkerWebSocketFrame{
		mode: 'websocket_dispatch'
		event: event
		id: req_id
		path: path
		query: query.clone()
		headers: headers.clone()
		remote_addr: remote_addr
		request_id: req_id
		trace_id: trace_id
		opcode: opcode
		data: data
		code: code
		reason: reason
		rooms: rooms.clone()
		metadata: metadata.clone()
		room_members: room_members.clone()
		member_metadata: member_metadata.clone()
		room_counts: room_counts.clone()
		presence_users: presence_users.clone()
	}
}
