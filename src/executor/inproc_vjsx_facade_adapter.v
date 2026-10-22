module executor

import upstream.transport

// Polymorphic executor entry points adapt the broad facade exactly once.

pub fn (e InProcVjsxExecutor) warmup(mut app AppFacade) ! {
	mut host := EmbeddedHost(app)
	e.warmup_with_host(mut host)!
}

pub fn (e InProcVjsxExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	mut host := EmbeddedHost(app)
	return e.dispatch_http_with_host(mut host, req)
}

pub fn (e InProcVjsxExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	mut host := EmbeddedHost(app)
	return e.open_websocket_session_with_host(mut host, req)
}

pub fn (e InProcVjsxExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	mut host := EmbeddedHost(app)
	return e.dispatch_stream_with_host(mut host, req)
}

pub fn (e InProcVjsxExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut host := EmbeddedHost(app)
	return e.dispatch_mcp_with_host(mut host, req)
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut host := EmbeddedHost(app)
	return e.dispatch_websocket_upstream_with_host(mut host, req)
}

pub fn (e InProcVjsxExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut host := EmbeddedHost(app)
	return e.dispatch_websocket_event_with_host(mut host, frame)
}
