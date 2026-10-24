module main

import executor
import connection_runtime
import cachex
import net
import net.unix
import os
import process_runtime
import server_lifecycle
import time

fn C.kill(int, int) int

fn signal_network_config(pid string) server_lifecycle.ServerRuntimeConfig {
	return server_lifecycle.ServerRuntimeConfig{
		pid_file:      pid
		executor_plan: executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
}

fn signal_network_stream(mut app App) &net.TcpConn {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	listener.close() or { panic(err) }
	peer.set_read_timeout(2 * time.second)
	app.protocols.mcp.ensure_session('signal', '', '', '', '')
	mut ctx := Context{}
	ctx.conn = server
	ctx.req.url = '/mcp'
	ctx.req.method = .get
	ctx.query['session_id'] = 'signal'
	mcp_handle_get_http(mut app, mut ctx)
	mut text := ''
	mut bytes := []u8{len: 2048}
	for !text.contains(': connected\n\n') {
		n := peer.read(mut bytes) or { panic(err) }
		assert n > 0
		text += bytes[..n].bytestr()
	}
	assert app.protocols.mcp.active_streams() == 1
	return peer
}

fn signal_network_admin(path string) &unix.StreamConn {
	deadline := time.now().add(2 * time.second)
	for {
		conn := unix.connect_stream(path) or {
			assert time.now() < deadline
			time.sleep(time.millisecond)
			continue
		}
		return conn
	}
	panic('unreachable admin connection')
}

// Executed fixtures install real signal handlers without modifying the runner.
fn testsuite_begin() {
	if os.args.len != 3 || os.args[1] != '--signal-network-probe' { return }
	root := os.args[2]
	mut one := &App{}
	mut two := &App{}
	mut peer := signal_network_stream(mut one)
	path := root + '/admin.sock'
	one.lifecycle.internal_admin.start(mut one, path) or { panic(err) }
	mut admin_peer := signal_network_admin(path)
	deadline := time.now().add(2 * time.second)
	admin_peer.set_read_timeout(2 * time.second)
	admin_peer.write([u8(0), 0]) or { panic(err) }
	for one.lifecycle.internal_admin.owner.active_requests(1) != 1 {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	cache_path := root + '/cache.sock'
	one.transport.cache = cachex.Runtime.new(true, cache_path)
	assert one.transport.cache.start(cache_path)
	mut cache_peer := signal_network_admin(cache_path)
	cache_peer.write([u8(0), 0]) or { panic(err) }
	for one.transport.cache.listener_owner.active_requests(1) == 0 {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	$if enable_db ? {
		one.transport.db.enabled = true
		one.transport.db.driver = 'pgsql'
		assert one.db_runtime_server_start(root + '/db.sock')
		mut db_peer := signal_network_admin(root + '/db.sock')
		db_peer.write([u8(0), 0]) or { panic(err) }
		for one.transport.db.listener_owner.active_requests(1) == 0 {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
	}
	first_pid := root + '/one.pid'
	second_pid := root + '/two.pid'
	process_runtime.acquire_pid_files([first_pid, second_pid]) or { panic(err) }
	register_active_runtime(one, signal_network_config(first_pid))
	register_active_runtime(two, signal_network_config(second_pid))
	mut first := one.websocket.upstream_runs.reserve('test/one') or { panic('first run') }
	mut second := two.websocket.upstream_runs.reserve('test/two') or { panic('second run') }
	mut bridge := one.providers.feishu.background_runs.reserve('bridge') or { panic('bridge run') }
	job := one.codex_queue_error_burst('main', 'signal', '{"error":"cancelled"}') or { panic('burst') }
	spawn fn [mut two, mut second, root] () {
		assert !second.wait(time.hour)
		os.write_file(root + '/two.finished', 'joined') or { panic(err) }
		two.websocket.upstream_runs.release('test/two', mut second)
	}()
	spawn fn [mut one, mut bridge, mut first, mut second, root] () {
		assert !bridge.wait(time.hour)
		// Another App must already have been notified before any wait begins.
		assert first.stopped() && second.stopped()
		os.write_file(root + '/bridge.finished', 'joined') or { panic(err) }
		one.providers.feishu.background_runs.release('bridge', mut bridge)
	}()
	spawn fn [job, root] () {
		defer { job.finish() }
		assert !job.wait(time.hour)
		assert job.take().len == 0
		os.write_file(root + '/burst.finished', 'joined') or { panic(err) }
	}()
	spawn fn [mut one, mut first, mut second, mut bridge, mut peer, mut admin_peer, root] () {
		assert !first.wait(time.hour)
		assert second.stopped() && bridge.stopped()
		// Signal shutdown must release the registry mutex before waiting.
		assert active_runtime_config_snapshot().len == 2
		deadline := time.now().add(2 * time.second)
		for one.protocols.mcp.active_streams() != 0 || one.lifecycle.internal_admin.owner.is_current(1) {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		mut bytes := []u8{len: 1}
		assert (peer.read(mut bytes) or { 0 }) == 0
		assert (admin_peer.read(mut bytes) or { 0 }) == 0
		assert !os.exists(root + '/admin.sock')
		assert one.transport.cache.listener_owner.is_current(1)
		assert os.exists(root + '/cache.sock')
		$if enable_db ? {
			assert one.transport.db.listener_owner.is_current(1)
			assert os.exists(root + '/db.sock')
		}
		os.write_file(root + '/one.finished', 'joined') or { panic(err) }
		one.websocket.upstream_runs.release('test/one', mut first)
	}()
	mut http_peer := signal_network_http(mut one, mut first, root)
	defer { http_peer.close() or {} }
	process_runtime.install_shutdown_signal_handler(vhttpd_shutdown_runtime) or { panic(err) }
	os.write_file(root + '/ready', 'ready') or { panic(err) }
	time.sleep(10 * time.second)
	exit(91)
}

fn run_signal_network_probe(sig int) {
	root := os.join_path(os.temp_dir(), 'vhttpd-sig-net-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut child := os.new_process(os.executable())
	child.set_args(['--signal-network-probe', root])
	child.run()
	defer { child.close() }
	ready_deadline := time.now().add(5 * time.second)
	for !os.exists(root + '/ready') && child.is_alive() && time.now() < ready_deadline {
		time.sleep(time.millisecond)
	}
	if !os.exists(root + '/ready') {
		child.signal_kill()
		child.wait()
		assert false, 'signal fixture did not become ready'
		return
	}
	assert C.kill(child.pid, sig) == 0
	exit_deadline := time.now().add(5 * time.second)
	for child.is_alive() && time.now() < exit_deadline { time.sleep(time.millisecond) }
	if child.is_alive() { child.signal_kill() }
	child.wait()
	assert child.code == 128 + sig
	for marker in ['one', 'two', 'bridge', 'burst', 'http'] {
		assert os.read_file(root + '/${marker}.finished') or { '' } == 'joined', 'missing ${marker} cleanup'
	}
	assert !os.exists(root + '/admin.sock')
	assert !os.exists(root + '/cache.sock')
	$if enable_db ? {
		assert !os.exists(root + '/db.sock')
	}
	assert !os.exists(root + '/one.pid') && !os.exists(root + '/two.pid')
}

fn test_sigterm_joins_all_apps_mcp_bridge_burst_and_partial_admin_before_exit() {
	run_signal_network_probe(15)
}

fn test_sigint_joins_all_apps_mcp_bridge_burst_and_partial_admin_before_exit() {
	run_signal_network_probe(2)
}

fn test_background_stop_tickets_are_idempotent_and_keep_admission_closed() {
	mut app := &App{}
	mut run := app.websocket.upstream_runs.reserve('test/run') or { panic('run') }
	first := app.request_background_network_stop()
	second := app.request_background_network_stop()
	assert run.stopped()
	assert app.websocket.upstream_runs.reserve('new') == none
	assert app.codex_queue_error_burst('main', 'new', 'error') == none
	app.websocket.upstream_runs.release('test/run', mut run)
	first.wait()
	second.wait()
	first.wait()
	assert app.lifecycle.internal_admin.request_stop() == none
}

// The signal must drain the owned HTTP handler before stopping its dependencies.
fn signal_network_http(mut app App, mut run connection_runtime.Run, root string) &net.TcpConn {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	addr := listener.addr() or { panic(err) }
	port := addr.port() or { panic(err) }
	listener.close() or { panic(err) }
	entered := chan bool{cap: 1}
	mut owner := app.lifecycle.http
	app.use(handler: fn [mut owner, mut run, entered, root] (mut ctx Context) bool {
		entered <- true
		deadline := time.now().add(3 * time.second)
		for owner.accepting() { assert time.now() < deadline; time.sleep(time.millisecond) }
		assert !run.stopped()
		os.write_file(root + '/http.finished', 'joined') or { panic(err) }
		ctx.text('drained')
		return false
	})
	base := signal_network_config('')
	cfg := server_lifecycle.ServerRuntimeConfig{...base, host: '127.0.0.1', port: int(port), serve_data_plane: true}
	spawn serve_server_runtime(mut app, cfg)
	deadline := time.now().add(3 * time.second)
	for {
		mut peer := net.dial_tcp(addr.str()) or {
			assert time.now() < deadline
			time.sleep(time.millisecond)
			continue
		}
		peer.write_string('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n') or { panic(err) }
		select { _ := <-entered {} 3 * time.second { panic('signal HTTP request did not enter') } }
		return peer
	}
	panic('unreachable HTTP connection')
}
