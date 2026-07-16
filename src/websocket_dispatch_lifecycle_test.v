module main

import ws

fn test_websocket_runtime_owns_initialized_hub_state() {
	runtime := WebSocketRuntime.new(true)
	assert runtime.state.dispatch_mode
	assert runtime.state.recent_dispatch_limit == 50
	assert runtime.state.auto_start_dynamic_upstreams
	assert runtime.state.conns.len == 0
}

fn test_websocket_runtime_builds_hub_context_without_app_capture() {
	mut runtime := WebSocketRuntime.new(false)
	rt := runtime.build_context(WebSocketKernelPort{})
	assert rt.send_to('pending-connection', 'hello', 'text')
	assert runtime.state.pending['pending-connection'].len == 1
	assert rt.rooms('pending-connection').len == 0
}

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
	app.websocket.state.conns['conn_dispatch'] = ws.HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	app.websocket.state.conn_rooms['conn_dispatch'] = {
		'room_dispatch': true
	}
	app.websocket.state.room_members['room_dispatch'] = {
		'conn_dispatch': true
	}
	app.websocket.state.conn_meta['conn_dispatch'] = {
		'relay_role': 'client'
	}
	app.websocket.state.pending['conn_dispatch'] = [
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
	assert 'conn_dispatch' !in app.websocket.state.conns
	assert 'conn_dispatch' !in app.websocket.state.conn_rooms
	assert 'conn_dispatch' !in app.websocket.state.conn_meta
	assert 'conn_dispatch' !in app.websocket.state.pending
	assert 'room_dispatch' !in app.websocket.state.room_members
	ws.dispatch_session_finalize(state)
	assert 'conn_dispatch' !in app.websocket.state.conns
}

fn test_ws_hub_send_to_rejects_closing_dispatch_connection() {
	mut app := App{}
	mut lifecycle := &ws.DispatchConnState{}
	app.websocket.state.conns['conn_dispatch'] = ws.HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	assert lifecycle.mark_closing()
	assert !ws.hub_send_to(mut app.websocket.state, 'conn_dispatch', 'hello', 'text')
	assert 'conn_dispatch' !in app.websocket.state.pending
}

fn test_ws_hub_send_to_queues_opening_dispatch_connection() {
	mut app := App{}
	mut lifecycle := &ws.DispatchConnState{}
	app.websocket.state.conns['conn_dispatch'] = ws.HubConn{
		id:        'conn_dispatch'
		lifecycle: lifecycle
	}
	assert ws.hub_send_to(mut app.websocket.state, 'conn_dispatch', 'hello', 'text')
	assert app.websocket.state.pending['conn_dispatch'].len == 1
}
