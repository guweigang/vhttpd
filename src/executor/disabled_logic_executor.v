module executor

import upstream.transport

pub struct DisabledLogicExecutor {}

pub fn (e DisabledLogicExecutor) model() LogicExecutorModel {
	_ = e
	return .worker
}

pub fn (e DisabledLogicExecutor) kind() string {
	_ = e
	return 'none'
}

pub fn (e DisabledLogicExecutor) provider() string {
	_ = e
	return 'none'
}

pub fn (e DisabledLogicExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'none'
		provider: 'none'
		model:    LogicExecutorModel.worker.str()
	}
}

pub fn (e DisabledLogicExecutor) warmup(mut app AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e DisabledLogicExecutor) close() {
	_ = e
}

pub fn (e DisabledLogicExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('logic_executor_disabled')
}
