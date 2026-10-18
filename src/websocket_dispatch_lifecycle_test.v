module main

import ws
import upstream.transport

fn test_websocket_runtime_owns_initialized_hub_state() {
	runtime := WebSocketRuntime.new(true)
	assert runtime.state.dispatch_mode
	assert runtime.state.recent_dispatch_limit == 50
	assert runtime.state.auto_start_dynamic_upstreams
	assert runtime.state.conns.len == 0
}

fn test_websocket_runtime_builds_hub_context_without_app_capture() {
	mut runtime := WebSocketRuntime.new(false)
	mut app := App{}
	rt := runtime.build_context(app.build_websocket_kernel_port())
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

@[heap]
struct WebSocketKernelProbe {
mut:
	builds     int
	dispatches int
}

fn test_websocket_command_context_keeps_injected_kernel_for_broadcast_dispatch() {
	mut runtime := WebSocketRuntime.new(true)
	mut probe := &WebSocketKernelProbe{}
	runtime.state.conns['target'] = ws.HubConn{
		id:         'target'
		path:       '/chat'
		request_id: 'req'
		trace_id:   'trace'
		lifecycle:  &ws.DispatchConnState{}
	}
	runtime.state.room_members['room'] = {
		'target': true
	}
	kernel := WebSocketKernelPort{
		build_frame_fn:    fn [mut probe] (event string, _method string, path string, _query map[string]string, _headers map[string]string, _remote string, id string, trace string, _opcode string, data string, _code int, _reason string, _rooms []string, _metadata map[string]string, _presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
			probe.builds++
			return transport.WorkerWebSocketFrame{ event: event, path: path, request_id: id, trace_id: trace, data: data }
		}
		dispatch_event_fn: fn [mut probe] (frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			probe.dispatches++
			assert frame.event == 'info'
			assert frame.path == '/chat'
			assert frame.trace_id == 'trace'
			assert frame.data == 'payload'
			return transport.WorkerWebSocketDispatchResponse{ commands: [transport.WorkerWebSocketFrame{ event: 'set_meta', key: 'seen', value: 'yes' }] }
		}
	}
	result := runtime.execute_commands([transport.WorkerWebSocketFrame{ event: 'broadcast_dispatch', room: 'room', data: 'payload' }], kernel)
	assert result.failures.len == 0
	assert probe.builds == 1
	assert probe.dispatches == 1
	assert runtime.state.meta_snapshot('target')['seen'] == 'yes'
}

fn test_hub_flush_without_client_retains_pending_messages() {
	mut hub := ws.HubState{}
	hub.conns['pending'] = ws.HubConn{ id: 'pending', lifecycle: &ws.DispatchConnState{ phase: .open } }
	hub.pending['pending'] = [ws.HubPendingMessage{ data: 'queued', opcode: 'text' }]
	hub.flush_pending('pending')
	assert hub.pending['pending'].len == 1
	assert hub.pending['pending'][0].data == 'queued'
	assert !ws.hub_send_to(mut hub, 'pending', 'next', 'text')
	ws.hub_close_target(mut hub, 'pending', 1000, 'close')
	assert !hub.conn_open('pending')
}

fn test_dispatch_finalizer_and_local_close_preserve_replacement_session_identity() {
	mut app := &App{}
	mut old := &ws.DispatchConnState{ phase: .open }
	mut current := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: current }
	app.websocket.state.pending['same'] = [ws.HubPendingMessage{ data: 'replacement' }]
	rt := app.build_websocket_runtime_context()
	mut state := &ws.DispatchBridgeState{ rt: rt, lifecycle: old, conn_id: 'same' }
	ws.dispatch_session_finalize(state)
	rt.close_owned_target('same', old, 1008, 'stale')
	assert old.phase() == .closed
	assert current.phase() == .open
	assert voidptr((app.websocket.state.conns['same'] or { panic('replacement') }).lifecycle) == voidptr(current)
	assert app.websocket.state.pending['same'][0].data == 'replacement'
	mut replacement := &ws.DispatchBridgeState{ rt: rt, lifecycle: current, conn_id: 'same' }
	ws.dispatch_session_finalize(replacement)
	assert app.websocket.state.conns.len == 0
	assert app.websocket.state.pending.len == 0
}

fn test_relay_context_cleanup_only_releases_its_own_lifecycle() {
	mut runtime := WebSocketRuntime.new(false)
	mut old := &ws.DispatchConnState{ phase: .open }
	mut current := &ws.DispatchConnState{ phase: .open }
	runtime.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: current }
	runtime.state.pending['same'] = [ws.HubPendingMessage{ data: 'replacement' }]
	rt := runtime.build_relay_session_context()
	assert !rt.mark_closing('same', old)
	old.mark_closing()
	assert old.begin_cleanup()
	rt.cleanup_conn('same', old)
	assert current.phase() == .open
	assert runtime.state.pending['same'][0].data == 'replacement'
	assert rt.mark_closing('same', current)
	assert current.begin_cleanup()
	rt.cleanup_conn('same', current)
	assert runtime.state.conns.len == 0
}
