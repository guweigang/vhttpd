module connection_runtime

import net
import net.websocket
import time
import os

#include <unistd.h>

fn C.dup(int) int

// The executed child checks inherited descriptors before running any test.
// The intentionally inheritable control proves exec did not close every fd.
fn testsuite_begin() {
	if os.args.len == 4 && os.args[1] == '--vhttpd-interrupt-fd-probe' {
		owned := os.args[2].int()
		control := os.args[3].int()
		if C.fcntl(control, C.F_GETFD, 0) < 0 { exit(43) }
		if C.fcntl(owned, C.F_GETFD, 0) >= 0 { exit(42) }
		exit(0)
	}
}

fn test_registry_shutdown_notifies_all_before_waiting_and_closes_admission() {
	mut registry := Registry{}
	mut first := registry.reserve('feishu/a') or { panic('missing first') }
	mut second := registry.reserve('codex/b') or { panic('missing second') }
	assert registry.reserve('feishu/a') == none
	mut runs := registry.request_shutdown()
	assert runs.len == 2
	assert first.stopped() && second.stopped()
	assert !first.finished() && !second.finished()
	assert registry.reserve('new') == none
	registry.release('feishu/a', mut first)
	registry.release('codex/b', mut second)
	for mut run in runs { run.wait_finished() }
	assert registry.reserve('feishu/a') == none
}

fn test_stale_registry_release_preserves_restarted_run() {
	mut registry := Registry{}
	mut old := registry.reserve('bridge') or { panic('no run') }
	registry.release('bridge', mut old)
	mut next := registry.reserve('bridge') or { panic('no restart') }
	registry.release('bridge', mut old)
	assert registry.reserve('bridge') == none
	assert !next.stopped()
	registry.release('bridge', mut next)
}

fn stop_fixture(mut registry Registry, done chan bool) {
	registry.stop_prefix('feishu/')
	done <- true
}

fn test_prefix_stop_holds_admission_until_owned_run_finishes() {
	mut registry := &Registry{}
	mut first := registry.reserve('feishu/a') or { panic('no run') }
	done := chan bool{cap: 1}
	spawn stop_fixture(mut registry, done)
	deadline := time.now().add(time.second)
	for !first.stopped() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	assert registry.reserve('feishu/new') == none
	mut other := registry.reserve('codex/a') or { panic('unrelated provider blocked') }
	registry.release('feishu/a', mut first)
	select {
		_ := <-done {
		}
		time.second {
			panic('prefix stop did not finish')
		}
	}
	mut restarted := registry.reserve('feishu/a') or { panic('restart blocked') }
	registry.release('feishu/a', mut restarted)
	registry.release('codex/a', mut other)
}

fn wait_session_fixture(mut session Session, done chan bool) {
	done <- session.wait(20 * time.second)
}

fn test_session_stop_broadcast_interrupts_all_heartbeat_waiters() {
	mut session := &Session{}
	done := chan bool{cap: 5}
	for _ in 0 .. 5 { spawn wait_session_fixture(mut session, done) }
	session.request_stop()
	for _ in 0 .. 5 {
		select {
			completed := <-done {
				assert !completed
			}
			time.second {
				panic('heartbeat sleep not interrupted')
			}
		}
	}
	session.release()
	session.release()
}

fn test_stale_session_detach_cannot_hide_new_connection_from_stop() {
	mut run := Run{}
	mut first := &Session{}
	mut second := &Session{}
	assert run.attach(mut first)
	run.detach(first)
	assert run.attach(mut second)
	run.detach(first)
	run.request_stop()
	assert second.stopped()
	assert !run.wait(time.second)
	run.detach(second)
	run.finish()
	assert run.finished()
}

fn test_session_interrupt_uses_owned_descriptor_after_original_connection_closes() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	defer { peer.close() or {} }
	mut original := listener.accept() or { panic(err) }
	client := &websocket.Client{ conn: original }
	mut session := Session.connected(client) or { panic(err) }
	original.close() or { panic(err) }
	mut next_peer := net.dial_tcp(addr.str()) or { panic(err) }
	defer { next_peer.close() or {} }
	mut replacement := listener.accept() or { panic(err) }
	defer { replacement.close() or {} }
	replacement.set_read_timeout(time.second)
	session.request_stop()
	session.release()
	session.request_stop()
	session.release()
	next_peer.write('still alive'.bytes()) or { panic(err) }
	mut bytes := []u8{len: 32}
	n := replacement.read(mut bytes) or { panic(err) }
	assert bytes[..n].bytestr() == 'still alive'
}

fn test_provider_pause_requires_explicit_resume_and_shutdown_cannot_resume() {
	mut registry := Registry{}
	registry.pause_prefix('feishu/')
	assert registry.reserve('feishu/new') == none
	mut other := registry.reserve('codex/main') or { panic('other provider blocked') }
	registry.release('codex/main', mut other)
	assert registry.resume_prefix('feishu/')
	mut next := registry.reserve('feishu/new') or { panic('resume failed') }
	registry.release('feishu/new', mut next)
	registry.request_shutdown()
	assert !registry.resume_prefix('feishu/')
	assert registry.reserve('feishu/new') == none
}

fn test_provider_stop_can_notify_both_registries_before_waiting() {
	mut upstreams := Registry{}
	mut bridge := Registry{}
	mut upstream := upstreams.reserve('feishu/main') or { panic('no upstream') }
	mut client := bridge.reserve('client') or { panic('no bridge') }
	mut upstream_runs := upstreams.request_pause('feishu/')
	mut bridge_runs := bridge.request_pause('')
	assert upstream.stopped() && client.stopped()
	assert !upstream.finished() && !client.finished()
	assert !upstreams.resume_prefix('feishu/')
	assert !bridge.resume_prefix('')
	upstreams.release('feishu/main', mut upstream)
	bridge.release('client', mut client)
	upstream_runs.wait()
	bridge_runs.wait()
	assert upstreams.reserve('feishu/main') == none
	assert bridge.reserve('client') == none
	assert upstreams.resume_prefix('feishu/')
	assert bridge.resume_prefix('')
}

fn test_session_interrupt_is_closed_on_exec_without_closing_inheritable_control() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	defer { peer.close() or {} }
	mut original := listener.accept() or { panic(err) }
	defer { original.close() or {} }
	client := &websocket.Client{ conn: original }
	mut session := Session.connected(client) or { panic(err) }
	defer { session.release() }
	fd := session.interrupt or { panic('missing interrupt descriptor') }
	control := C.dup(original.sock.handle)
	assert control >= 0
	defer { net.close(control) or {} }
	assert C.fcntl(control, C.F_GETFD, 0) & C.FD_CLOEXEC == 0
	mut proc := os.new_process(os.executable())
	defer { proc.close() }
	proc.set_args(['--vhttpd-interrupt-fd-probe', fd.str(), control.str()])
	proc.run()
	proc.wait()
	assert proc.code == 0
	assert C.fcntl(fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
}

fn test_unconnected_client_has_explicit_session_error() {
	client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	assert isnil(client.conn)
	if mut unexpected := Session.connected(client) {
		unexpected.release()
		panic('unconnected client acquired a session')
	} else {
		assert err.msg() == 'websocket_connection_unavailable'
	}
}

fn test_invalid_socket_dup_failure_preserves_other_connection() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	defer { peer.close() or {} }
	mut original := listener.accept() or { panic(err) }
	defer { original.close() or {} }
	original.set_read_timeout(time.second)
	invalid := &websocket.Client{
		conn: &net.TcpConn{
			sock: net.TcpSocket{ Socket: net.Socket{ handle: -1 } }
		}
	}
	if mut unexpected := Session.connected(invalid) {
		unexpected.release()
		panic('invalid socket acquired a session')
	} else {
		assert err.msg() == 'websocket_interrupt_dup_failed'
	}
	peer.write_string('unaffected') or { panic(err) }
	mut bytes := []u8{len: 32}
	n := original.read(mut bytes) or { panic(err) }
	assert bytes[..n].bytestr() == 'unaffected'
}

fn test_session_release_closes_only_interrupt_and_preserves_borrowed_socket() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	defer { peer.close() or {} }
	mut original := listener.accept() or { panic(err) }
	defer { original.close() or {} }
	original.set_read_timeout(time.second)
	mut session := Session.connected(&websocket.Client{ conn: original }) or { panic(err) }
	fd := session.interrupt or { panic('missing interrupt descriptor') }
	session.release()
	session.release()
	assert session.interrupt == none
	assert C.fcntl(fd, C.F_GETFD, 0) == -1
	peer.write_string('still owned by caller') or { panic(err) }
	mut bytes := []u8{len: 32}
	n := original.read(mut bytes) or { panic(err) }
	assert bytes[..n].bytestr() == 'still owned by caller'
}
