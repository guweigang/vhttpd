module executor

import upstream.transport

pub struct PhpCgiExecutor {}

pub fn (e PhpCgiExecutor) model() LogicExecutorModel {
	_ = e
	return .worker
}

pub fn (e PhpCgiExecutor) kind() string {
	_ = e
	return 'php-cgi'
}

pub fn (e PhpCgiExecutor) provider() string {
	_ = e
	return 'php-cgi'
}

pub fn (e PhpCgiExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'php-cgi'
		provider: 'php-cgi'
		model:    LogicExecutorModel.worker.str()
	}
}

pub fn (e PhpCgiExecutor) warmup(mut app AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e PhpCgiExecutor) close() {
	_ = e
}

pub fn (e PhpCgiExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	mut socket_port := worker_socket_port(app)
	config_port := worker_backend_config_port(app)
	return e.dispatch_http_with_worker_ports(mut socket_port, config_port, req)
}

pub fn (e PhpCgiExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support websockets')
}

pub fn (e PhpCgiExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support stream dispatch')
}

pub fn (e PhpCgiExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support MCP dispatch')
}

pub fn (e PhpCgiExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support websocket upstream')
}

pub fn (e PhpCgiExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('php-cgi executor does not support websocket events')
}
