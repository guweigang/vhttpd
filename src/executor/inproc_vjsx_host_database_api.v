module executor

import json2 as json
import sync
import time
import vjsx

pub interface DatabaseFacade {
	EmbeddedHost
mut:
	vjsx_database_backend() !DatabaseBackend
}

// A plain-data port avoids executor -> dbx -> provider -> executor cycles.
// Implementations must be thread-safe and must not capture any QuickJS value.
// run_fn borrows its cancellation callback only until it returns.
pub struct DatabaseBackend {
pub:
	run_fn   fn (string, fn () bool) !string @[required]
	close_fn fn () @[required]
}

fn (backend DatabaseBackend) close() { backend.close_fn() }

struct DatabaseWireRequest {
	op         string
	timeout_ms int
	session_id string
}

@[heap]
struct VjsxDatabaseBridge {
mut:
	mu       sync.Mutex
	closed   bool
	workers  int
	database ?DatabaseBackend
}

fn (mut bridge VjsxDatabaseBridge) close() {
	bridge.mu.@lock()
	bridge.closed = true
	database := bridge.database
	bridge.mu.unlock()
	if service := database { spawn service.close() }
}

fn InProcVjsxHostApi.database_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		mut bridge := &VjsxDatabaseBridge{}
		ctx.register_host_cleanup(fn [mut bridge] () { bridge.close() })
		return ctx.js_function(fn [ctx, mut bridge, mut state, idx] (args []vjsx.Value) vjsx.Value {
			state.mu.@lock()
			mut session := state.hosts[idx].session_handle() or {
				state.mu.unlock()
				return ctx.js_throw(ctx.js_error(message: 'database_session_unavailable'))
			}
			state.mu.unlock()
			if args.len > 0 && args[0].to_string() == '__drain' {
				session.drain_host_async_events() or {
					return ctx.js_throw(ctx.js_error(
						message: err.msg()
					))
				}
				ctx.drain_ready_tasks() or { return ctx.js_throw(ctx.js_error(message: err.msg())) }
				return ctx.js_undefined()
			}
			if args.len == 0 { return ctx.js_throw(ctx.js_error(message: 'invalid_db_request')) }
			request_json := args[0].to_string()
			req := json.decode[DatabaseWireRequest](request_json) or {
				return ctx.js_throw(ctx.js_error(
					message: 'invalid_db_request'
				))
			}
			if req.timeout_ms <= 0 {
				return ctx.js_throw(ctx.js_error(message: 'invalid_timeout', name: 'TypeError'))
			}
			if bridge.database == none {
				access := state.request_host(idx, .request_only) or {
					return ctx.js_throw(ctx.js_error(
						message: 'database_host_unavailable'
					))
				}
				mut host := access.host
				if mut host is DatabaseFacade {
					backend := host.vjsx_database_backend() or {
						return ctx.js_throw(ctx.js_error(
							message: err.msg()
						))
					}
					bridge.database = backend
				} else {
					return ctx.js_throw(ctx.js_error(message: 'database_unavailable'))
				}
			}
			database := bridge.database or {
				return ctx.js_throw(ctx.js_error(
					message: 'database_unavailable'
				))
			}
			bridge.mu.@lock()
			// Reserve bounded cleanup admission so saturated query workers cannot
			// prevent an idle transaction from rolling back on timeout/abort.
			limit := if req.op == 'rollback' { 96 } else { 64 }
			if bridge.closed || bridge.workers >= limit {
				bridge.mu.unlock()
				return ctx.js_throw(ctx.js_error(message: 'database_busy_or_closed'))
			}
			bridge.workers++
			bridge.mu.unlock()
			operation := session.start_host_async_operation(kind: 'dbx', timeout_ms: req.timeout_ms) or {
				bridge.mu.@lock()
				bridge.workers--
				bridge.mu.unlock()
				return ctx.js_throw(ctx.js_error(message: err.msg()))
			}
			if args.len > 1 && !args[1].is_undefined() && !args[1].is_null() {
				operation.bind_abort_signal(args[1]) or {
					operation.completion.cancel('invalid AbortSignal')
					operation.promise.free()
					bridge.mu.@lock()
					bridge.workers--
					bridge.mu.unlock()
					return ctx.js_throw(ctx.js_error(message: err.msg(), name: 'TypeError'))
				}
			}
			spawn vjsx_database_worker(mut bridge, database, req, request_json, operation.completion, operation.cancel)
			return operation.promise
		})
	}
}

fn vjsx_database_worker(mut bridge VjsxDatabaseBridge, database DatabaseBackend, req DatabaseWireRequest, request_json string, port vjsx.RuntimeHostAsyncCompletionPort, token vjsx.RuntimeHostAsyncCancelToken) {
	defer {
		bridge.mu.@lock()
		bridge.workers--
		bridge.mu.unlock()
	}
	run_scoped_database_work(&VjsxDatabaseWork{
		database:     database
		req:          req
		request_json: request_json
		port:         port
		token:        token
	}) or { port.reject('database_callback_scope_failed:${err}') }
}

// Cancellation callbacks are borrowed by the synchronous native backend. The
// worker scope releases their trampolines only after all backend work returns.
fn vjsx_database_worker_run(database DatabaseBackend, req DatabaseWireRequest, request_json string, port vjsx.RuntimeHostAsyncCompletionPort, token vjsx.RuntimeHostAsyncCancelToken) {
	clock := time.new_stopwatch()
	stop := fn [clock, token, req] () bool {
		return token.is_cancelled() || clock.elapsed().milliseconds() >= req.timeout_ms
	}
	response := database.run_fn(request_json, stop) or {
		if clock.elapsed().milliseconds() >= req.timeout_ms {
			port.timeout()
		} else if !token.is_cancelled() {
			port.reject(err.msg())
		}
		if req.session_id != '' && stop() {
			database.run_fn(json.encode(DatabaseWireRequest{ op: 'rollback', session_id: req.session_id }), fn () bool {
				return false
			}) or {}
		}
		return
	}
	if clock.elapsed().milliseconds() >= req.timeout_ms { port.timeout() }
	delivered := port.resolve_text(response)
	// BEGIN may finish after an abort/close has won. Never orphan its lease.
	if !delivered && req.op == 'begin' {
		begin := json.decode[DatabaseWireRequest](response) or { return }
		database.run_fn(json.encode(DatabaseWireRequest{ op: 'rollback', session_id: begin.session_id }), fn () bool {
			return false
		}) or {}
	}
}
