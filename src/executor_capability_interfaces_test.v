module main

import executor

fn accepts_executor_identity(e executor.LogicExecutorIdentity) string {
	return e.provider()
}

fn accepts_executor_lifecycle_ops(e executor.LogicExecutorLifecycleOps) bool {
	_ = e
	return true
}

fn accepts_http_executor(e executor.HttpLogicExecutor) bool {
	_ = e
	return true
}

fn accepts_websocket_session_executor(e executor.WebSocketSessionExecutor) bool {
	_ = e
	return true
}

fn accepts_stream_executor(e executor.StreamLogicExecutor) bool {
	_ = e
	return true
}

fn accepts_mcp_executor(e executor.McpLogicExecutor) bool {
	_ = e
	return true
}

fn accepts_websocket_upstream_executor(e executor.WebSocketUpstreamExecutor) bool {
	_ = e
	return true
}

fn accepts_websocket_event_executor(e executor.WebSocketEventExecutor) bool {
	_ = e
	return true
}

fn test_builtin_logic_executors_satisfy_capability_interfaces() {
	disabled := executor.DisabledLogicExecutor{}
	assert accepts_executor_identity(disabled) != ''
	assert accepts_executor_lifecycle_ops(disabled)
	assert accepts_http_executor(disabled)
	assert accepts_websocket_session_executor(disabled)
	assert accepts_stream_executor(disabled)
	assert accepts_mcp_executor(disabled)
	assert accepts_websocket_upstream_executor(disabled)
	assert accepts_websocket_event_executor(disabled)

	worker := executor.SocketWorkerExecutor{}
	assert accepts_executor_identity(worker) != ''
	assert accepts_executor_lifecycle_ops(worker)
	assert accepts_http_executor(worker)
	assert accepts_websocket_session_executor(worker)
	assert accepts_stream_executor(worker)
	assert accepts_mcp_executor(worker)
	assert accepts_websocket_upstream_executor(worker)
	assert accepts_websocket_event_executor(worker)

	cgi := executor.PhpCgiExecutor{}
	assert accepts_executor_identity(cgi) != ''
	assert accepts_executor_lifecycle_ops(cgi)
	assert accepts_http_executor(cgi)
	assert accepts_websocket_session_executor(cgi)
	assert accepts_stream_executor(cgi)
	assert accepts_mcp_executor(cgi)
	assert accepts_websocket_upstream_executor(cgi)
	assert accepts_websocket_event_executor(cgi)
}

fn test_logic_executor_ports_satisfy_capability_interfaces() {
	exec := executor.DisabledLogicExecutor{}
	http_port := executor.logic_executor_http_port(exec)
	assert accepts_executor_identity(http_port) == 'none'
	assert accepts_http_executor(http_port)

	stream_port := executor.logic_executor_stream_port(exec)
	assert accepts_stream_executor(stream_port)

	mcp_port := executor.logic_executor_mcp_port(exec)
	assert accepts_mcp_executor(mcp_port)

	ws_session_port := executor.logic_executor_websocket_session_port(exec)
	assert accepts_websocket_session_executor(ws_session_port)

	ws_upstream_port := executor.logic_executor_websocket_upstream_port(exec)
	assert accepts_websocket_upstream_executor(ws_upstream_port)

	ws_event_port := executor.logic_executor_websocket_event_port(exec)
	assert accepts_websocket_event_executor(ws_event_port)
}
