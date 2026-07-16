module main

import dispatch
import executor
import net.http
import upstream.transport

fn test_websocket_open_projects_to_session_exchange() {
	ctx := WebSocketExchangeContext{
		request_id: 'req-1'
		trace_id:   'trace-1'
		ingress:    'listener:web'
		pipeline:   'ws.pipeline'
	}
	ex := websocket_session_open_exchange(executor.WebSocketSessionOpenRequest{
		req:         http.Request{
			method: .get
			url:    '/ws'
		}
		remote_addr: '127.0.0.1:50000'
		path:        '/ws'
		request_id:  'req-1'
		trace_id:    'trace-1'
	}, executor.WebSocketSessionOpenOutcome{
		accepted:    true
		status:      101
		socket_path: '/tmp/vhttpd-ws.sock'
	}, ctx)
	assert ex.kind == .session_open
	assert ex.identity.id == 'req-1:open'
	assert ex.identity.parent_id == 'req-1'
	assert ex.identity.trace_id == 'trace-1'
	assert ex.ingress == 'listener:web'
	assert ex.pipeline == 'ws.pipeline'
	assert ex.headers['upgrade'] == 'websocket'
	assert ex.metadata['websocket.source'] == 'worker'
	assert ex.metadata['websocket.accepted'] == 'true'
	assert ex.metadata['websocket.status'] == '101'
	assert ex.metadata['websocket.path'] == '/ws'
	assert ex.metadata['websocket.remote_addr'] == '127.0.0.1:50000'
	assert ex.metadata['websocket.socket_path'] == '/tmp/vhttpd-ws.sock'
	match ex.payload {
		dispatch.SessionPayload {
			assert ex.payload.session_id == 'req-1'
			assert ex.payload.message == ''
		}
		else {
			assert false
		}
	}
}

fn test_worker_websocket_frame_projects_to_message_exchange() {
	ctx := WebSocketExchangeContext{
		request_id: 'req-2'
		trace_id:   'trace-2'
		ingress:    'listener:web'
		pipeline:   'ws.pipeline'
		session_id: 'conn-2'
	}
	ex := worker_websocket_frame_exchange(transport.WorkerWebSocketFrame{
		event:    'message'
		id:       'conn-2'
		opcode:   'text'
		data:     'hello'
		rooms:    ['room-a']
		headers:  {
			'x-ws': '1'
		}
		metadata: {
			'affinity_key': 'user:1'
		}
	}, ctx)
	assert ex.kind == .session_message
	assert ex.identity.id == 'conn-2:message'
	assert ex.identity.parent_id == 'conn-2'
	assert ex.metadata['websocket.source'] == 'worker'
	assert ex.metadata['websocket.event'] == 'message'
	assert ex.metadata['websocket.opcode'] == 'text'
	assert ex.metadata['affinity_key'] == 'user:1'
	assert ex.headers['x-ws'] == '1'
	match ex.payload {
		dispatch.SessionPayload {
			assert ex.payload.session_id == 'conn-2'
			assert ex.payload.message == 'hello'
			assert ex.payload.rooms == ['room-a']
		}
		else {
			assert false
		}
	}
}

fn test_runtime_websocket_close_projects_to_session_exchange() {
	ctx := WebSocketExchangeContext{
		request_id: 'req-3'
		trace_id:   'trace-3'
		ingress:    'listener:web'
		pipeline:   'ws.pipeline'
		session_id: 'conn-3'
	}
	ex := websocket_session_close_exchange(ctx, 'client_closed', {
		'close_by': 'client'
	})
	assert ex.kind == .session_close
	assert ex.identity.id == 'conn-3:close'
	assert ex.identity.request_id == 'req-3'
	assert ex.identity.trace_id == 'trace-3'
	assert ex.metadata['websocket.source'] == 'runtime'
	assert ex.metadata['websocket.event'] == 'close'
	assert ex.metadata['websocket.reason'] == 'client_closed'
	assert ex.metadata['close_by'] == 'client'
	match ex.payload {
		dispatch.SessionPayload {
			assert ex.payload.session_id == 'conn-3'
			assert ex.payload.message == 'client_closed'
		}
		else {
			assert false
		}
	}
}
