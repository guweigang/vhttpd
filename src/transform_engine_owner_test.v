module main

import dispatch
import executor
import net.unix
import os
import runtime_plan
import time
import upstream.transport
import worker

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int

struct TransformRouteExecutor {
	executor.DisabledLogicExecutor
	call_fn fn (executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome @[required]
}

fn (_ TransformRouteExecutor) kind() string { return 'vjsx' }

fn (_ TransformRouteExecutor) model() executor.LogicExecutorModel { return .embedded }

fn (e TransformRouteExecutor) dispatch_http(mut _ executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	return e.call_fn(req)!
}

fn transform_route_executor(label string, calls chan string) executor.LogicExecutor {
	return TransformRouteExecutor{
		call_fn: fn [label, calls] (req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
			calls <- '${label}:${req.path.all_after_last('/')}'
			return executor.HttpLogicDispatchOutcome{ response: transport.WorkerResponse{ status: 200, body: label } }
		}
	}
}

fn transform_route_publish(mut app App, value executor.LogicExecutor, named bool) {
	app.mu.@lock()
	defer { app.mu.unlock() }
	app.plan = runtime_plan.RuntimePlan{
		transforms: {
			'first': runtime_plan.TransformPlan{ id: 'first', kind: 'vjsx', handler: 'first', engine: runtime_plan.ResourceRef{ domain: .engine, id: 'chosen' } }
			'last':  runtime_plan.TransformPlan{ id: 'last', kind: 'vjsx', handler: 'last', engine: runtime_plan.ResourceRef{ domain: .engine, id: 'chosen' } }
		}
	}
	app.transformers = TransformerRuntimeHub.from_plan(app.plan)
	app.engines = if named {
		EngineRuntime{
			additional: {
				'chosen': &worker.WorkerState{ logic_executor: value }
			}
		}
	} else {
		EngineRuntime{ primary: &worker.WorkerState{ logic_executor: value } }
	}
}

fn transform_route_exchange() dispatch.Exchange {
	return runtime_event_exchange('request', 'trace', 'provider:events', 'events', 'topic', 'event', '{}', {})
}

fn test_vjsx_transform_chain_keeps_engine_registry_during_callback_replacement() {
	mut app := &App{}
	calls := chan string{cap: 16}
	old := TransformRouteExecutor{
		call_fn: fn [mut app, calls] (req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
			calls <- 'old:${req.path.all_after_last('/')}'
			if req.path.ends_with('/first') {
				transform_route_publish(mut app, transform_route_executor('new', calls), true)
			}
			return executor.HttpLogicDispatchOutcome{}
		}
	}
	transform_route_publish(mut app, old, true)
	mut services := noop_dispatch_services('trace')
	mut exchange := transform_route_exchange()
	assert !app.run_transform_refs(['first', 'last'], mut services, mut exchange)!.halted
	assert <-calls == 'old:first'
	assert <-calls == 'old:last'
	assert !app.run_transform_refs(['last'], mut services, mut exchange)!.halted
	assert <-calls == 'new:last'
}

fn test_http_and_pipeline_views_retain_transform_engines_after_replacement() {
	mut app := App{}
	calls := chan string{cap: 16}
	transform_route_publish(mut app, transform_route_executor('old', calls), true)
	http_view := app.http_dispatch_view()
	pipeline_view := app.pipeline_dispatch_view()
	transform_route_publish(mut app, transform_route_executor('new', calls), true)
	for view in [http_view.transform_dispatch_view(), pipeline_view.transform_dispatch_view()] {
		mut services := noop_dispatch_services('trace')
		mut exchange := transform_route_exchange()
		assert !app.run_transform_refs_on_view(view, ['last'], mut services, mut exchange)!.halted
		assert <-calls == 'old:last'
	}
}

fn test_transform_missing_named_engine_uses_only_captured_fallback_registry() {
	mut app := App{}
	calls := chan string{cap: 16}
	transform_route_publish(mut app, transform_route_executor('old-default', calls), false)
	view := app.transform_dispatch_view()
	app.engines.additional['chosen'] = &worker.WorkerState{ logic_executor: transform_route_executor('late', calls) }
	mut services := noop_dispatch_services('trace')
	mut exchange := transform_route_exchange()
	assert !app.run_transform_refs_on_view(view, ['last'], mut services, mut exchange)!.halted
	assert <-calls == 'old-default:last'
	assert !app.run_transform_refs(['last'], mut services, mut exchange)!.halted
	assert <-calls == 'late:last'
}

fn test_retired_transform_executor_error_does_not_fall_forward_to_replacement() {
	mut app := App{}
	calls := chan string{cap: 16}
	transform_route_publish(mut app, TransformRouteExecutor{
		call_fn: fn (_ executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
			return error('origin_retired')
		}
	}, true)
	view := app.transform_dispatch_view()
	transform_route_publish(mut app, transform_route_executor('new', calls), true)
	mut services := noop_dispatch_services('trace')
	mut exchange := transform_route_exchange()
	app.run_transform_refs_on_view(view, ['last'], mut services, mut exchange) or {
		assert err.msg() == 'origin_retired'
		select {
			_ := <-calls {
				assert false
			}
			else {
			}
		}
		return
	}
	assert false
}

fn transform_owned_outcome(leased bool, kind executor.HttpLogicDispatchKind) (executor.HttpLogicDispatchOutcome, int, chan bool) {
	path := os.join_path(os.temp_dir(), 'transform-result-${os.getpid()}-${time.now().unix_micro()}.sock')
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
		mut lease := &executor.WorkerRequestLease{
			socket_path: path
			finish_fn:   fn [fd, finished] (_ string) {
				assert C.fcntl(fd, C.F_GETFD, 0) < 0
				finished <- true
			}
		}
		lease.retain_connection(conn)
		return executor.HttpLogicDispatchOutcome{ kind: kind, response: transport.WorkerResponse{ status: 503 }, conn: conn, lease: lease }, fd, finished
	}
	return executor.HttpLogicDispatchOutcome{ kind: kind, response: transport.WorkerResponse{ status: 503 }, conn: conn }, fd, finished
}

fn test_transform_and_upload_events_reclaim_unconsumed_stream_outcomes() {
	for consumer in ['transform', 'upload'] {
		for leased in [false, true] {
			mut owned, fd, finished := transform_owned_outcome(leased, .stream)
			defer {
				owned.close_live_conn()
				owned.finish_worker()
			}
			mut app := App{}
			transform_route_publish(mut app, TransformRouteExecutor{
				call_fn: fn [owned] (_ executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
					return owned
				}
			}, false)
			if consumer == 'transform' {
				mut services := noop_dispatch_services('trace')
				mut exchange := transform_route_exchange()
				assert !app.run_transform_refs(['last'], mut services, mut exchange)!.halted
			} else {
				app.dispatch_upload_completed_vjsx(app.engine_runtime_snapshot(), 'completed', UploadResponse{}, {})
			}
			assert C.fcntl(fd, C.F_GETFD, 0) < 0
			if !leased { owned.conn = none }
			if leased {
				assert <-finished
				owned.close_live_conn()
				owned.finish_worker()
				select {
					_ := <-finished {
						assert false
					}
					else {
					}
				}
			}
		}
	}
}

fn test_rejected_transform_response_cleans_attached_owner_before_return() {
	mut owned, fd, finished := transform_owned_outcome(true, .response)
	defer {
		owned.close_live_conn()
		owned.finish_worker()
	}
	mut app := App{}
	transform_route_publish(mut app, TransformRouteExecutor{
		call_fn: fn [owned] (_ executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
			return owned
		}
	}, false)
	mut services := noop_dispatch_services('trace')
	mut exchange := transform_route_exchange()
	result := app.run_transform_refs(['last'], mut services, mut exchange)!
	assert result.halted
	assert result.action.kind == .reject
	assert result.action.status == 503
	assert C.fcntl(fd, C.F_GETFD, 0) < 0
	assert <-finished
}

fn test_standalone_event_dispatch_transfers_result_ownership_to_its_caller() {
	mut owned, fd, finished := transform_owned_outcome(true, .stream)
	defer {
		owned.close_live_conn()
		owned.finish_worker()
	}
	mut app := App{}
	transform_route_publish(mut app, TransformRouteExecutor{
		call_fn: fn [owned] (_ executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
			return owned
		}
	}, false)
	mut result := app.dispatch_vjsx_event(VjsxEventDispatchRequest{ event: 'event', handler: 'handler' })!
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
	select {
		_ := <-finished {
			assert false
		}
		else {
		}
	}
	result.close_live_conn()
	result.finish_worker()
	assert C.fcntl(fd, C.F_GETFD, 0) < 0
	assert <-finished
}
