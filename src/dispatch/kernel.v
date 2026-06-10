module dispatch

import transport
import executor

pub type KernelDispatchKind = executor.KernelDispatchKind
pub type KernelDispatchTransportFailure = executor.KernelDispatchTransportFailure
pub type KernelWebSocketUpstreamDispatchOutcome = executor.KernelWebSocketUpstreamDispatchOutcome
pub type KernelMcpDispatchOutcome = executor.KernelMcpDispatchOutcome
pub type KernelStreamDispatchFailure = executor.KernelStreamDispatchFailure

pub fn stream_failure(resp transport.StreamDispatchResponse) ?KernelStreamDispatchFailure {
	if resp.event != 'error' {
		return none
	}
	return KernelStreamDispatchFailure{
		error:       resp.error
		error_class: if resp.error_class != '' { resp.error_class } else { 'worker_runtime_error' }
	}
}

pub fn transport_failure(err_msg string) KernelDispatchTransportFailure {
	status, error_class := transport.classify_worker_backend_error(err_msg)
	return KernelDispatchTransportFailure{
		status:      status
		error_class: error_class
	}
}

pub fn build_stream_open_request(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) transport.StreamDispatchRequest {
	return transport.StreamDispatchRequest{
		mode:        'stream'
		strategy:    'dispatch'
		event:       'open'
		id:          req_id
		method:      method.to_upper()
		path:        path
		body:        body
		remote_addr: remote_addr
		request_id:  req_id
		trace_id:    trace_id
		query:       query.clone()
		headers:     headers.clone()
		state:       map[string]string{}
	}
}

pub fn build_stream_next_request(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) transport.StreamDispatchRequest {
	return transport.StreamDispatchRequest{
		mode:        'stream'
		strategy:    'dispatch'
		event:       'next'
		id:          req_id
		method:      method.to_upper()
		path:        path
		body:        ''
		remote_addr: remote_addr
		request_id:  req_id
		trace_id:    trace_id
		query:       query.clone()
		headers:     headers.clone()
		state:       state.clone()
	}
}

pub fn build_stream_close_request(req_id string, trace_id string, state map[string]string, reason string) transport.StreamDispatchRequest {
	return transport.StreamDispatchRequest{
		mode:       'stream'
		strategy:   'dispatch'
		event:      'close'
		id:         req_id
		request_id: req_id
		trace_id:   trace_id
		state:      state.clone()
		reason:     reason
	}
}

pub fn build_mcp_message_request(method string, path string, headers map[string]string, protocol_version string, body string, remote_addr string, req_id string, trace_id string, session_id string, client_capabilities_json string) transport.WorkerMcpDispatchRequest {
	return transport.WorkerMcpDispatchRequest{
		mode:                     'mcp'
		event:                    'message'
		id:                       req_id
		http_method:              method
		path:                     path
		headers:                  headers.clone()
		protocol_version:         protocol_version
		accept:                   headers['accept'] or { '' }
		content_type:             headers['content-type'] or { '' }
		body:                     body
		jsonrpc_raw:              body
		remote_addr:              remote_addr
		request_id:               req_id
		trace_id:                 trace_id
		session_id:               session_id
		client_capabilities_json: client_capabilities_json
	}
}

pub fn build_websocket_upstream_request(activity_id string, provider string, instance string, trace_id string, event_type string, message_id string, target string, target_type string, payload string, received_at i64, metadata map[string]string) transport.WorkerWebSocketUpstreamDispatchRequest {
	return build_websocket_upstream_request_with_event('message', activity_id, provider, instance,
		trace_id, event_type, message_id, target, target_type, payload, received_at, metadata)
}

pub fn build_websocket_upstream_request_with_event(event string, activity_id string, provider string, instance string, trace_id string, event_type string, message_id string, target string, target_type string, payload string, received_at i64, metadata map[string]string) transport.WorkerWebSocketUpstreamDispatchRequest {
	return transport.WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       event
		id:          activity_id
		provider:    provider
		instance:    instance
		trace_id:    trace_id
		event_type:  event_type
		message_id:  message_id
		target:      target
		target_type: target_type
		payload:     payload
		received_at: received_at
		metadata:    metadata.clone()
	}
}

pub fn build_websocket_dispatch_frame(event string, _method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, room_members map[string][]string, member_metadata map[string]map[string]string, room_counts map[string]int, presence_users map[string][]string) transport.WorkerWebSocketFrame {
	_ = _method
	return transport.WorkerWebSocketFrame{
		mode:            'websocket_dispatch'
		event:           event
		id:              req_id
		path:            path
		query:           query.clone()
		headers:         headers.clone()
		remote_addr:     remote_addr
		request_id:      req_id
		trace_id:        trace_id
		opcode:          opcode
		data:            data
		code:            code
		reason:          reason
		rooms:           rooms.clone()
		metadata:        metadata.clone()
		room_members:    room_members.clone()
		member_metadata: member_metadata.clone()
		room_counts:     room_counts.clone()
		presence_users:  presence_users.clone()
	}
}

fn classify_transport_error(err_msg string) (int, string) {
	return transport.classify_worker_backend_error(err_msg)
}
