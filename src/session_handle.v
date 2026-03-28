module main

pub enum RuntimeRole {
	ingress
	external_upstream
	backend_worker
}

pub struct SessionHandle {
pub:
	id         string
	request_id string
	trace_id   string
	role       RuntimeRole
	provider   string
	transport  string
	stream_type string
	source     string
	instance   string
}

pub fn SessionHandle.from_websocket_upstream(req WorkerWebSocketUpstreamDispatchRequest) SessionHandle {
	return SessionHandle{
		id:          req.id
		request_id:  req.id
		trace_id:    req.trace_id
		role:        .external_upstream
		provider:    req.provider
		transport:   'websocket_upstream'
		stream_type: req.target_type
		source:      req.event_type
		instance:    req.instance
	}
}

pub fn SessionHandle.from_stream_dispatch(req StreamDispatchRequest) SessionHandle {
	return SessionHandle.from_stream_dispatch_provider(req, 'php-worker')
}

pub fn SessionHandle.from_stream_dispatch_provider(req StreamDispatchRequest, provider string) SessionHandle {
	return SessionHandle{
		id:          req.id
		request_id:  req.request_id
		trace_id:    req.trace_id
		role:        .backend_worker
		provider:    provider
		transport:   'worker_backend'
		stream_type: req.strategy
		source:      req.event
		instance:    ''
	}
}

pub fn SessionHandle.from_mcp_dispatch(req WorkerMcpDispatchRequest) SessionHandle {
	return SessionHandle.from_mcp_dispatch_provider(req, 'php-worker')
}

pub fn SessionHandle.from_mcp_dispatch_provider(req WorkerMcpDispatchRequest, provider string) SessionHandle {
	return SessionHandle{
		id:          req.id
		request_id:  req.request_id
		trace_id:    req.trace_id
		role:        .backend_worker
		provider:    provider
		transport:   'worker_backend'
		stream_type: 'mcp'
		source:      req.event
		instance:    req.session_id
	}
}

pub fn SessionHandle.from_websocket_dispatch(frame WorkerWebSocketFrame) SessionHandle {
	return SessionHandle.from_websocket_dispatch_provider(frame, 'php-worker')
}

pub fn SessionHandle.from_websocket_dispatch_provider(frame WorkerWebSocketFrame, provider string) SessionHandle {
	return SessionHandle{
		id:          frame.id
		request_id:  frame.request_id
		trace_id:    frame.trace_id
		role:        .backend_worker
		provider:    provider
		transport:   'worker_backend'
		stream_type: 'websocket_dispatch'
		source:      frame.event
		instance:    ''
	}
}
