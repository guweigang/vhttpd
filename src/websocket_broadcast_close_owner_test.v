module main

import upstream.transport
import ws

fn broadcast_close_owner_app() (&App, &ws.DispatchConnState) {
	mut app := &App{}
	mut lifecycle := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.conns['target'] = ws.HubConn{ id: 'target', lifecycle: lifecycle }
	app.websocket.state.room_members['room'] = {
		'target': true
	}
	app.websocket.state.pending['target'] = [ws.HubPendingMessage{ data: 'original' }]
	return app, lifecycle
}

fn broadcast_close_replace(mut app App, replacement &ws.DispatchConnState) {
	app.websocket.state.mu.@lock()
	defer { app.websocket.state.mu.unlock() }
	app.websocket.state.conns['target'] = ws.HubConn{ id: 'target', lifecycle: replacement }
	app.websocket.state.pending['target'] = [ws.HubPendingMessage{ data: 'replacement' }]
}

fn test_broadcast_late_close_response_cannot_close_replacement() {
	mut app, old := broadcast_close_owner_app()
	mut replacement := &ws.DispatchConnState{ phase: .open }
	base := app.build_websocket_runtime_context()
	rt := ws.RuntimeContext{
		...base
		dispatch_event_fn: fn [mut app, replacement] (_ transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			broadcast_close_replace(mut app, replacement)
			return transport.WorkerWebSocketDispatchResponse{ commands: [transport.WorkerWebSocketFrame{ event: 'close', code: 1008, reason: 'old-response' }] }
		}
	}
	assert ws.hub_broadcast_dispatch(rt, 'room', 'payload', '') == 0
	assert replacement.phase() == .open
	assert !replacement.socket_close_requested
	assert app.websocket.state.pending['target'][0].data == 'replacement'
	assert old.phase() == .open
}

fn broadcast_close_failure() transport.WorkerWebSocketDispatchCommandsResult {
	return transport.WorkerWebSocketDispatchCommandsResult{ failures: [transport.WorkerWebSocketDispatchCommandFailure{ error: 'send_failed' }] }
}

fn test_broadcast_followup_close_cannot_close_replacement_created_during_followup() {
	mut app, _ := broadcast_close_owner_app()
	mut replacement := &ws.DispatchConnState{ phase: .open }
	base := app.build_websocket_runtime_context()
	rt := ws.RuntimeContext{
		...base
		dispatch_event_fn:   fn (_ transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return transport.WorkerWebSocketDispatchResponse{}
		}
		command_result_fn:   fn (_ []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
			return broadcast_close_failure()
		}
		followup_failure_fn: fn [mut app, replacement] (_ string, _ string, _ string, _ map[string]string, _ map[string]string, _ string, _ string, _ string, _ []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
			broadcast_close_replace(mut app, replacement)
			return transport.WorkerWebSocketFrame{ event: 'close', code: 1008, reason: 'old-followup' }
		}
	}
	assert ws.hub_broadcast_dispatch(rt, 'room', 'payload', '') == 1
	assert replacement.phase() == .open
	assert !replacement.socket_close_requested
	assert app.websocket.state.pending['target'][0].data == 'replacement'
}

fn test_broadcast_current_close_response_preserves_default_code_and_reason() {
	mut app, lifecycle := broadcast_close_owner_app()
	base := app.build_websocket_runtime_context()
	rt := ws.RuntimeContext{
		...base
		dispatch_event_fn: fn (_ transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return transport.WorkerWebSocketDispatchResponse{ commands: [transport.WorkerWebSocketFrame{ event: 'close', reason: 'done' }] }
		}
	}
	assert ws.hub_broadcast_dispatch(rt, 'room', 'payload', '') == 0
	assert lifecycle.phase() == .closing
	code, reason := lifecycle.close_details(0, '')
	assert code == 1000
	assert reason == 'done'
	assert 'target' !in app.websocket.state.pending
}

fn test_broadcast_current_followup_close_preserves_code_and_reason() {
	mut app, lifecycle := broadcast_close_owner_app()
	base := app.build_websocket_runtime_context()
	rt := ws.RuntimeContext{
		...base
		dispatch_event_fn:   fn (_ transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return transport.WorkerWebSocketDispatchResponse{}
		}
		command_result_fn:   fn (_ []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
			return broadcast_close_failure()
		}
		followup_failure_fn: fn (_ string, _ string, _ string, _ map[string]string, _ map[string]string, _ string, _ string, _ string, _ []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
			return transport.WorkerWebSocketFrame{ event: 'close', code: 1008, reason: 'failed' }
		}
	}
	assert ws.hub_broadcast_dispatch(rt, 'room', 'payload', '') == 1
	assert lifecycle.phase() == .closing
	code, reason := lifecycle.close_details(0, '')
	assert code == 1008
	assert reason == 'failed'
	assert 'target' !in app.websocket.state.pending
}

fn test_owned_close_without_registered_connection_cannot_remove_pending_messages() {
	mut app := &App{}
	old := &ws.DispatchConnState{ phase: .closed }
	app.websocket.state.pending['target'] = [ws.HubPendingMessage{ data: 'future-open' }]
	rt := app.build_websocket_runtime_context()
	rt.close_owned_target('target', old, 1008, 'late')
	assert app.websocket.state.pending['target'].len == 1
	assert app.websocket.state.pending['target'][0].data == 'future-open'
}

fn test_explicit_key_close_still_discards_pending_messages_without_connection() {
	mut app := &App{}
	app.websocket.state.pending['target'] = [ws.HubPendingMessage{ data: 'cancel' }]
	rt := app.build_websocket_runtime_context()
	rt.close_target('target', 1000, 'explicit-cancel')
	assert 'target' !in app.websocket.state.pending
}
