module ws

import connection_runtime
import net.websocket
import net
import time

fn publication_socket_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return listener.accept() or { panic(err) }, peer
}

fn publication_client(conn_id string, mut hub HubState, lifecycle &DispatchConnState) (&websocket.Client, &connection_runtime.Session) {
	mut native, mut peer := publication_socket_pair()
	// The peer can close now: the test exercises publication, not socket I/O.
	peer.close() or {}
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = native
	client.set_state(.open)
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	hub.register_conn(conn_id, '', '', '', '', '', {}, {}, '', client, lifecycle)
	return client, session
}

fn test_hub_rejects_session_from_another_native_client() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut other_life := &DispatchConnState{}
	mut client, mut own := publication_client('target', mut hub, life)
	mut other, mut foreign := publication_client('other', mut hub, other_life)
	defer {
		own.release()
		foreign.release()
		client.conn.close() or {}
		other.conn.close() or {}
	}
	assert !hub.bind_outbound('target', life, foreign)
	assert (hub.conns['target'] or { panic('missing') }).outbound == none
	assert !foreign.stopped()
	assert hub.bind_outbound('target', life, own)
}

fn test_hub_rejects_session_after_native_connection_replacement() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut session := publication_client('target', mut hub, life)
	mut original := client.conn
	mut replacement, mut peer := publication_socket_pair()
	defer {
		session.release()
		original.close() or {}
		replacement.close() or {}
		peer.close() or {}
	}
	client.conn = replacement
	assert !hub.bind_outbound('target', life, session)
	assert (hub.conns['target'] or { panic('missing') }).outbound == none
	client.conn = original
	assert hub.bind_outbound('target', life, session)
}

fn test_hub_rejects_stopped_session_before_publication() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut session := publication_client('target', mut hub, life)
	defer {
		session.release()
		client.conn.close() or {}
	}
	session.request_stop()
	assert !hub.bind_outbound('target', life, session)
	assert (hub.conns['target'] or { panic('missing') }).outbound == none
}

fn test_hub_rejects_released_session_before_publication() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut session := publication_client('target', mut hub, life)
	defer { client.conn.close() or {} }
	session.release()
	assert !hub.bind_outbound('target', life, session)
	assert (hub.conns['target'] or { panic('missing') }).outbound == none
}

fn test_hub_rejects_publication_after_lifecycle_closes() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut session := publication_client('target', mut hub, life)
	defer {
		session.release()
		client.conn.close() or {}
	}
	life.mark_closing()
	assert !hub.bind_outbound('target', life, session)
	assert (hub.conns['target'] or { panic('missing') }).outbound == none
	assert !session.stopped()
}

fn test_hub_does_not_overwrite_an_existing_outbound_owner() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut first := publication_client('target', mut hub, life)
	mut second := connection_runtime.Session.connected(client) or { panic(err) }
	defer {
		first.release()
		second.release()
		client.conn.close() or {}
	}
	assert hub.bind_outbound('target', life, first)
	assert !hub.bind_outbound('target', life, second)
	current := (hub.conns['target'] or { panic('missing') }).outbound or { panic('missing session') }
	assert voidptr(current) == voidptr(first)
	assert !first.stopped() && !second.stopped()
}

fn test_one_session_cannot_be_published_to_two_hub_registrations() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut session := publication_client('first', mut hub, life)
	mut second_life := &DispatchConnState{}
	defer {
		session.release()
		client.conn.close() or {}
	}
	hub.register_conn('second', '', '', '', '', '', {}, {}, '', client, second_life)
	assert hub.bind_outbound('first', life, session)
	assert !hub.bind_outbound('second', second_life, session)
	assert (hub.conns['second'] or { panic('missing') }).outbound == none
}

fn test_failed_hub_lookup_does_not_consume_session_publication() {
	mut hub := &HubState{}
	mut life := &DispatchConnState{}
	mut client, mut session := publication_client('target', mut hub, life)
	defer {
		session.release()
		client.conn.close() or {}
	}
	assert !hub.bind_outbound('absent', life, session)
	assert !hub.bind_outbound('target', &DispatchConnState{}, session)
	assert hub.bind_outbound('target', life, session)
	assert (hub.conns['target'] or { panic('missing') }).serving == none
}

fn test_concurrent_hubs_share_one_session_attachment_admission() {
	mut first_hub := &HubState{}
	mut first_life := &DispatchConnState{}
	mut client, mut session := publication_client('first', mut first_hub, first_life)
	mut second_hub := &HubState{}
	mut second_life := &DispatchConnState{}
	defer {
		session.release()
		client.conn.close() or {}
	}
	second_hub.register_conn('second', '', '', '', '', '', {}, {}, '', client, second_life)
	start := chan bool{cap: 2}
	results := chan bool{cap: 2}
	spawn fn [mut first_hub, first_life, session, start, results] () {
		_ := <-start
		results <- first_hub.bind_outbound('first', first_life, session)
	}()
	spawn fn [mut second_hub, second_life, session, start, results] () {
		_ := <-start
		results <- second_hub.bind_outbound('second', second_life, session)
	}()
	start <- true
	start <- true
	first := <-results
	second := <-results
	assert first != second
	mut owners := 0
	if (first_hub.conns['first'] or { panic('missing') }).outbound != none { owners++ }
	if (second_hub.conns['second'] or { panic('missing') }).outbound != none { owners++ }
	assert owners == 1
}
