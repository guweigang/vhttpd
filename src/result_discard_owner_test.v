module main

import executor
import net
import net.http
import net.unix
import os
import runtime_plan
import time
import upstream.transport
import worker

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int

struct DiscardExecutor {
	executor.DisabledLogicExecutor
	http_result executor.HttpLogicDispatchOutcome
	ws_result   executor.WebSocketSessionOpenOutcome
}

fn (_ DiscardExecutor) kind() string { return 'vjsx' }

fn (_ DiscardExecutor) model() executor.LogicExecutorModel { return .embedded }

fn (e DiscardExecutor) dispatch_http(mut _ executor.AppFacade, _ executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	return e.http_result
}

fn (e DiscardExecutor) open_websocket_session(mut _ executor.AppFacade, _ executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	return e.ws_result
}

fn discard_fixture(leased bool, kind executor.HttpLogicDispatchKind) (executor.HttpLogicDispatchOutcome, int, chan bool) {
	path := os.join_path(os.temp_dir(), 'discard-owner-${os.getpid()}-${time.now().unix_micro()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut conn := unix.connect_stream(path) or { panic(err) }
	mut peer := listener.accept() or { panic(err) }
	peer.close() or {}
	fd := conn.sock.handle
	finished := chan bool{cap: 4}
	if leased {
		mut lease := &executor.WorkerRequestLease{ socket_path: path, finish_fn: fn [fd, finished] (_ string) {
			finished <- (C.fcntl(fd, C.F_GETFD, 0) < 0)
		} }
		lease.retain_connection(conn)
		return executor.HttpLogicDispatchOutcome{ kind: kind, response: transport.WorkerResponse{ status: 202, body: 'accepted' }, conn: conn, lease: lease }, fd, finished
	}
	return executor.HttpLogicDispatchOutcome{ kind: kind, response: transport.WorkerResponse{ status: 202, body: 'accepted' }, conn: conn }, fd, finished
}

fn discard_app(owned executor.HttpLogicDispatchOutcome, accepted bool) App {
	return App{
		plan:    runtime_plan.RuntimePlan{ transforms: {
			'event': runtime_plan.TransformPlan{ id: 'event', kind: 'vjsx', handler: 'handler' }
		} }
		engines: EngineRuntime{ primary: &worker.WorkerState{ logic_executor: DiscardExecutor{ http_result: owned, ws_result: executor.WebSocketSessionOpenOutcome{ accepted: accepted, status: 403, body: 'blocked', conn: owned.conn, lease: owned.lease } } } }
	}
}

fn discard_expect_pending(fd int, finished chan bool) {
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
	select {
		_ := <-finished {
			assert false, "discard finished another consumer's lease"
		}
		else {
		}
	}
}

fn discard_tcp_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	return listener.accept() or { panic(err) }, peer
}

fn discard_websocket_request(mut app App) Context {
	mut server, mut peer := discard_tcp_pair()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	mut ctx := Context{ req: http.Request{ method: .get, url: '/ws' }, conn: server }
	ctx.req.header.set(.sec_websocket_key, 'dGhlIHNhbXBsZSBub25jZQ==')
	ctx.req.header.set(.upgrade, 'websocket')
	ctx.req.header.set(.connection, 'Upgrade')
	proxy_worker_websocket(mut app, mut ctx, 'GET', '/ws')
	assert app.websocket.state.ingress.active() == 0
	return ctx
}

fn test_http_response_and_invalid_upstream_discard_unclaimed_resources() {
	for kind in [executor.HttpLogicDispatchKind.response, .upstream_plan] {
		for leased in [false, true] {
			mut owned, fd, finished := discard_fixture(leased, kind)
			defer { owned.close_live_conn() }
			mut app := discard_app(owned, false)
			mut ctx := Context{ req: http.Request{ method: .get, url: '/request' } }
			HttpIngressRuntime.handle(mut app, mut ctx, 'GET', '/request', '')
			assert ctx.res.status_code == if kind == .response { 202 } else { 502 }
			assert C.fcntl(fd, C.F_GETFD, 0) < 0
			if leased {
				assert <-finished
			} else {
				owned.conn = none
			}
		}
	}
}

fn test_rejected_websocket_open_discards_attached_unclaimed_resources() {
	for leased in [false, true] {
		mut owned, fd, finished := discard_fixture(leased, .response)
		defer { owned.close_live_conn() }
		mut app := discard_app(owned, false)
		ctx := discard_websocket_request(mut app)
		assert ctx.res.status_code == 403
		assert ctx.res.body == 'blocked'
		assert C.fcntl(fd, C.F_GETFD, 0) < 0
		if leased {
			assert <-finished
		} else {
			owned.conn = none
		}
	}
}

fn test_http_discard_preserves_connection_and_lease_already_taken_by_a_consumer() {
	for kind in [executor.HttpLogicDispatchKind.response, .upstream_plan] {
		mut owned, fd, finished := discard_fixture(true, kind)
		defer { owned.close_live_conn() }
		mut app := discard_app(owned, false)
		mut conn := owned.take_live_conn() or { panic('missing owned connection') }
		defer {
			conn.close() or {}
			owned.finish_worker()
		}
		mut ctx := Context{ req: http.Request{ method: .get, url: '/request' } }
		HttpIngressRuntime.handle(mut app, mut ctx, 'GET', '/request', '')
		discard_expect_pending(fd, finished)
		conn.close() or {}
		owned.finish_worker()
		assert <-finished
	}
}

fn test_websocket_rejection_preserves_a_transferred_lease() {
	mut owned, fd, finished := discard_fixture(true, .response)
	defer { owned.close_live_conn() }
	mut app := discard_app(owned, false)
	mut conn := owned.take_live_conn() or { panic('missing owned connection') }
	defer {
		conn.close() or {}
		owned.finish_worker()
	}
	assert discard_websocket_request(mut app).res.status_code == 403
	discard_expect_pending(fd, finished)
	conn.close() or {}
	owned.finish_worker()
	assert <-finished
}

fn test_transform_and_upload_discard_do_not_finish_transferred_leases() {
	for consumer in ['transform', 'upload'] {
		mut owned, fd, finished := discard_fixture(true, .stream)
		defer { owned.close_live_conn() }
		mut app := discard_app(owned, false)
		app.transformers = TransformerRuntimeHub.from_plan(app.plan)
		mut conn := owned.take_live_conn() or { panic('missing owned connection') }
		defer {
			conn.close() or {}
			owned.finish_worker()
		}
		if consumer == 'transform' {
			mut services := noop_dispatch_services('trace')
			mut exchange := runtime_event_exchange('request', 'trace', '', '', '', '', '', {})
			assert !app.run_transform_refs(['event'], mut services, mut exchange)!.halted
		} else {
			app.dispatch_upload_completed_vjsx(app.engine_runtime_snapshot(), 'handler', UploadResponse{}, {})
		}
		discard_expect_pending(fd, finished)
		conn.close() or {}
		owned.finish_worker()
		assert <-finished
	}
}

fn test_websocket_missing_connection_finishes_unclaimed_empty_lease() {
	finished := chan bool{cap: 2}
	lease := &executor.WorkerRequestLease{ socket_path: 'empty', finish_fn: fn [finished] (_ string) {
		finished <- true
	} }
	mut app := discard_app(executor.HttpLogicDispatchOutcome{ lease: lease }, true)
	ctx := discard_websocket_request(mut app)
	assert ctx.res.status_code == 502
	assert <-finished
	mut copy := executor.WebSocketSessionOpenOutcome{ lease: lease }
	copy.close_live_conn()
	select {
		_ := <-finished {
			assert false
		}
		else {
		}
	}
}
