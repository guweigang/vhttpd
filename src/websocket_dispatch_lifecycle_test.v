module main

fn test_ws_dispatch_conn_state_uses_single_lifecycle_source() {
	mut lifecycle := &WebSocketDispatchConnState{}
	assert ws_dispatch_conn_phase(lifecycle) == .opening
	assert !ws_dispatch_conn_can_process_messages(lifecycle)
	assert ws_dispatch_conn_can_queue(lifecycle)
	assert ws_dispatch_conn_mark_open(lifecycle)
	assert ws_dispatch_conn_can_process_messages(lifecycle)
	assert ws_dispatch_conn_begin_worker_close(lifecycle)
	assert ws_dispatch_conn_phase(lifecycle) == .closing
	assert !ws_dispatch_conn_can_process_messages(lifecycle)
	should_process, worker_initiated := ws_dispatch_conn_begin_peer_close(lifecycle)
	assert !should_process
	assert worker_initiated
	assert ws_dispatch_conn_begin_cleanup(lifecycle)
	assert !ws_dispatch_conn_begin_cleanup(lifecycle)
	assert ws_dispatch_conn_phase(lifecycle) == .closed
}

fn test_worker_websocket_dispatch_finalize_cleans_hub_state_once() {
	mut app := App{}
	mut lifecycle := &WebSocketDispatchConnState{}
	app.ws_hub_conns['conn_dispatch'] = HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	app.ws_hub_conn_rooms['conn_dispatch'] = {
		'room_dispatch': true
	}
	app.ws_hub_room_members['room_dispatch'] = {
		'conn_dispatch': true
	}
	app.ws_hub_conn_meta['conn_dispatch'] = {
		'relay_role': 'client'
	}
	app.ws_hub_pending['conn_dispatch'] = [
		HubPendingMessage{
			data:   'hello'
			opcode: 'text'
		},
	]
	mut state := &WebSocketDispatchBridgeState{
		app:       &app
		lifecycle: lifecycle
		conn_id:   'conn_dispatch'
	}
	worker_websocket_dispatch_finalize(state)
	assert ws_dispatch_conn_phase(lifecycle) == .closed
	assert !('conn_dispatch' in app.ws_hub_conns)
	assert !('conn_dispatch' in app.ws_hub_conn_rooms)
	assert !('conn_dispatch' in app.ws_hub_conn_meta)
	assert !('conn_dispatch' in app.ws_hub_pending)
	assert !('room_dispatch' in app.ws_hub_room_members)
	worker_websocket_dispatch_finalize(state)
	assert !('conn_dispatch' in app.ws_hub_conns)
}

fn test_ws_hub_send_to_rejects_closing_dispatch_connection() {
	mut app := App{}
	mut lifecycle := &WebSocketDispatchConnState{}
	app.ws_hub_conns['conn_dispatch'] = HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	assert ws_dispatch_conn_mark_closing(lifecycle)
	assert !app.ws_hub_send_to('conn_dispatch', 'hello', 'text')
	assert !('conn_dispatch' in app.ws_hub_pending)
}

fn test_ws_hub_send_to_queues_opening_dispatch_connection() {
	mut app := App{}
	mut lifecycle := &WebSocketDispatchConnState{}
	app.ws_hub_conns['conn_dispatch'] = HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	assert app.ws_hub_send_to('conn_dispatch', 'hello', 'text')
	assert app.ws_hub_pending['conn_dispatch'].len == 1
}
