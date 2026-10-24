module executor

import upstream.transport

pub struct SocketWorkerExecutor {}

pub fn (e SocketWorkerExecutor) model() LogicExecutorModel {
	_ = e
	return .worker
}

pub fn (e SocketWorkerExecutor) kind() string {
	_ = e
	return 'php'
}

pub fn (e SocketWorkerExecutor) provider() string {
	_ = e
	return 'php-worker'
}

pub fn (e SocketWorkerExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'php'
		provider: 'php-worker'
		model:    LogicExecutorModel.worker.str()
	}
}

pub fn (e SocketWorkerExecutor) warmup(mut app AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e SocketWorkerExecutor) close() {
	_ = e
}

pub fn (e SocketWorkerExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	mut socket_port := worker_socket_port(app)
	config_port := worker_backend_config_port(app)
	return e.dispatch_http_with_worker_ports(mut socket_port, config_port, req)
}

pub fn (e SocketWorkerExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	mut socket_port := worker_socket_port(app)
	config_port := worker_backend_config_port(app)
	return e.open_websocket_session_with_worker_ports(mut socket_port, config_port, req)
}

pub fn (e SocketWorkerExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	mut port := worker_stream_dispatch_port(app)
	return port.worker_backend_dispatch_stream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	mut port := worker_mcp_dispatch_port(app)
	return port.worker_backend_dispatch_mcp(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	mut port := worker_websocket_dispatch_port(app)
	return port.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	mut port := worker_websocket_dispatch_port(app)
	return port.worker_backend_dispatch_websocket_event(frame)
}
