module ws

import net
import net.websocket
import time

fn ingress_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	peer := net.dial_tcp(addr.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	return server, peer
}

fn test_ingress_stop_before_spawn_waits_for_reserved_scope_and_rejects_late_work() {
	mut owner := &IngressOwner{}
	mut run := owner.reserve() or { panic('reserve') }
	owner.request_stop()
	assert run.stopped()
	assert owner.reserve() == none
	done := chan bool{cap: 1}
	spawn fn [mut owner, done] () {
		owner.wait()
		done <- true
	}()
	select {
		_ := <-done {
			panic('unstarted run escaped join')
		}
		20 * time.millisecond {
		}
	}
	run.finish()
	select {
		_ := <-done {
		}
		time.second {
			panic('join')
		}
	}
	run.finish()
	owner.request_stop()
	owner.wait()
	assert owner.active() == 0
}

fn test_ingress_retains_cloexec_interrupt_and_stops_all_attached_sockets() {
	mut owner := &IngressOwner{}
	mut run := owner.reserve() or { panic('reserve') }
	mut a, mut peer_a := ingress_pair()
	mut b, mut peer_b := ingress_pair()
	defer {
		a.close() or {}
		b.close() or {}
		peer_a.close() or {}
		peer_b.close() or {}
	}
	assert run.attach(a.sock.handle)
	assert run.attach(b.sock.handle)
	handles := run.handles.clone()
	for fd in handles {
		assert C.fcntl(fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
	}
	owner.request_stop()
	assert !run.attach(a.sock.handle)
	mut bytes := []u8{len: 1}
	mut peers := [peer_a, peer_b]
	for mut peer in peers {
		peer.set_read_timeout(time.second)
		n := peer.read(mut bytes) or { 0 }
		assert n == 0
	}
	run.finish()
	for fd in handles {
		assert C.fcntl(fd, C.F_GETFD, 0) == -1
	}
}

fn test_ingress_late_stop_cannot_touch_recycled_original_descriptor() {
	mut owner := &IngressOwner{}
	mut run := owner.reserve() or { panic('reserve') }
	mut original, mut first_peer := ingress_pair()
	defer { first_peer.close() or {} }
	assert run.attach(original.sock.handle)
	original.close() or { panic(err) }
	mut replacement, mut second_peer := ingress_pair()
	defer {
		replacement.close() or {}
		second_peer.close() or {}
	}
	owner.request_stop()
	replacement.write_string('safe') or { panic(err) }
	mut bytes := []u8{len: 4}
	assert second_peer.read(mut bytes) or { panic(err) } == 4
	assert bytes.bytestr() == 'safe'
	run.finish()
}

fn test_ingress_failed_attachment_releases_reservation_explicitly() {
	mut owner := &IngressOwner{}
	mut run := owner.reserve() or { panic('reserve') }
	assert !run.attach(-1)
	run.finish()
	owner.request_stop()
	owner.wait()
	assert owner.active() == 0
}

fn test_async_close_writes_requested_code_without_closing_original_socket() {
	mut hub := &HubState{}
	mut run := hub.ingress.reserve() or { panic('reserve') }
	mut original, mut peer := ingress_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	assert run.attach(original.sock.handle)
	client := close_test_client(original)
	spawn hub_close_client_owned(mut hub, mut run, client, 1008, 'policy')
	hub.ingress.wait()
	assert C.fcntl(original.sock.handle, C.F_GETFD, 0) >= 0
	peer.set_read_timeout(time.second)
	mut bytes := []u8{len: 64}
	n := peer.read(mut bytes) or { panic(err) }
	assert bytes[0] == 0x88 && bytes[1] == 0x88
	assert n == 14
	mut payload := bytes[6..n].clone()
	for i in 0 .. payload.len { payload[i] ^= bytes[2 + i % 4] }
	assert payload == [u8(3), 240, 112, 111, 108, 105, 99, 121]
	assert hub.ingress.active() == 0
}

fn test_queued_close_task_is_joined_and_cancelled_before_it_can_write() {
	mut hub := &HubState{}
	mut run := hub.ingress.reserve() or { panic('reserve') }
	mut original, mut peer := ingress_pair()
	defer {
		original.close() or {}
		peer.close() or {}
	}
	assert run.attach(original.sock.handle)
	hub.send_mu.@lock()
	client := close_test_client(original)
	spawn hub_close_client_owned(mut hub, mut run, client, 1008, 'late')
	hub.ingress.request_stop()
	assert hub.ingress.active() == 1
	hub.send_mu.unlock()
	hub.ingress.wait()
	peer.set_read_timeout(time.second)
	mut bytes := []u8{len: 64}
	assert (peer.read(mut bytes) or { 0 }) == 0
}

fn test_socket_close_claim_is_once_even_after_logical_closing() {
	mut lifecycle := &DispatchConnState{}
	assert lifecycle.mark_closing()
	assert lifecycle.claim_socket_close(1008, 'policy')
	assert !lifecycle.claim_socket_close(1000, 'duplicate')
	code, reason := lifecycle.close_details(1000, 'native')
	assert code == 1008 && reason == 'policy'
}

fn test_close_task_uses_retained_serving_socket_after_original_is_closed() {
	mut owner := &IngressOwner{}
	mut run := owner.reserve() or { panic('reserve') }
	mut original, mut peer := ingress_pair()
	defer { peer.close() or {} }
	assert run.attach(original.sock.handle)
	client := close_test_client(original)
	original.close() or { panic(err) }
	mut replacement, mut replacement_peer := ingress_pair()
	defer {
		replacement.close() or {}
		replacement_peer.close() or {}
	}
	mut task := run.child() or { panic('child') }
	task.write_client_close(client, 1008, 'owned')
	task.request_stop()
	task.finish()
	run.finish()
	peer.set_read_timeout(time.second)
	mut bytes := []u8{len: 64}
	// TcpConn.close shuts down the old socket before closing its descriptor.
	// A late close task must tolerate EOF and leave replacement sockets intact.
	assert (peer.read(mut bytes) or { 0 }) == 0
	replacement.write_string('safe') or { panic(err) }
	assert replacement_peer.read(mut bytes) or { panic(err) } == 4
	assert bytes[..4].bytestr() == 'safe'
	assert run.child() == none
	owner.request_stop()
	owner.wait()
}

fn close_test_client(conn &net.TcpConn) &websocket.Client {
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = conn
	client.set_state(.open)
	return client
}
