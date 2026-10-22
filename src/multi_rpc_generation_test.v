module main

import executor
import worker
import ws
import upstream.transport
import sync
import net
import net.http
import net.websocket
import time
import net.unix
import os
import json2 as json

@[heap]
struct MultiRpcProbe {
mut:
	mu         sync.Mutex
	rows       []string
	events     chan string = chan string{cap: 32}
	on_open    fn ()       = fn () {}
	gate_close bool
	gate_mcp   bool
	entered    chan bool = chan bool{cap: 1}
	release    chan bool = chan bool{cap: 1}
}

struct MultiRpcExecutor {
	executor.DisabledLogicExecutor
	label string
	probe &MultiRpcProbe @[required]
}

fn (e MultiRpcExecutor) provider() string { return e.label }

fn (e MultiRpcExecutor) dispatch_websocket_event(mut app executor.AppFacade, req transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut p := e.probe
	p.mu.@lock()
	p.rows << '${e.label}:${req.event}'
	p.mu.unlock()
	if req.event == 'open' { p.on_open() }
	if req.event == 'close' && p.gate_close {
		p.entered <- true
		_ := <-p.release
	}
	p.events <- '${e.label}:${req.event}'
	return transport.WorkerWebSocketDispatchResponse{ accepted: true }
}

fn (e MultiRpcExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut p := e.probe
	p.mu.@lock()
	p.rows << '${e.label}:mcp'
	p.mu.unlock()
	if p.gate_mcp {
		p.entered <- true
		_ := <-p.release
	}
	return transport.WorkerMcpDispatchResponse{ handled: true, body: e.label }
}

fn multi_rpc_publish(mut app App, e executor.LogicExecutor) {
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ logic_executor: e } }
	app.mu.unlock()
}

fn multi_rpc_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return listener.accept() or { panic(err) }, peer
}

fn multi_rpc_event(mut p MultiRpcProbe, expected string) {
	select {
		row := <-p.events {
			assert row == expected
		}
		3 * time.second {
			panic('missing ' + expected)
		}
	}
}

fn test_dispatch_websocket_http_open_message_close_keep_original_executor() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	old := MultiRpcExecutor{ label: 'old', probe: p }
	next := MultiRpcExecutor{ label: 'new', probe: p }
	multi_rpc_publish(mut app, old)
	p.on_open = fn [mut app, next] () { multi_rpc_publish(mut app, next) }
	mut server, mut peer := multi_rpc_pair()
	defer { peer.close() or {} }
	mut ctx := Context{ req: http.Request{ method: .get, url: '/ws' } }
	ctx.req.header.set_custom('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==') or { panic(err) }
	ctx.conn = server
	proxy_worker_websocket_dispatch(mut app, mut ctx, 'GET', '/ws')
	multi_rpc_event(mut p, 'old:open')
	mut buf := []u8{len: 2048}
	n := peer.read(mut buf) or { panic(err) }
	assert buf[..n].bytestr().contains('101 Switching Protocols')
	peer.write([u8(0x81), 0x82, 1, 2, 3, 4, u8(104 ^ 1), u8(105 ^ 2)]) or { panic(err) }
	multi_rpc_event(mut p, 'old:message')
	app.websocket.state.ingress.request_stop()
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		app.websocket.state.ingress.wait()
		done <- true
	}()
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('WebSocket session did not drain')
		}
	}
	multi_rpc_event(mut p, 'old:close')
	assert p.rows == ['old:open', 'old:message', 'old:close']
	assert app.websocket.active_connections() == 0
	fresh := app.build_websocket_runtime_context()
	fresh.dispatch_event(transport.WorkerWebSocketFrame{ event: 'open' }) or { panic(err) }
	multi_rpc_event(mut p, 'new:open')
}

fn test_dispatch_websocket_cancel_before_activation_closes_original_open_once() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	rt := app.build_websocket_runtime_context()
	rt.dispatch_event(transport.WorkerWebSocketFrame{ event: 'open' }) or { panic(err) }
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'new', probe: p })
	mut server, mut peer := multi_rpc_pair()
	defer { peer.close() or {} }
	mut run := app.websocket.state.ingress.reserve() or { panic('reserve') }
	run.request_stop()
	ws.run_dispatch_session(mut run, rt, mut server, 'key', 'GET', '/ws', {}, {}, '', 'c', 'trace', 0, [])
	assert p.rows == ['old:open', 'old:close']
	assert app.websocket.state.ingress.active() == 0
}

fn test_dispatch_websocket_failed_handshake_closes_original_open_once() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	rt := app.build_websocket_runtime_context()
	rt.dispatch_event(transport.WorkerWebSocketFrame{ event: 'open' }) or { panic(err) }
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'new', probe: p })
	mut server, mut peer := multi_rpc_pair()
	defer { peer.close() or {} }
	server.close() or {}
	ws.handle_dispatch_session(rt, mut server, 'key', 'GET', '/ws', {}, {}, '', 'c', 'trace', 0, [])
	assert p.rows == ['old:open', 'old:close']
	assert app.websocket.active_connections() == 0
}

fn test_broadcast_info_uses_each_target_session_executor() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	rt := app.build_websocket_runtime_context()
	client := websocket.new_client('ws://localhost:1') or { panic(err) }
	mut lifecycle := &ws.DispatchConnState{}
	rt.register_conn('target', '', 'GET', 'target', 'trace', '/ws', {}, {}, '', client, lifecycle)
	assert lifecycle.mark_open()
	assert rt.join('target', 'room')
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'new', probe: p })
	fresh := app.build_websocket_runtime_context()
	assert ws.hub_broadcast_dispatch(fresh, 'room', 'payload', '') == 1
	assert p.rows == ['old:info']
	rt.cleanup_conn('target', lifecycle)
	assert app.websocket.active_connections() == 0
}

fn test_mcp_session_route_stays_old_and_new_session_uses_new_executor() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'new', probe: p })
	result := app.kernel_dispatch_mcp(transport.WorkerMcpDispatchRequest{ session_id: 's' }) or { panic(err) }
	assert result.body == 'old'
	fresh := app.mcp_dispatch_route('') or { panic(err) }
	assert (fresh.call_fn(transport.WorkerMcpDispatchRequest{}) or { panic(err) }).body == 'new'
	app.protocols.mcp.delete_session('s')
	if _ := app.kernel_dispatch_mcp(transport.WorkerMcpDispatchRequest{ session_id: 's' }) {
		assert false
	}
	assert p.rows == ['old:mcp', 'new:mcp']
}

fn test_mcp_late_queue_and_capabilities_cannot_cross_reused_id() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
	app.protocols.mcp.delete_session('s')
	fresh := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('s', '', '', '', '', fresh, false) or { panic(err) }
	assert !McpRuntime.queue_message_for_dispatch(mut app, 's', 'old-result', route).queued
	assert app.protocols.mcp.sessions['s'].pending.len == 0
	assert McpRuntime.queue_message_for_dispatch(mut app, 's', 'new-result', fresh).queued
	assert app.protocols.mcp.sessions['s'].pending == ['new-result']
	app.protocols.mcp.request_stop()
	assert app.protocols.mcp.sessions['s'].dispatch == none
}

fn multi_rpc_worker_pool(path string, id int, inflight i64) &worker.WorkerState {
	return &worker.WorkerState{
		worker_backend: worker.WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			read_timeout_ms: 1000
			managed_workers: [transport.ManagedWorker{ id: id, socket_path: path, inflight_requests: inflight, next_retry_ts: time.now().unix_milli() + 60000 }]
		}
	}
}

fn multi_rpc_worker_peer(mut listener unix.StreamListener, events []string, done chan bool) {
	for event in events {
		mut conn := listener.accept() or { panic(err) }
		raw := worker.WorkerBackendFrameCodec.read(mut conn) or { panic(err) }
		request := json.decode[transport.WorkerWebSocketFrame](raw) or { panic(err) }
		assert request.event == event
		worker.WorkerBackendFrameCodec.write(mut conn, '{"accepted":true,"handled":true,"body":"old-worker"}') or { panic(err) }
		conn.close() or {}
	}
	done <- true
}

fn multi_rpc_worker_generation_case(kind string) {
	path := os.join_path(os.temp_dir(), 'vhttpd-multi-rpc-${os.getpid()}-${kind}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := multi_rpc_worker_pool(path, 1, 0)
	replacement := multi_rpc_worker_pool(path, 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	done := chan bool{cap: 1}
	events := if kind == 'ws' { ['open', 'message', 'close'] } else { ['', ''] }
	spawn multi_rpc_worker_peer(mut listener, events, done)
	if kind == 'ws' {
		rt := app.build_websocket_runtime_context()
		rt.dispatch_event(transport.WorkerWebSocketFrame{ event: 'open' }) or { panic(err) }
		app.mu.@lock()
		app.engines = EngineRuntime{ primary: replacement }
		app.mu.unlock()
		rt.dispatch_event(transport.WorkerWebSocketFrame{ event: 'message' }) or { panic(err) }
		rt.dispatch_event(transport.WorkerWebSocketFrame{ event: 'close' }) or { panic(err) }
	} else {
		route := app.mcp_dispatch_route('') or { panic(err) }
		route.call_fn(transport.WorkerMcpDispatchRequest{}) or { panic(err) }
		app.protocols.mcp.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
		app.mu.@lock()
		app.engines = EngineRuntime{ primary: replacement }
		app.mu.unlock()
		assert (app.kernel_dispatch_mcp(transport.WorkerMcpDispatchRequest{ session_id: 's' }) or { panic(err) }).body == 'old-worker'
	}
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('worker session fixture timed out')
		}
	}
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == events.len
	assert replacement.worker_backend.managed_workers[0].inflight_requests == 1
	assert replacement.worker_backend.managed_workers[0].served_requests == 0
}

fn test_worker_websocket_rpc_context_keeps_original_pool_completion() {
	multi_rpc_worker_generation_case('ws')
}

fn test_worker_mcp_rpc_session_keeps_original_pool_completion() {
	multi_rpc_worker_generation_case('mcp')
}

fn multi_rpc_wait(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('RPC gate timed out')
		}
	}
}

fn multi_rpc_finalize(state &ws.DispatchBridgeState, done chan bool) {
	ws.dispatch_session_finalize(state)
	done <- true
}

fn test_concurrent_websocket_finalizers_wait_for_one_close_before_cleanup() {
	mut p := &MultiRpcProbe{ gate_close: true }
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	rt := app.build_websocket_runtime_context()
	lifecycle := &ws.DispatchConnState{}
	app.websocket.state.conns['c'] = ws.HubConn{ id: 'c', lifecycle: lifecycle }
	state := &ws.DispatchBridgeState{ rt: rt, lifecycle: lifecycle, conn_id: 'c' }
	done := chan bool{cap: 2}
	spawn multi_rpc_finalize(state, done)
	multi_rpc_wait(p.entered)
	spawn multi_rpc_finalize(state, done)
	select {
		_ := <-done {
			panic('finalizer skipped in-flight close')
		}
		20 * time.millisecond {
		}
	}
	assert app.websocket.active_connections() == 1
	p.release <- true
	multi_rpc_wait(done)
	multi_rpc_wait(done)
	assert p.rows == ['old:close']
	assert app.websocket.active_connections() == 0
}

fn test_mcp_deleted_during_rpc_rejects_late_handled_response() {
	mut p := &MultiRpcProbe{ gate_mcp: true }
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		if _ := app.kernel_dispatch_mcp_handled(transport.WorkerMcpDispatchRequest{ session_id: 's' }) {
			panic('deleted session RPC accepted')
		}
		done <- true
	}()
	multi_rpc_wait(p.entered)
	app.protocols.mcp.delete_session('s')
	fresh := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('s', 'replacement', '', '', '', fresh, false) or { panic(err) }
	p.release <- true
	multi_rpc_wait(done)
	assert app.protocols.mcp.sessions['s'].protocol_version == 'replacement'
	assert p.rows == ['old:mcp']
}

fn test_mcp_http_existing_session_survives_replacement_without_socket_workers() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
	multi_rpc_publish(mut app, executor.DisabledLogicExecutor{})
	mut server, mut peer := multi_rpc_pair()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	mut ctx := Context{ req: http.Request{ method: .post, url: '/mcp', data: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' } }
	ctx.conn = server
	ctx.req.header.set_custom('Mcp-Session-Id', 's') or { panic(err) }
	mcp_handle_post_http(mut app, mut ctx)
	assert ctx.res.status_code == 200
	assert p.rows == ['old:mcp']
	app.protocols.mcp.delete_session('s')
	mut missing := Context{ req: ctx.req }
	missing.conn = server
	mcp_handle_post_http(mut app, mut missing)
	assert missing.res.status_code == 404
	assert p.rows == ['old:mcp']
}

fn test_late_websocket_finalizer_does_not_notify_replacement_connection_id() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	rt := app.build_websocket_runtime_context()
	stale := &ws.DispatchConnState{ phase: .open }
	current := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: current }
	state := &ws.DispatchBridgeState{ rt: rt, lifecycle: stale, conn_id: 'same' }
	ws.dispatch_session_finalize(state)
	assert p.rows.len == 0
	assert current.phase() == .open
	assert app.websocket.active_connections() == 1
}

fn test_backend_retirement_detaches_only_old_mcp_session_and_joins_sse_owner() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'old', probe: p })
	mut old := app.engines.primary
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('old', '', '', '', '', route, false) or { panic(err) }
	server, mut peer := multi_rpc_pair()
	defer { peer.close() or {} }
	mut stream := app.protocols.mcp.attach_stream('old', server) or { panic(err) }
	stream.start(fn (mut conn net.TcpConn) ! {}) or { panic(err) }
	done := chan bool{cap: 1}
	spawn fn [mut app, mut stream, done] () {
		app.protocols.mcp.run_stream('old', mut stream)
		done <- true
	}()
	multi_rpc_publish(mut app, MultiRpcExecutor{ label: 'new', probe: p })
	fresh := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('new', '', '', '', '', fresh, false) or { panic(err) }
	old.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
	app.retire_mcp_dispatch_sessions()
	multi_rpc_wait(done)
	assert stream.finished()
	assert app.protocols.mcp.active_streams() == 0
	assert 'old' !in app.protocols.mcp.sessions
	assert 'new' in app.protocols.mcp.sessions
	if _ := app.protocols.mcp.complete_dispatch_session('late', '', '', '', '', route, false) {
		panic('late initializer resurrected retired backend')
	}
	assert 'late' !in app.protocols.mcp.sessions
	assert voidptr(app.mcp_dispatch_route('new') or { panic(err) }) == voidptr(fresh)
}

struct MultiRpcNativeExecutor {
	MultiRpcExecutor
	conn &unix.StreamConn @[required]
}

fn (e MultiRpcNativeExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	if !req.register_conn_fn(e.conn.sock.handle) { return error('session_stopping') }
	e.probe.on_open()
	return executor.WebSocketSessionOpenOutcome{ accepted: true, conn: e.conn }
}

fn test_native_worker_activation_retains_selected_context_for_info_rpc() {
	mut p := &MultiRpcProbe{}
	mut app := &App{}
	path := os.join_path(os.temp_dir(), 'vhttpd-native-route-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut worker_peer := unix.connect_stream(path) or { panic(err) }
	defer { worker_peer.close() or {} }
	worker_conn := listener.accept() or { panic(err) }
	old := MultiRpcNativeExecutor{ MultiRpcExecutor: MultiRpcExecutor{ label: 'old', probe: p }, conn: worker_conn }
	next := MultiRpcExecutor{ label: 'new', probe: p }
	multi_rpc_publish(mut app, old)
	p.on_open = fn [mut app, next] () { multi_rpc_publish(mut app, next) }
	mut server, mut peer := multi_rpc_pair()
	defer { peer.close() or {} }
	mut ctx := Context{ req: http.Request{ method: .get, url: '/ws' } }
	ctx.req.header.set_custom('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==') or { panic(err) }
	ctx.req.header.set_custom('X-Request-Id', 'native-origin') or { panic(err) }
	ctx.req.header.set_custom('Upgrade', 'websocket') or { panic(err) }
	ctx.req.header.set_custom('Connection', 'Upgrade') or { panic(err) }
	ctx.req.header.set_custom('Sec-WebSocket-Version', '13') or { panic(err) }
	ctx.conn = server
	proxy_worker_websocket(mut app, mut ctx, 'GET', '/ws')
	mut buf := []u8{len: 2048}
	n := peer.read(mut buf) or { panic(err) }
	assert buf[..n].bytestr().contains('101 Switching Protocols')
	fresh := app.build_websocket_runtime_context()
	deadline := time.now().add(time.second)
	for !fresh.conn_open('native-origin') && time.now() < deadline { time.sleep(time.millisecond) }
	assert fresh.conn_open('native-origin')
	assert fresh.join('native-origin', 'room')
	assert ws.hub_broadcast_dispatch(fresh, 'room', 'payload', '') == 1
	assert p.rows == ['old:info']
	app.websocket.state.ingress.request_stop()
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		app.websocket.state.ingress.wait()
		done <- true
	}()
	multi_rpc_wait(done)
	assert app.websocket.active_connections() == 0
}
