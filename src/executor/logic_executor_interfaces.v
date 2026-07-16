module executor

import upstream.transport

pub interface LogicExecutorIdentity {
	model() LogicExecutorModel
	kind() string
	provider() string
	admin_details() LogicExecutorAdminDetails
}

pub interface LogicExecutorLifecycleOps {
	warmup(mut app AppFacade) !
	close()
}

pub interface HttpLogicExecutor {
	dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome
}

pub interface WebSocketSessionExecutor {
	open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome
}

pub interface StreamLogicExecutor {
	dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
}

pub interface McpLogicExecutor {
	dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
}

pub interface WebSocketUpstreamExecutor {
	dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
}

pub interface WebSocketEventExecutor {
	dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
}

pub interface LogicExecutor {
	LogicExecutorIdentity
	LogicExecutorLifecycleOps
	HttpLogicExecutor
	WebSocketSessionExecutor
	StreamLogicExecutor
	McpLogicExecutor
	WebSocketUpstreamExecutor
	WebSocketEventExecutor
}
