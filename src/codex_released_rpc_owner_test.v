module main

import codex
import executor
import net
import net.websocket
import sync
import time
import upstream.transport

struct ReleasedRpcProbe {
mut:
	mu             sync.Mutex
	close_count    int
	delivered      chan transport.WorkerWebSocketUpstreamDispatchRequest = chan transport.WorkerWebSocketUpstreamDispatchRequest{cap: 16}
	dispatch_count int
	last_req       transport.WorkerWebSocketUpstreamDispatchRequest
}

struct ReleasedRpcExecutor {
mut:
	state &ReleasedRpcProbe @[required]
}

pub fn (e ReleasedRpcExecutor) kind() string {
	return 'vjsx'
}

pub fn (e ReleasedRpcExecutor) model() executor.LogicExecutorModel {
	return .embedded
}

pub fn (e ReleasedRpcExecutor) provider() string {
	return 'vjsx'
}

pub fn (e ReleasedRpcExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'vjsx'
		provider: 'vjsx'
		model:    executor.LogicExecutorModel.embedded.str()
	}
}

pub fn (e ReleasedRpcExecutor) warmup(mut app executor.AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e ReleasedRpcExecutor) close() {
	mut state := e.state
	state.mu.@lock()
	state.close_count++
	state.mu.unlock()
}

pub fn (e ReleasedRpcExecutor) dispatch_http(mut app executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ReleasedRpcExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ReleasedRpcExecutor) dispatch_stream(mut app executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ReleasedRpcExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ReleasedRpcExecutor) dispatch_websocket_upstream(mut app executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = app
	mut state := e.state
	state.mu.@lock()
	state.dispatch_count++
	state.last_req = req
	state.mu.unlock()
	state.delivered <- req
	return transport.WorkerWebSocketUpstreamDispatchResponse{
		mode:     'websocket_upstream'
		event:    'result'
		id:       req.id
		handled:  true
		commands: []transport.WorkerWebSocketUpstreamCommand{}
	}
}

pub fn (e ReleasedRpcExecutor) dispatch_websocket_event(mut app executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return error('not_used')
}

fn released_rpc_app() (&App, &ReleasedRpcProbe) {
	mut app := &App{}
	mut probe := &ReleasedRpcProbe{}
	app.engines.primary.logic_executor = ReleasedRpcExecutor{ state: probe }
	app.providers.codex.runtime.thread_id = 'keep-thread'
	app.providers.codex.runtime.active_stream_id = 'keep-stream'
	return app, probe
}

fn test_codex_release_retires_pending_only_route_without_dropping_response_registration() {
	mut rt := codex.ProviderRuntime{}
	rt.remember_pending_rpc(7, codex.PendingRpc{ method: 'thread/read', stream_id: 'released' })
	assert rt.clear_stream_targets('released')
	assert rt.pending_stream_id() == ''
	assert rt.pending_rpcs.len == 1
	assert !rt.clear_stream_targets('released')
	pending, found := rt.take_pending_rpc(7)
	assert found
	assert pending.method == 'thread/read'
	assert rt.pending_rpcs.len == 0
}

fn test_codex_release_revokes_prepared_rpc_registration_admission() {
	mut app := &App{}
	registration := app.providers.codex_register_rpc('secondary', codex.PendingRpc{ method: 'turn/start', stream_id: 'released' })
	assert registration.is_pending()
	_ = app.codex_clear_stream_targets('secondary', 'released')
	assert !registration.is_pending()
	assert app.providers.codex.snapshot('secondary').pending_rpcs.len == 1
	assert app.codex_pending_stream_id('secondary') == ''
}

fn test_codex_release_preserves_other_pending_routes_and_unscoped_rpcs() {
	mut rt := codex.ProviderRuntime{}
	rt.remember_pending_rpc(1, codex.PendingRpc{ stream_id: 'released' })
	rt.remember_pending_rpc(2, codex.PendingRpc{ stream_id: 'live' })
	rt.remember_pending_rpc(3, codex.PendingRpc{ method: 'initialize' })
	_ = rt.clear_stream_targets('released')
	assert rt.pending_stream_id() == 'live'
	assert rt.pending_rpcs.len == 3
	assert !rt.clear_stream_targets('')
}

fn test_codex_released_rpc_success_cannot_capture_thread_or_dispatch() {
	mut app, probe := released_rpc_app()
	registration := app.providers.codex_register_rpc('main', codex.PendingRpc{ method: 'thread/start', stream_id: 'released' })
	_ = app.codex_clear_stream_targets('main', 'released')
	raw := '{"id":${registration.id},"result":{"thread":{"id":"stale-thread"}}}'
	app.codex_handle_response('main', codex.classify_rpc(raw), raw)
	assert app.providers.codex.snapshot('main').thread_id == 'keep-thread'
	assert probe.delivered.len == 0
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 0
}

fn test_codex_released_rpc_error_cannot_schedule_delayed_business_dispatch() {
	mut app, probe := released_rpc_app()
	defer {
		ctx := app.build_provider_context('codex')
		ctx.stop() or { panic(err) }
	}
	registration := app.providers.codex_register_rpc('main', codex.PendingRpc{ method: 'turn/start', stream_id: 'released' })
	_ = app.codex_clear_stream_targets('main', 'released')
	raw := '{"id":${registration.id},"error":{"message":"late failure"}}'
	app.codex_handle_response('main', codex.classify_rpc(raw), raw)
	mut dispatched := false
	select {
		_ := <-probe.delivered {
			dispatched = true
		}
		time.second {
		}
	}
	assert !dispatched
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 0
}

fn test_codex_prepared_rpc_cannot_write_after_its_stream_is_released() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	mut client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	defer {
		peer.close() or {}
		client.conn.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, conn: client })
	prepared := app.providers.codex_prepare_rpc('main', codex.PendingRpc{ method: 'turn/start', stream_id: 'released' }, '')
	assert prepared.failure == ''
	_ = app.codex_clear_stream_targets('main', 'released')
	mut rejected := false
	prepared.send('turn/start', '{}') or { rejected = true }
	assert rejected
	peer.set_read_timeout(30 * time.millisecond)
	mut bytes := []u8{len: 128}
	mut received := 0
	received = peer.read(mut bytes) or { 0 }
	assert received == 0
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 0
}

fn test_codex_reused_stream_id_does_not_restore_old_rpc_routing() {
	mut app, probe := released_rpc_app()
	old := app.providers.codex_register_rpc('main', codex.PendingRpc{ method: 'thread/start', stream_id: 'reused' })
	_ = app.codex_clear_stream_targets('main', 'reused')
	fresh := app.providers.codex_register_rpc('main', codex.PendingRpc{ method: 'thread/start', stream_id: 'reused' })
	assert fresh.is_pending()
	raw := '{"id":${old.id},"result":{"thread":{"id":"old-thread"}}}'
	app.codex_handle_response('main', codex.classify_rpc(raw), raw)
	assert app.providers.codex.snapshot('main').thread_id == 'keep-thread'
	assert probe.delivered.len == 0
	fresh_raw := '{"id":${fresh.id},"result":{"thread":{"id":"fresh-thread"}}}'
	app.codex_handle_response('main', codex.classify_rpc(fresh_raw), fresh_raw)
	assert app.providers.codex.snapshot('main').thread_id == 'fresh-thread'
	assert probe.delivered.len == 1
	req := <-probe.delivered
	assert req.target == 'reused'
}

fn test_codex_active_rpc_response_retains_business_delivery() {
	mut app, probe := released_rpc_app()
	registration := app.providers.codex_register_rpc('main', codex.PendingRpc{ method: 'thread/read', stream_id: 'keep-stream' })
	raw := '{"id":${registration.id},"result":{"ok":true}}'
	app.codex_handle_response('main', codex.classify_rpc(raw), raw)
	assert probe.delivered.len == 1
	req := <-probe.delivered
	assert req.target == 'keep-stream'
	assert req.payload.contains('thread/read')
	assert !registration.is_pending()
}
