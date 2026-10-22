module main

import executor
import net
import net.unix
import os
import process_runtime
import relay
import server_lifecycle
import time
import upstream.transport
import ws

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int
fn C.kill(int, int) int

fn inbound_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return listener.accept() or { panic(err) }, peer
}

fn inbound_ready(mut peer net.TcpConn) {
	mut bytes := []u8{len: 2048}
	n := peer.read(mut bytes) or { panic(err) }
	assert bytes[..n].bytestr().contains('101 Switching Protocols')
}

fn inbound_join(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('inbound session did not finish')
		}
	}
}

fn inbound_run(mut app App, server &net.TcpConn) &ws.IngressRun {
	mut ctx := Context{}
	ctx.conn = server
	return reserve_inbound_websocket(mut app, ctx) or { panic('reserve') }
}

struct InboundFinalizer {
	executor.DisabledLogicExecutor
	close_fn fn () @[required]
}

fn (e InboundFinalizer) close() { e.close_fn() }

fn inbound_cfg() server_lifecycle.ServerRuntimeConfig {
	return server_lifecycle.ServerRuntimeConfig{ executor_plan: executor.LogicExecutorRuntimePlan{ executor: executor.DisabledLogicExecutor{}, lifecycle: executor.disabled_executor_lifecycle() } }
}

fn test_inbound_dispatch_relay_and_bridge_join_before_app_finalizers() {
	for mode in ['dispatch', 'relay', 'bridge'] {
		mut app := &App{}
		mut server, mut peer := inbound_pair()
		defer { peer.close() or {} }
		fd := server.sock.handle
		mut run := inbound_run(mut app, server)
		match mode {
			'dispatch' {
				spawn ws.run_dispatch_session(mut run, app.build_websocket_runtime_context(), mut server, 'dGhlIHNhbXBsZSBub25jZQ==', 'GET', '/ws', {}, {}, '', 'conn', 'trace', 0, [])
			}
			'relay' {
				spawn run_relay_websocket_session(mut run, mut app, mut server, 'dGhlIHNhbXBsZSBub25jZQ==', 'GET', '/ws', {}, {}, '', 'conn', 'trace', relay.RelayDescriptor{ id: 'relay' })
			}
			else {
				spawn FeishuCardBridgeRuntime.run_server_session(mut run, mut app, mut server, 'dGhlIHNhbXBsZSBub25jZQ==', 'bridge', 'conn')
			}
		}
		inbound_ready(mut peer)
		done := chan bool{cap: 1}
		app.engines.primary.logic_executor = InboundFinalizer{
			close_fn: fn [mut app] () {
				assert app.websocket.state.ingress.active() == 0
				assert app.websocket.active_connections() == 0
			}
		}
		spawn fn [mut app, done] () {
			shutdown_app_runtime(mut app, inbound_cfg())
			done <- true
		}()
		inbound_join(done)
		assert C.fcntl(fd, C.F_GETFD, 0) == -1
		assert app.websocket.state.ingress.reserve() == none
		mut bridge := app.bridge_context()
		assert !bridge.has_client('bridge')
	}
}

fn test_inbound_worker_shutdown_interrupts_blocked_reply_and_releases_hub_state() {
	root := os.join_path(os.temp_dir(), 'inbound-worker-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut listener := unix.listen_stream(root + '/worker.sock') or { panic(err) }
	defer { listener.close() or {} }
	mut worker_peer := unix.connect_stream(root + '/worker.sock') or { panic(err) }
	defer { worker_peer.close() or {} }
	worker_peer.set_read_timeout(time.second)
	mut worker_conn := listener.accept() or { panic(err) }
	mut server, mut peer := inbound_pair()
	defer { peer.close() or {} }
	mut app := &App{}
	mut run := inbound_run(mut app, server)
	assert run.attach(worker_conn.sock.handle)
	worker_fd := worker_conn.sock.handle
	spawn run_worker_websocket_session(mut run, app.build_websocket_runtime_context(), mut server, mut worker_conn, 'fixture', 'dGhlIHNhbXBsZSBub25jZQ==', 'GET', '/ws', 'worker', 'trace', 0, none)
	inbound_ready(mut peer)
	peer.write([u8(0x81), 0x82, 1, 2, 3, 4, u8(104 ^ 1), u8(105 ^ 2)]) or { panic(err) }
	raw := transport.WorkerFrameCodec.read(mut worker_peer) or { panic(err) }
	assert raw.contains('message')
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		shutdown_app_runtime(mut app, inbound_cfg())
		done <- true
	}()
	inbound_join(done)
	assert app.websocket.state.ingress.active() == 0
	assert app.websocket.active_connections() == 0
	assert C.fcntl(worker_fd, C.F_GETFD, 0) == -1
}

fn test_inbound_stop_before_spawn_closes_original_and_does_not_upgrade() {
	mut app := &App{}
	mut server, mut peer := inbound_pair()
	defer { peer.close() or {} }
	fd := server.sock.handle
	mut run := inbound_run(mut app, server)
	stop := app.request_http_ingress_stop()
	spawn ws.run_dispatch_session(mut run, app.build_websocket_runtime_context(), mut server, 'key', 'GET', '/ws', {}, {}, '', 'late', 'trace', 0, [])
	done := chan bool{cap: 1}
	spawn fn [stop, done] () {
		stop.wait() or { panic(err) }
		done <- true
	}()
	inbound_join(done)
	assert C.fcntl(fd, C.F_GETFD, 0) == -1
	assert app.websocket.active_connections() == 0
}

fn test_inbound_failed_upgrade_releases_socket_and_opening_state() {
	mut app := &App{}
	mut server, mut peer := inbound_pair()
	defer { peer.close() or {} }
	fd := server.sock.handle
	assert net.shutdown(fd, how: .write) == 0
	mut run := inbound_run(mut app, server)
	ws.run_dispatch_session(mut run, app.build_websocket_runtime_context(), mut server, 'key', 'GET', '/ws', {}, {}, '', 'failed', 'trace', 0, [])
	assert app.websocket.state.ingress.active() == 0
	assert app.websocket.active_connections() == 0
	assert C.fcntl(fd, C.F_GETFD, 0) == -1
}

fn testsuite_begin() {
	if os.args.len != 3 || os.args[1] != '--inbound-signal' { return }
	root := os.args[2]
	mut app := &App{}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := listener.addr() or { panic(err) }
	app.engines.primary.logic_executor = InboundFinalizer{
		close_fn: fn [mut app, root] () {
			assert app.websocket.state.ingress.active() == 0
			assert app.websocket.active_connections() == 0
			os.write_file(root + '/finalized', 'joined') or { panic(err) }
		}
	}
	register_active_runtime(app, inbound_cfg())
	process_runtime.install_shutdown_signal_handler(vhttpd_shutdown_runtime) or { panic(err) }
	os.write_file(root + '/address', addr.str()) or { panic(err) }
	mut server := listener.accept() or { panic(err) }
	mut run := inbound_run(mut app, server)
	spawn ws.run_dispatch_session(mut run, app.build_websocket_runtime_context(), mut server, 'dGhlIHNhbXBsZSBub25jZQ==', 'GET', '/ws', {}, {}, '', 'signal', 'trace', 0, [])
	time.sleep(10 * time.second)
	exit(91)
}

fn test_real_signals_join_inbound_session_before_process_exit() {
	for sig in [15, 2] {
		root := os.join_path(os.temp_dir(), 'inbound-signal-${os.getpid()}-${sig}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		mut child := os.new_process(os.executable())
		child.set_args(['--inbound-signal', root])
		child.run()
		defer { child.close() }
		deadline := time.now().add(5 * time.second)
		for !os.exists(root + '/address') {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		address := os.read_file(root + '/address') or { panic(err) }
		mut peer := net.dial_tcp(address) or { panic(err) }
		defer { peer.close() or {} }
		peer.set_read_timeout(time.second)
		inbound_ready(mut peer)
		assert C.kill(child.pid, sig) == 0
		exit_deadline := time.now().add(5 * time.second)
		for child.is_alive() && time.now() < exit_deadline { time.sleep(time.millisecond) }
		if child.is_alive() { child.signal_kill() }
		child.wait()
		assert child.code == 128 + sig
		assert os.read_file(root + '/finalized') or { '' } == 'joined'
	}
}
