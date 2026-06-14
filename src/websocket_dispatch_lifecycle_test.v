module main

import ws

fn test_ws_dispatch_conn_state_uses_single_lifecycle_source() {
	mut lifecycle := &ws.DispatchConnState{}
	assert lifecycle.phase() == .opening
	assert !lifecycle.can_process_messages()
	assert lifecycle.can_queue()
	assert lifecycle.mark_open()
	assert lifecycle.can_process_messages()
	assert lifecycle.begin_worker_close()
	assert lifecycle.phase() == .closing
	assert !lifecycle.can_process_messages()
	should_process, worker_initiated := lifecycle.begin_peer_close()
	assert !should_process
	assert worker_initiated
	assert lifecycle.begin_cleanup()
	assert !lifecycle.begin_cleanup()
	assert lifecycle.phase() == .closed
}

fn test_worker_websocket_dispatch_finalize_cleans_hub_state_once() {
	mut app := App{}
	mut lifecycle := &ws.DispatchConnState{}
	app.transport.websocket.conns['conn_dispatch'] = ws.HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	app.transport.websocket.conn_rooms['conn_dispatch'] = {
		'room_dispatch': true
	}
	app.transport.websocket.room_members['room_dispatch'] = {
		'conn_dispatch': true
	}
	app.transport.websocket.conn_meta['conn_dispatch'] = {
		'relay_role': 'client'
	}
	app.transport.websocket.pending['conn_dispatch'] = [
		ws.HubPendingMessage{
			data:   'hello'
			opcode: 'text'
		},
	]
	rt := app.build_websocket_runtime_context()
	mut state := &ws.DispatchBridgeState{
		rt:        rt
		lifecycle: lifecycle
		conn_id:   'conn_dispatch'
	}
	ws.dispatch_session_finalize(state)
	assert lifecycle.phase() == .closed
	assert 'conn_dispatch' !in app.transport.websocket.conns
	assert 'conn_dispatch' !in app.transport.websocket.conn_rooms
	assert 'conn_dispatch' !in app.transport.websocket.conn_meta
	assert 'conn_dispatch' !in app.transport.websocket.pending
	assert 'room_dispatch' !in app.transport.websocket.room_members
	ws.dispatch_session_finalize(state)
	assert 'conn_dispatch' !in app.transport.websocket.conns
}

fn test_ws_hub_send_to_rejects_closing_dispatch_connection() {
	mut app := App{}
	mut lifecycle := &ws.DispatchConnState{}
	app.transport.websocket.conns['conn_dispatch'] = ws.HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	assert lifecycle.mark_closing()
	assert !ws.hub_send_to(mut app.transport.websocket, 'conn_dispatch', 'hello', 'text')
	assert 'conn_dispatch' !in app.transport.websocket.pending
}

fn test_ws_hub_send_to_queues_opening_dispatch_connection() {
	mut app := App{}
	mut lifecycle := &ws.DispatchConnState{}
	app.transport.websocket.conns['conn_dispatch'] = ws.HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	assert ws.hub_send_to(mut app.transport.websocket, 'conn_dispatch', 'hello', 'text')
	assert app.transport.websocket.pending['conn_dispatch'].len == 1
}
