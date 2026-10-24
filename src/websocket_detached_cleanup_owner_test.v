module main

import net
import net.websocket
import time
import upstream.transport
import ws

fn detached_cleanup_pending(mut app App) {
	assert ws.hub_send_to(mut app.websocket.state, 'same', 'future-open', 'text')
}

fn detached_cleanup_retained(app &App) {
	assert app.websocket.state.pending['same'].len == 1
	assert app.websocket.state.pending['same'][0].data == 'future-open'
}

fn test_detached_owned_mark_cannot_cancel_future_open_queue() {
	mut app := &App{}
	detached_cleanup_pending(mut app)
	old := &ws.DispatchConnState{ phase: .closed }
	assert !app.websocket.state.mark_owned_closing('same', old)
	detached_cleanup_retained(app)
}

fn test_detached_owned_cleanup_cannot_cancel_future_open_queue() {
	mut app := &App{}
	detached_cleanup_pending(mut app)
	app.websocket.state.cleanup_owned('same', &ws.DispatchConnState{ phase: .closed })
	detached_cleanup_retained(app)
}

fn test_detached_unregister_finishes_own_lifecycle_without_cancelling_future_queue() {
	mut app := &App{}
	detached_cleanup_pending(mut app)
	mut old := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.unregister_owned('same', old)
	assert old.phase() == .closed
	detached_cleanup_retained(app)
}

@[heap]
struct DetachedCleanupProbe {
mut:
	closes int
}

fn test_detached_dispatch_finalizer_keeps_logical_close_and_future_queue() {
	mut app := &App{}
	mut probe := &DetachedCleanupProbe{}
	base := app.build_websocket_runtime_context()
	rt := ws.RuntimeContext{
		...base
		dispatch_event_fn: fn [mut probe] (frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			assert frame.event == 'close'
			probe.closes++
			return transport.WorkerWebSocketDispatchResponse{}
		}
	}
	old := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: old }
	app.websocket.state.cleanup_owned('same', old)
	detached_cleanup_pending(mut app)
	state := &ws.DispatchBridgeState{ rt: rt, lifecycle: old, conn_id: 'same' }
	ws.dispatch_session_finalize(state)
	ws.dispatch_session_finalize(state)
	assert old.phase() == .closed
	assert probe.closes == 1
	detached_cleanup_retained(app)
}

fn test_detached_relay_cleanup_cannot_cancel_future_open_queue() {
	mut runtime := WebSocketRuntime.new(false)
	rt := runtime.build_relay_session_context()
	assert ws.hub_send_to(mut runtime.state, 'same', 'future-open', 'text')
	old := &ws.DispatchConnState{ phase: .closing }
	assert !rt.mark_closing('same', old)
	rt.cleanup_conn('same', old)
	assert runtime.state.pending['same'].len == 1
}

fn test_registered_owned_cleanup_still_removes_rooms_metadata_and_queue() {
	mut app := &App{}
	old := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: old }
	app.websocket.state.conn_rooms['same'] = {
		'room': true
	}
	app.websocket.state.room_members['room'] = {
		'same': true
	}
	app.websocket.state.conn_meta['same'] = {
		'owner': 'old'
	}
	app.websocket.state.pending['same'] = [ws.HubPendingMessage{ data: 'old' }]
	app.websocket.state.unregister_owned('same', old)
	assert old.phase() == .closed
	assert app.websocket.state.conns.len == 0
	assert app.websocket.state.conn_rooms.len == 0
	assert app.websocket.state.room_members.len == 0
	assert app.websocket.state.conn_meta.len == 0
	assert app.websocket.state.pending.len == 0
}

fn test_explicit_key_cleanup_still_cancels_unregistered_pending_queue() {
	mut app := &App{}
	detached_cleanup_pending(mut app)
	app.websocket.state.cleanup_conn('same')
	assert app.websocket.state.pending.len == 0
}

fn detached_cleanup_read(mut peer net.TcpConn, count int) []u8 {
	mut result := []u8{len: count}
	mut offset := 0
	for offset < count {
		mut buffer := []u8{len: count - offset}
		n := peer.read(mut buffer) or { panic(err) }
		assert n > 0
		copy(mut result[offset..], buffer[..n])
		offset += n
	}
	return result
}

fn test_future_open_queue_survives_stale_cleanup_and_reaches_new_socket() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	mut server := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		server.close() or {}
	}
	peer.set_read_timeout(time.second)
	mut app := &App{}
	detached_cleanup_pending(mut app)
	app.websocket.state.cleanup_owned('same', &ws.DispatchConnState{ phase: .closed })
	mut client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	client.conn = server
	client.set_state(.open)
	current := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.register_conn('same', '', 'GET', 'new', 'trace', '/', {}, {}, '', client, current)
	app.websocket.state.flush_pending('same')
	header := detached_cleanup_read(mut peer, 2)
	assert header[0] == 0x81
	assert header[1] & 0x7f == 'future-open'.len
	mask := if header[1] & 0x80 != 0 { detached_cleanup_read(mut peer, 4) } else { []u8{} }
	mut payload := detached_cleanup_read(mut peer, 'future-open'.len)
	if mask.len > 0 {
		for i in 0 .. payload.len { payload[i] ^= mask[i % 4] }
	}
	assert payload.bytestr() == 'future-open'
	assert app.websocket.state.pending.len == 0
	app.websocket.state.unregister_owned('same', current)
}
