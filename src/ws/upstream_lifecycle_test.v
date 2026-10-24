module ws

import connection_runtime
import io
import net
import net.http
import net.websocket
import time

@[heap]
struct UpstreamLifecycleFixture {
mut:
	url               string
	prepares          int
	activations       int
	last_reason       string
	pause_prepare     bool
	prepare_error     bool
	activation_error  bool
	retry_delay       int       = 60000
	prepare_entered   chan bool = chan bool{cap: 1}
	prepare_continue  chan bool = chan bool{cap: 1}
	pulls             int
	releases          int
	disconnected      int
	failed            chan bool = chan bool{cap: 1}
	pause_endpoint    bool
	endpoint_entered  chan bool = chan bool{cap: 1}
	endpoint_continue chan bool = chan bool{cap: 1}
	child_started     chan bool = chan bool{cap: 1}
	child_stopped     chan bool = chan bool{cap: 1}
	child_continue    chan bool = chan bool{cap: 1}
}

fn upstream_owned_child(mut session connection_runtime.Session, started chan bool, stopped chan bool, proceed chan bool) {
	started <- true
	for session.wait(time.minute) {
	}
	stopped <- true
	_ := <-proceed
}

fn (mut f UpstreamLifecycleFixture) context() UpstreamRuntimeContext {
	return UpstreamRuntimeContext{
		enabled_fn:         fn (_ string, _ string) bool { return true }
		reconnect_delay_fn: fn [f] (_ string, _ string) int { return f.retry_delay }
		connecting_fn:      fn (_ string, _ string) {}
		pull_url_fn:        fn [mut f] (_ string, _ string) !string {
			f.pulls++
			if f.pause_endpoint {
				f.endpoint_entered <- true
				_ := <-f.endpoint_continue
			}
			return f.url
		}
		prepare_fn:         fn [mut f] (_ string, _ string, _ string) !UpstreamPreparation {
			f.prepares++
			if f.pause_prepare {
				f.prepare_entered <- true
				_ := <-f.prepare_continue
			}
			if f.prepare_error { return error('cold_load_failed') }
			return UpstreamPreparation{
				activate_fn: fn [mut f] (mut _ websocket.Client) ! {
					f.activations++
					if f.activation_error { return error('initial_frame_failed') }
				}
			}
		}
		connected_fn:       fn (_ string, _ string, _ string) {}
		disconnected_fn:    fn [mut f] (_ string, _ string, reason string) {
			f.last_reason = reason
			f.disconnected++
			select {
				f.failed <- true {
				}
				else {
				}
			}
		}
		handle_message_fn:  fn (_ string, _ string, mut _ websocket.Client, _ &websocket.Message) ! {}
		post_connect_fn:    fn [f] (_ string, _ string, _ string, mut session connection_runtime.Session, mut _ websocket.Client) []thread {
			mut workers := []thread{}
			workers << spawn upstream_owned_child(mut session, f.child_started, f.child_stopped, f.child_continue)
			return workers
		}
		release_client_fn:  fn [mut f] (_ string, _ string, _ &websocket.Client) { f.releases++ }
	}
}

fn upstream_signal(ch chan bool) {
	select {
		_ := <-ch {
		}
		3 * time.second {
			panic('upstream fixture timed out')
		}
	}
}

fn upstream_lifecycle_server(mut listener net.TcpListener, done chan bool) {
	mut conn := listener.accept() or {
		done <- false
		return
	}
	defer { conn.close() or {} }
	conn.set_read_timeout(3 * time.second)
	conn.set_write_timeout(time.second)
	mut reader := io.new_buffered_reader(reader: conn)
	req := http.parse_request(mut reader) or {
		done <- false
		return
	}
	key := req.header.get(.sec_websocket_key) or {
		done <- false
		return
	}
	mut server := websocket.new_server(.ip, 0, '')
	server.handle_handshake(mut conn, key) or {}
	done <- true
}

fn test_upstream_stop_before_entry_never_pulls_endpoint() {
	mut f := &UpstreamLifecycleFixture{}
	ctx := f.context()
	mut run := connection_runtime.Run{}
	run.request_stop()
	ctx.run_provider('test', 'one', mut run)
	assert run.finished()
	assert f.pulls == 0
}

fn test_upstream_stop_during_endpoint_lookup_prevents_late_connect() {
	mut f := &UpstreamLifecycleFixture{ pause_endpoint: true, url: 'ws://127.0.0.1:1' }
	ctx := f.context()
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.endpoint_entered)
	run.request_stop()
	assert !run.finished()
	f.endpoint_continue <- true
	worker.wait()
	assert run.finished()
	assert f.pulls == 1
	assert f.disconnected == 0
}

fn test_upstream_retry_sleep_is_cancelled_without_another_attempt() {
	mut f := &UpstreamLifecycleFixture{ pause_endpoint: true, url: 'ws://127.0.0.1:1/' }
	ctx := f.context()
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.endpoint_entered)
	f.endpoint_continue <- true
	upstream_signal(f.failed)
	run.request_stop()
	worker.wait()
	assert f.pulls == 1
	assert run.finished()
}

fn test_upstream_stop_interrupts_reader_and_joins_child_before_release() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut f := &UpstreamLifecycleFixture{ url: 'ws://${addr}/' }
	ctx := f.context()
	done := chan bool{cap: 1}
	spawn upstream_lifecycle_server(mut listener, done)
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.child_started)
	run.request_stop()
	upstream_signal(f.child_stopped)
	assert !run.finished() // Reader has stopped; session tasks still own the run.
	assert f.releases == 0
	f.child_continue <- true
	worker.wait()
	upstream_signal(done)
	assert run.finished()
	assert f.releases == 1
	assert f.disconnected == 1
	assert f.pulls == 1
}

fn upstream_reject_upgrade(mut listener net.TcpListener, done chan bool) {
	mut conn := listener.accept() or {
		done <- false
		return
	}
	defer { conn.close() or {} }
	conn.set_read_timeout(3 * time.second)
	mut reader := io.new_buffered_reader(reader: conn)
	_ := http.parse_request(mut reader) or {
		done <- false
		return
	}
	conn.write('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'.bytes()) or {
		done <- false
		return
	}
	mut buf := []u8{len: 512}
	for {
		n := conn.read(mut buf) or {
			done <- (err is io.Eof)
			return
		}
		if n == 0 {
			done <- true
			return
		}
	}
}

fn test_upstream_failed_upgrade_closes_unpublished_tcp_connection() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut f := &UpstreamLifecycleFixture{ url: 'ws://${addr}/' }
	ctx := f.context()
	done := chan bool{cap: 1}
	spawn upstream_reject_upgrade(mut listener, done)
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.failed)
	run.request_stop()
	worker.wait()
	select {
		eof := <-done {
			assert eof
		}
		3 * time.second {
			panic('failed handshake retained TCP socket')
		}
	}
	assert f.pulls == 1
	assert f.releases == 0
}

fn assert_no_upstream_connection(mut listener net.TcpListener) {
	listener.set_accept_timeout(30 * time.millisecond)
	if mut conn := listener.accept() {
		conn.close() or {}
		panic('connected before preparation completed')
	} else {
		assert err.code() == net.err_timed_out_code
	}
}

fn test_upstream_prepares_before_connecting_and_activates_before_session_tasks() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut f := &UpstreamLifecycleFixture{ url: 'ws://${addr}/', pause_prepare: true }
	ctx := f.context()
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.prepare_entered)
	assert f.prepares == 1
	assert f.activations == 0
	assert_no_upstream_connection(mut listener)
	listener.set_accept_timeout(3 * time.second)
	done := chan bool{cap: 1}
	spawn upstream_lifecycle_server(mut listener, done)
	f.prepare_continue <- true
	upstream_signal(f.child_started)
	assert f.activations == 1
	run.request_stop()
	upstream_signal(f.child_stopped)
	f.child_continue <- true
	worker.wait()
	upstream_signal(done)
	assert f.releases == 1
}

fn test_upstream_cancelled_preparation_never_connects_or_activates() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut f := &UpstreamLifecycleFixture{ url: 'ws://${addr}/', pause_prepare: true }
	ctx := f.context()
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.prepare_entered)
	run.request_stop()
	assert !run.finished()
	f.prepare_continue <- true
	worker.wait()
	assert run.finished()
	assert f.prepares == 1
	assert f.activations == 0
	assert f.releases == 0
	assert_no_upstream_connection(mut listener)
}

fn test_upstream_failed_preparation_never_opens_transport() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut f := &UpstreamLifecycleFixture{ url: 'ws://${addr}/', prepare_error: true }
	ctx := f.context()
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.failed)
	run.request_stop()
	worker.wait()
	assert f.last_reason == 'prepare:cold_load_failed'
	assert f.activations == 0
	assert f.releases == 0
	assert_no_upstream_connection(mut listener)
}

fn test_upstream_activation_failure_closes_session_without_starting_heartbeat() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut f := &UpstreamLifecycleFixture{ url: 'ws://${addr}/', activation_error: true }
	ctx := f.context()
	done := chan bool{cap: 1}
	spawn upstream_lifecycle_server(mut listener, done)
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.failed)
	run.request_stop()
	worker.wait()
	upstream_signal(done)
	assert f.activations == 1
	assert f.releases == 1
	assert f.last_reason == 'handshake:initial_frame_failed'
	select {
		_ := <-f.child_started {
			panic('heartbeat started after failed initial frame')
		}
		else {
		}
	}
}

fn test_upstream_reconnect_rebuilds_preparation_for_each_attempt() {
	mut f := &UpstreamLifecycleFixture{ url: 'ws://127.0.0.1:1/', retry_delay: 1 }
	ctx := f.context()
	mut run := &connection_runtime.Run{}
	worker := spawn ctx.run_provider('test', 'one', mut run)
	upstream_signal(f.failed)
	upstream_signal(f.failed)
	run.request_stop()
	worker.wait()
	assert f.prepares >= 2
	assert f.prepares <= f.pulls
	assert f.activations == 0
}

fn upstream_stop_during_wire_handshake(tls bool) {
 mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
 defer { listener.close() or {} }
 listener.set_accept_timeout(time.second)
 address := listener.addr() or { panic(err) }
 scheme := if tls { 'wss' } else { 'ws' }
 mut fixture := &UpstreamLifecycleFixture{url: '${scheme}://${address}/stalled'}
 mut run := &connection_runtime.Run{}
 finished := chan bool{cap:1}
 ctx := fixture.context()
 spawn fn [ctx, mut run, finished] () {
  ctx.run_provider('fixture', 'main', mut run)
  finished <- true
 }()
 mut peer := listener.accept() or { run.request_stop(); panic(err) }
 peer.set_read_timeout(time.second)
 mut first := []u8{len:1024}
 count := peer.read(mut first) or { panic(err) }
 assert count > 0
 if tls { assert first[0] == 0x16 } else { assert first[..count].bytestr().starts_with('GET ') }
 // The peer has received the request/ClientHello but never answers it.
 run.request_stop()
 mut stopped := false
 select {
  _ := <-finished { stopped = true }
  500 * time.millisecond {}
 }
 // Always release the test peer, including on the old implementation, before
 // asserting so a regression cannot leave a 60-second client thread behind.
 peer.close() or {}
 if !stopped {
  select { _ := <-finished {} 3 * time.second { panic('connect did not join after peer cleanup') } }
 }
 assert stopped, 'stop waited for a stalled wire handshake'
 assert fixture.activations == 0
 assert fixture.releases == 0
 assert run.finished()
}

fn test_upstream_stop_interrupts_stalled_http_upgrade() {
 upstream_stop_during_wire_handshake(false)
}

fn test_upstream_stop_interrupts_stalled_tls_handshake() {
 upstream_stop_during_wire_handshake(true)
}
