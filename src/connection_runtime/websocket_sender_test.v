module connection_runtime

import net
import net.websocket
import os
import time

fn sender_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn sender_wait(ch chan bool) {
	select {
		_ := <-ch {
		}
		3 * time.second {
			panic('sender lifecycle timed out')
		}
	}
}

fn sender_not_done(ch chan bool) {
	select {
		_ := <-ch {
			panic('close/idle skipped an active send')
		}
		20 * time.millisecond {
		}
	}
}

fn exercise_sender_close(mut client websocket.Client, fail bool) {
	mut sender := WebSocketSender.new(&client)
	assert voidptr(&sender.template.client_state) != voidptr(&client.client_state)
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	sent := chan bool{cap: 1}
	spawn fn [mut sender, entered, release, sent, fail] () {
		sender.with_lease(fn [entered, release, fail] (mut writer websocket.Client) ! {
			entered <- true
			_ := <-release
			if fail { return error('injected send failure') }
			writer.write_string('leased')!
		}) or { assert err.msg() == 'injected send failure' }
		sent <- true
	}()
	sender_wait(entered)
	closing := chan bool{cap: 1}
	closed := chan bool{cap: 1}
	spawn fn [mut client, closing, closed] () {
		closing <- true
		client.close(1000, 'end') or { panic(err) }
		closed <- true
	}()
	sender_wait(closing)
	sender_not_done(closed)
	sender.retire()
	if _ := sender.write_string('late') {
		assert false
	} else {
		assert err.msg() == 'websocket_sender_retired'
	}
	idle := chan bool{cap: 1}
	spawn fn [mut sender, idle] () {
		sender.wait_idle()
		idle <- true
	}()
	sender_not_done(idle)
	release <- true
	sender_wait(sent)
	sender_wait(closed)
	sender_wait(idle)
	assert client.get_state() == .closed
}

fn test_native_close_joins_send_lease_and_send_error_releases_it() {
	for fail in [false, true] {
		mut client, mut peer := sender_pair()
		defer { peer.close() or {} }
		exercise_sender_close(mut client, fail)
	}
}

fn test_sender_retirement_is_terminal_and_release_is_idempotent() {
	mut client, mut peer := sender_pair()
	defer {
		peer.close() or {}
		client.close(1000, '') or {}
	}
	mut sender := WebSocketSender.new(client)
	sender.retire()
	sender.retire()
	sender.wait_idle()
	if _ := sender.write_string('late') {
		assert false
	} else {
		assert err.msg() == 'websocket_sender_retired'
	}
	assert client.get_state() == .open
}

fn sender_process(command string, args []string) &os.Process {
	mut proc := os.new_process(command)
	proc.set_args(args)
	proc.run()
	return proc
}

fn test_tls_native_close_joins_send_lease_before_releasing_tls_state() {
	root := os.join_path(os.temp_dir(), 'vhttpd-sender-tls-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut cert := sender_process('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout',
		root + '/key.pem', '-out', root + '/cert.pem', '-subj', '/CN=localhost', '-days', '1'])
	cert.wait()
	assert cert.code == 0
	cert.close()
	mut peer := sender_process('python3', [
		@VMODROOT + '/tests/fixtures/bridge_wss_peer.py',
		root,
	])
	defer {
		if peer.is_alive() { peer.signal_kill() }
		peer.wait()
		peer.close()
	}
	deadline := time.now().add(5 * time.second)
	for !os.exists(root + '/port') {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	port := os.read_file(root + '/port') or { panic(err) }
	mut client := websocket.new_client('wss://127.0.0.1:${port}') or { panic(err) }
	client.connect() or { panic(err) }
	fd := client.conn.sock.handle
	exercise_sender_close(mut client, false)
	assert C.fcntl(i32(fd), C.F_GETFD, 0) < 0
	close_client(mut client)
	close_client(mut client)
	deadline_frames := time.now().add(3 * time.second)
	for !os.exists(root + '/frames.json') {
		assert time.now() < deadline_frames
		time.sleep(time.millisecond)
	}
	assert (os.read_file(root + '/frames.json') or { panic(err) }) == '["leased"]'
}

fn test_sender_rejects_closed_and_reconnected_native_client_generations() {
	mut client, mut peer := sender_pair()
	defer { peer.close() or {} }
	mut sender := WebSocketSender.new(client)
	client.close(1000, 'old') or { panic(err) }
	if _ := sender.write_string('late') {
		assert false
	} else {
		assert err.msg() == 'websocket_sender_closed'
	}
	mut replacement, mut next_peer := sender_pair()
	defer {
		next_peer.close() or {}
		replacement.close(1000, 'new') or {}
	}
	client.conn = replacement.conn
	client.set_state(.open)
	if _ := sender.write_string('wrong generation') {
		assert false
	} else {
		assert err.msg() == 'websocket_sender_generation_changed'
	}
	sender.retire()
	sender.wait_idle()
	assert replacement.get_state() == .open
}

fn test_session_stop_interrupts_blocked_send_before_native_close_joins() {
	mut client, mut peer := sender_pair()
	defer { peer.close() or {} }
	peer.sock.set_option_int(.receive_buf_size, 1024) or { panic(err) }
	client.conn.sock.set_option_int(.send_buf_size, 1024) or { panic(err) }
	client.conn.set_write_timeout(time.infinite)
	mut session := Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut sender := WebSocketSender.new(client)
	entered := chan bool{cap: 1}
	sent := chan bool{cap: 1}
	spawn fn [mut sender, entered, sent] () {
		sender.with_lease(fn [entered] (mut writer websocket.Client) ! {
			entered <- true
			writer.write_string('x'.repeat(1024 * 1024))!
		}) or {}
		sent <- true
	}()
	sender_wait(entered)
	sender_not_done(sent)
	closed := chan bool{cap: 1}
	spawn fn [mut client, closed] () {
		client.close(1000, 'cancel') or {}
		closed <- true
	}()
	sender_not_done(closed)
	session.request_stop()
	sender_wait(sent)
	sender_wait(closed)
	sender.retire()
	sender.wait_idle()
	assert client.get_state() == .closed
}

fn C.dup2(int, int) int

fn test_late_sender_cannot_write_or_release_a_recycled_native_descriptor() {
	mut client, mut peer := sender_pair()
	defer { peer.close() or {} }
	fd := client.conn.sock.handle
	mut sender := WebSocketSender.new(client)
	client.close(1000, 'done') or { panic(err) }
	mut next, mut next_peer := sender_pair()
	defer {
		next_peer.close() or {}
		next.close(1000, '') or {}
	}
	owns_alias := fd != next.conn.sock.handle && fd != next_peer.sock.handle
	if owns_alias {
		assert C.dup2(next.conn.sock.handle, fd) == fd
	}
	defer { if owns_alias { C.close(fd) } }
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
	if _ := sender.write_string('late') {
		assert false
	} else {
		assert err.msg() == 'websocket_sender_closed'
	}
	sender.retire()
	sender.retire()
	sender.wait_idle()
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
	assert next.get_state() == .open
}
