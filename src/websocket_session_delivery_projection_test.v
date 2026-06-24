module main

import executor
import upstream.transport

fn test_worker_websocket_session_delivery_outcome_projects_worker_session() {
	outcome := worker_websocket_session_delivery_outcome(executor.WebSocketSessionOpenOutcome{
		accepted:    true
		status:      101
		socket_path: '/tmp/ws.sock'
	}, 'req-1', '/ws')

	assert outcome.kind == .session_plan
	assert outcome.status == 101
	assert outcome.target == 'websocket:req-1'
	assert outcome.headers['upgrade'] == 'websocket'
	assert outcome.metadata['response_mode'] == 'websocket'
	assert outcome.metadata['session_protocol'] == 'websocket'
	assert outcome.metadata['session_transport'] == 'websocket'
	assert outcome.metadata['websocket_backend'] == 'worker'
	assert outcome.metadata['websocket_conn_id'] == 'req-1'
	assert outcome.metadata['websocket_path'] == '/ws'
	assert outcome.metadata['worker_socket'] == '/tmp/ws.sock'
}

fn test_dispatch_websocket_session_delivery_outcome_projects_dispatch_session() {
	outcome := dispatch_websocket_session_delivery_outcome(transport.WorkerWebSocketDispatchResponse{
		accepted:     true
		affinity_key: 'room-1'
		commands:     [
			transport.WorkerWebSocketFrame{
				event: 'send'
			},
			transport.WorkerWebSocketFrame{
				event: 'join'
			},
		]
	}, 'req-2', '/ws/dispatch')

	assert outcome.kind == .session_plan
	assert outcome.status == 101
	assert outcome.target == 'websocket:req-2'
	assert outcome.headers['upgrade'] == 'websocket'
	assert outcome.metadata['websocket_backend'] == 'dispatch'
	assert outcome.metadata['websocket_conn_id'] == 'req-2'
	assert outcome.metadata['websocket_path'] == '/ws/dispatch'
	assert outcome.metadata['command_count'] == '2'
	assert outcome.metadata['affinity_key'] == 'room-1'
}
