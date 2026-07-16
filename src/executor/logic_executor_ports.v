module executor

import upstream.transport

pub struct LogicExecutorHttpPort {
	inner LogicExecutor
}

pub fn logic_executor_http_port(inner LogicExecutor) LogicExecutorHttpPort {
	return LogicExecutorHttpPort{
		inner: inner
	}
}

pub fn (port LogicExecutorHttpPort) model() LogicExecutorModel {
	return port.inner.model()
}

pub fn (port LogicExecutorHttpPort) kind() string {
	return port.inner.kind()
}

pub fn (port LogicExecutorHttpPort) provider() string {
	return port.inner.provider()
}

pub fn (port LogicExecutorHttpPort) admin_details() LogicExecutorAdminDetails {
	return port.inner.admin_details()
}

pub fn (port LogicExecutorHttpPort) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	return port.inner.dispatch_http(mut app, req)
}

pub struct LogicExecutorStreamPort {
	inner LogicExecutor
}

pub fn logic_executor_stream_port(inner LogicExecutor) LogicExecutorStreamPort {
	return LogicExecutorStreamPort{
		inner: inner
	}
}

pub fn (port LogicExecutorStreamPort) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return port.inner.dispatch_stream(mut app, req)
}

pub struct LogicExecutorMcpPort {
	inner LogicExecutor
}

pub fn logic_executor_mcp_port(inner LogicExecutor) LogicExecutorMcpPort {
	return LogicExecutorMcpPort{
		inner: inner
	}
}

pub fn (port LogicExecutorMcpPort) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return port.inner.dispatch_mcp(mut app, req)
}

pub struct LogicExecutorWebSocketSessionPort {
	inner LogicExecutor
}

pub fn logic_executor_websocket_session_port(inner LogicExecutor) LogicExecutorWebSocketSessionPort {
	return LogicExecutorWebSocketSessionPort{
		inner: inner
	}
}

pub fn (port LogicExecutorWebSocketSessionPort) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	return port.inner.open_websocket_session(mut app, req)
}

pub struct LogicExecutorWebSocketUpstreamPort {
	inner LogicExecutor
}

pub fn logic_executor_websocket_upstream_port(inner LogicExecutor) LogicExecutorWebSocketUpstreamPort {
	return LogicExecutorWebSocketUpstreamPort{
		inner: inner
	}
}

pub fn (port LogicExecutorWebSocketUpstreamPort) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return port.inner.dispatch_websocket_upstream(mut app, req)
}

pub struct LogicExecutorWebSocketEventPort {
	inner LogicExecutor
}

pub fn logic_executor_websocket_event_port(inner LogicExecutor) LogicExecutorWebSocketEventPort {
	return LogicExecutorWebSocketEventPort{
		inner: inner
	}
}

pub fn (port LogicExecutorWebSocketEventPort) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return port.inner.dispatch_websocket_event(mut app, frame)
}
