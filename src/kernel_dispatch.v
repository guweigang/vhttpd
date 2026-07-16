module main

import upstream.transport
import executor
import dispatch

struct KernelDispatchFailureMapper {}

fn (mut app App) kernel_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = executor.KernelDispatchEnvelope{
		kind:    .stream
		context: DispatchContext.from_stream_dispatch_provider(req, app.logic_executor_provider())
	}
	mut facade := app.as_facade()
	return app.engines.dispatch_stream(mut facade, req)
}

fn kernel_stream_dispatch_failure(resp transport.StreamDispatchResponse) ?executor.KernelStreamDispatchFailure {
	result := dispatch.stream_failure(resp) or { return none }
	return executor.KernelStreamDispatchFailure{
		error:       result.error
		error_class: result.error_class
	}
}

fn KernelDispatchFailureMapper.from_stream_response(resp transport.StreamDispatchResponse) ?executor.KernelStreamDispatchFailure {
	return kernel_stream_dispatch_failure(resp)
}

fn (mut app App) kernel_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = executor.KernelDispatchEnvelope{
		kind:    .mcp
		context: DispatchContext.from_mcp_dispatch_provider(req, app.logic_executor_provider())
	}
	mut facade := app.as_facade()
	return app.engines.dispatch_mcp(mut facade, req)
}

fn (mut app App) kernel_dispatch_mcp_handled(req transport.WorkerMcpDispatchRequest) !executor.KernelMcpDispatchOutcome {
	resp := app.kernel_dispatch_mcp(req)!
	if resp.error != '' || resp.commands.len == 0 {
		return executor.KernelMcpDispatchOutcome{
			response:          resp
			command_snapshots: []executor.WebSocketUpstreamCommandActivity{}
			command_error:     ''
		}
	}
	ctx := DispatchContext.from_mcp_dispatch_provider(req, app.logic_executor_provider())
	command_snapshots, command_error := app.execute_command_envelopes_with_snapshots(req.id, ctx,
		resp.commands)
	return executor.KernelMcpDispatchOutcome{
		response:          resp
		command_snapshots: command_snapshots
		command_error:     command_error
	}
}

fn (mut app App) kernel_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = executor.KernelDispatchEnvelope.from_websocket_upstream(req)
	mut facade := app.as_facade()
	return app.engines.dispatch_websocket_upstream(mut facade, req)
}

fn (mut app App) kernel_dispatch_websocket_upstream_handled(req transport.WorkerWebSocketUpstreamDispatchRequest) !executor.KernelWebSocketUpstreamDispatchOutcome {
	resp := app.kernel_dispatch_websocket_upstream(req)!
	if resp.error != '' || resp.commands.len == 0 {
		return executor.KernelWebSocketUpstreamDispatchOutcome{
			response:          resp
			command_snapshots: []executor.WebSocketUpstreamCommandActivity{}
			command_error:     ''
		}
	}
	ctx := DispatchContext.from_websocket_upstream(req)
	command_snapshots, command_error := app.execute_command_envelopes_with_snapshots(req.id, ctx,
		resp.commands)
	return executor.KernelWebSocketUpstreamDispatchOutcome{
		response:          resp
		command_snapshots: command_snapshots
		command_error:     command_error
	}
}

fn (mut app App) kernel_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = executor.KernelDispatchEnvelope{
		kind:    .websocket_dispatch
		context: DispatchContext.from_websocket_dispatch_provider(frame,
			app.logic_executor_provider())
	}
	mut facade := app.as_facade()
	return app.engines.dispatch_websocket_event(mut facade, frame)
}

fn kernel_dispatch_transport_failure(err_msg string) executor.KernelDispatchTransportFailure {
	return dispatch.transport_failure(err_msg)
}

fn (mut app App) kernel_stream_dispatch_open_request(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) transport.StreamDispatchRequest {
	_ = app
	return dispatch.build_stream_open_request(method, path, body, remote_addr, req_id, trace_id,
		query, headers)
}

fn (mut app App) kernel_stream_dispatch_open(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
	return app.kernel_dispatch_stream(dispatch.build_stream_open_request(method, path, body,
		remote_addr, req_id, trace_id, query, headers))
}

fn (mut app App) kernel_stream_dispatch_next_request(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) transport.StreamDispatchRequest {
	_ = app
	return dispatch.build_stream_next_request(method, path, remote_addr, req_id, trace_id, query,
		headers, state)
}

fn (mut app App) kernel_stream_dispatch_next(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
	return app.kernel_dispatch_stream(dispatch.build_stream_next_request(method, path, remote_addr,
		req_id, trace_id, query, headers, state))
}

fn (mut app App) kernel_stream_dispatch_close_request(req_id string, trace_id string, state map[string]string, reason string) transport.StreamDispatchRequest {
	_ = app
	return dispatch.build_stream_close_request(req_id, trace_id, state, reason)
}

fn (mut app App) kernel_stream_dispatch_close(req_id string, trace_id string, state map[string]string, reason string) !transport.StreamDispatchResponse {
	return app.kernel_dispatch_stream(dispatch.build_stream_close_request(req_id, trace_id, state,
		reason))
}

fn (mut app App) kernel_mcp_dispatch_request(method string, path string, headers map[string]string, protocol_version string, body string, remote_addr string, req_id string, trace_id string, session_id string, client_capabilities_json string) transport.WorkerMcpDispatchRequest {
	_ = app
	return dispatch.build_mcp_message_request(method, path, headers, protocol_version, body,
		remote_addr, req_id, trace_id, session_id, client_capabilities_json)
}

fn (mut app App) kernel_websocket_upstream_dispatch_request(activity_id string, provider string, instance string, trace_id string, event_type string, message_id string, target string, target_type string, payload string, received_at i64, metadata map[string]string) transport.WorkerWebSocketUpstreamDispatchRequest {
	_ = app
	return dispatch.build_websocket_upstream_request(activity_id, provider, instance, trace_id,
		event_type, message_id, target, target_type, payload, received_at, metadata)
}

fn (mut app App) kernel_websocket_upstream_dispatch_request_with_event(event string, activity_id string, provider string, instance string, trace_id string, event_type string, message_id string, target string, target_type string, payload string, received_at i64, metadata map[string]string) transport.WorkerWebSocketUpstreamDispatchRequest {
	_ = app
	return dispatch.build_websocket_upstream_request_with_event(event, activity_id, provider,
		instance, trace_id, event_type, message_id, target, target_type, payload, received_at,
		metadata)
}

fn (mut app App) kernel_websocket_dispatch_frame(event string, _method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, room_members map[string][]string, member_metadata map[string]map[string]string, room_counts map[string]int, presence_users map[string][]string) transport.WorkerWebSocketFrame {
	_ = app
	return dispatch.build_websocket_dispatch_frame(event, _method, path, query, headers,
		remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata, room_members,
		member_metadata, room_counts, presence_users)
}
