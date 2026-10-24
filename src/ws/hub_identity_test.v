module ws

import connection_runtime
import net
import net.websocket
import time

fn identity_hub(mut old DispatchConnState, mut replacement DispatchConnState) &HubState {
	mut hub := &HubState{}
	hub.conns['same'] = HubConn{ id: 'same', lifecycle: &old }
	hub.conns['same'] = HubConn{ id: 'same', lifecycle: &replacement }
	hub.conn_rooms['same'] = {
		'new-room': true
	}
	hub.room_members['new-room'] = {
		'same': true
	}
	hub.conn_meta['same'] = {
		'owner': 'new'
	}
	hub.pending['same'] = [HubPendingMessage{ data: 'new' }]
	return hub
}

fn test_stale_cleanup_cannot_remove_replacement_connection_rooms_metadata_or_pending() {
	mut old := &DispatchConnState{ phase: .open }
	mut replacement := &DispatchConnState{ phase: .open }
	mut hub := identity_hub(mut old, mut replacement)
	hub.unregister_owned('same', old)
	assert old.phase() == .closed
	assert replacement.phase() == .open
	assert voidptr((hub.conns['same'] or { panic('replacement') }).lifecycle) == voidptr(replacement)
	assert hub.conn_rooms['same']['new-room']
	assert hub.room_members['new-room']['same']
	assert hub.conn_meta['same']['owner'] == 'new'
	assert hub.pending['same'][0].data == 'new'
	hub.cleanup_owned('same', old)
	assert hub.conns.len == 1
}

fn test_owned_cleanup_removes_its_entire_registration_once() {
	mut old := &DispatchConnState{ phase: .open }
	mut current := &DispatchConnState{ phase: .open }
	mut hub := identity_hub(mut old, mut current)
	hub.unregister_owned('same', current)
	hub.unregister_owned('same', current)
	assert current.phase() == .closed
	assert hub.conns.len == 0
	assert hub.room_members.len == 0
	assert hub.conn_rooms.len == 0
	assert hub.conn_meta.len == 0
	assert hub.pending.len == 0
}

fn test_stale_mark_and_owned_close_leave_replacement_open_and_pending() {
	mut old := &DispatchConnState{ phase: .open }
	mut current := &DispatchConnState{ phase: .open }
	mut hub := identity_hub(mut old, mut current)
	assert !hub.mark_owned_closing('same', old)
	hub_close_owned_target(mut hub, 'same', old, 1008, 'old')
	assert current.phase() == .open
	assert hub.pending['same'][0].data == 'new'
	assert hub.ingress.active() == 0
	assert hub.mark_owned_closing('same', current)
	assert current.phase() == .closing
	assert hub.pending.len == 0
}

fn identity_socket_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return listener.accept() or { panic(err) }, peer
}

fn identity_read(mut peer net.TcpConn, count int) []u8 {
	mut bytes := []u8{len: count}
	mut offset := 0
	for offset < count {
		mut part := []u8{len: count - offset}
		n := peer.read(mut part) or { panic(err) }
		assert n > 0
		copy(mut bytes[offset..], part[..n])
		offset += n
	}
	return bytes
}

fn test_outbound_close_uses_retained_session_and_client_masking() {
	mut original, mut peer := identity_socket_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = original
	client.set_state(.open)
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut hub := &HubState{}
	mut lifecycle := &DispatchConnState{ phase: .open }
	hub.register_conn('agent', '', '', '', '', '', {}, {}, '', client, lifecycle)
	assert (hub.conns['agent'] or { panic('agent') }).serving == none
	assert hub.bind_outbound('agent', lifecycle, session)
	assert !hub.bind_outbound('agent', &DispatchConnState{}, session)
	hub_close_target(mut hub, 'agent', 1008, 'policy')
	hub.ingress.wait()
	header := identity_read(mut peer, 2)
	assert header == [u8(0x88), 0x88]
	mask := identity_read(mut peer, 4)
	mut payload := identity_read(mut peer, 8)
	for i in 0 .. payload.len { payload[i] ^= mask[i % 4] }
	assert payload == [u8(3), 240, 112, 111, 108, 105, 99, 121]
	assert lifecycle.phase() == .closing
	assert hub.ingress.active() == 0
}

fn test_released_outbound_session_close_does_not_leave_a_task() {
	mut original, mut peer := identity_socket_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = original
	client.set_state(.open)
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	mut hub := &HubState{}
	mut lifecycle := &DispatchConnState{ phase: .open }
	hub.register_conn('agent', '', '', '', '', '', {}, {}, '', client, lifecycle)
	assert hub.bind_outbound('agent', lifecycle, session)
	session.release()
	hub_close_target(mut hub, 'agent', 1000, 'late')
	hub.ingress.wait()
	assert hub.ingress.active() == 0
	original.write_string('original still owned by loop') or { panic(err) }
	assert identity_read(mut peer, 'original still owned by loop'.len).bytestr() == 'original still owned by loop'
}

fn test_tls_close_uses_transport_cancellation_without_plaintext_frame() {
	mut original, mut peer := identity_socket_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	mut client := websocket.new_client('wss://localhost:1') or { panic(err) }
	client.conn = original
	client.set_state(.open)
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut hub := &HubState{}
	mut lifecycle := &DispatchConnState{ phase: .open }
	hub.register_conn('tls-agent', '', '', '', '', '', {}, {}, '', client, lifecycle)
	assert hub.bind_outbound('tls-agent', lifecycle, session)
	hub_close_target(mut hub, 'tls-agent', 1000, 'stop')
	hub.ingress.wait()
	mut bytes := []u8{len: 64}
	assert (peer.read(mut bytes) or { 0 }) == 0
	assert hub.ingress.active() == 0
}

fn test_close_writer_observes_native_clients_shared_terminal_state() {
	mut original, mut peer := identity_socket_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = original
	client.set_state(.open)
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut hub := &HubState{}
	mut lifecycle := &DispatchConnState{ phase: .open }
	hub.register_conn('agent', '', '', '', '', '', {}, {}, '', client, lifecycle)
	assert hub.bind_outbound('agent', lifecycle, session)
	client.set_state(.closed)
	hub_close_target(mut hub, 'agent', 1000, 'late')
	hub.ingress.wait()
	mut bytes := []u8{len: 64}
	assert (peer.read(mut bytes) or { 0 }) == 0
	assert hub.ingress.active() == 0
}

fn test_registration_retains_explicit_serving_scope_instead_of_guessing_by_fd() {
	mut original, mut peer := identity_socket_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = original
	mut hub := &HubState{}
	mut old := hub.ingress.reserve() or { panic('old') }
	mut current := hub.ingress.reserve() or { panic('current') }
	assert old.attach(original.sock.handle)
	assert current.attach(original.sock.handle)
	mut lifecycle := &DispatchConnState{ phase: .open }
	hub.register_conn('plain', '', '', '', '', '', {}, {}, '', client, lifecycle)
	assert (hub.conns['plain'] or { panic('plain') }).serving == none
	hub.register_owned_conn('owned', '', '', '', '', '', {}, {}, '', client, lifecycle, current)
	bound := (hub.conns['owned'] or { panic('owned') }).serving or { panic('scope') }
	assert voidptr(bound) == voidptr(current)
	current.request_stop()
	assert current.child() == none
	old.finish()
	current.finish()
	hub.ingress.request_stop()
	hub.ingress.wait()
}
