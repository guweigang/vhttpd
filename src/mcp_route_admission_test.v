module main

import executor
import worker
import upstream.transport
import time

struct RouteMetadataExecutor {
	executor.DisabledLogicExecutor
	label       string
	metadata_fn fn () string @[required]
}

fn (e RouteMetadataExecutor) provider() string { return e.metadata_fn() }

fn (e RouteMetadataExecutor) dispatch_mcp(mut _ executor.AppFacade, _ transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return transport.WorkerMcpDispatchResponse{ handled: true, body: e.label }
}

fn route_metadata_publish(mut app App, value executor.LogicExecutor) {
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ logic_executor: value } }
	app.mu.unlock()
}

fn route_metadata_wait(done chan bool) {
	select {
		_ := <-done {
		}
		2 * time.second {
			panic('MCP metadata held the publication lock')
		}
	}
}

fn test_mcp_metadata_reentry_preserves_captured_executor_and_provider() {
	mut app := &App{}
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'old'
		metadata_fn: fn [mut app] () string {
			route_metadata_publish(mut app, executor.DisabledLogicExecutor{})
			return 'old-provider'
		}
	})
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		route := app.mcp_dispatch_route('') or { panic(err) }
		assert route.provider == 'old-provider'
		assert (route.call_fn(transport.WorkerMcpDispatchRequest{}) or { panic(err) }).body == 'old'
		assert app.engine_runtime_snapshot().primary_kind() == 'none'
		done <- true
	}()
	route_metadata_wait(done)
}

fn test_blocked_mcp_metadata_allows_concurrent_runtime_publication() {
	mut app := &App{}
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'old'
		metadata_fn: fn [entered, release] () string {
			entered <- true
			_ := <-release
			return 'old-provider'
		}
	})
	spawn fn [mut app, done] () {
		route := app.mcp_dispatch_route('') or { panic(err) }
		assert route.provider == 'old-provider'
		assert (route.call_fn(transport.WorkerMcpDispatchRequest{}) or { panic(err) }).body == 'old'
		done <- true
	}()
	route_metadata_wait(entered)
	published := chan bool{cap: 1}
	spawn fn [mut app, published] () {
		route_metadata_publish(mut app, executor.DisabledLogicExecutor{})
		published <- true
	}()
	route_metadata_wait(published)
	release <- true
	route_metadata_wait(done)
}

fn test_bound_missing_and_stopped_mcp_routes_skip_current_executor_metadata() {
	mut app := &App{}
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'old'
		metadata_fn: fn () string {
			return 'old-provider'
		}
	})
	original := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('bound', '', '', '', '', original, false) or { panic(err) }
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'new'
		metadata_fn: fn () string {
			panic('unrelated metadata callback invoked')
		}
	})
	retained := app.mcp_dispatch_route('bound') or { panic(err) }
	assert voidptr(retained) == voidptr(original)
	assert (retained.call_fn(transport.WorkerMcpDispatchRequest{}) or { panic(err) }).body == 'old'
	if _ := app.mcp_dispatch_route('missing') {
		assert false
	} else {
		assert err.msg() == 'mcp_session_unavailable'
	}
	app.protocols.mcp.request_stop()
	if _ := app.mcp_dispatch_route('') {
		assert false
	} else {
		assert err.msg() == 'mcp_stopping'
	}
}

fn test_mcp_shutdown_during_metadata_rejects_candidate() {
	mut app := &App{}
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'candidate'
		metadata_fn: fn [mut app] () string {
			app.protocols.mcp.request_stop()
			return 'candidate'
		}
	})
	if _ := app.mcp_dispatch_route('') {
		assert false
	} else {
		assert err.msg() == 'mcp_stopping'
	}
	assert app.protocols.mcp.sessions.len == 0
}

fn test_mcp_retirement_during_metadata_does_not_bind_unbound_session() {
	mut app := &App{}
	app.protocols.mcp.ensure_session('legacy', '', '', '', '')
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'candidate'
		metadata_fn: fn [mut app] () string {
			mut state := app.engine_runtime_snapshot().primary
			state.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
			return 'candidate'
		}
	})
	if _ := app.mcp_dispatch_route('legacy') {
		assert false
	} else {
		assert err.msg() == 'mcp_session_unavailable'
	}
	assert app.protocols.mcp.sessions['legacy'].dispatch == none
}

fn test_mcp_deleted_unbound_session_cannot_be_restored_after_metadata() {
	mut app := &App{}
	app.protocols.mcp.ensure_session('legacy', '', '', '', '')
	route_metadata_publish(mut app, RouteMetadataExecutor{
		label:       'candidate'
		metadata_fn: fn [mut app] () string {
			app.protocols.mcp.delete_session('legacy')
			return 'candidate'
		}
	})
	if _ := app.mcp_dispatch_route('legacy') {
		assert false
	} else {
		assert err.msg() == 'mcp_session_unavailable'
	}
	assert 'legacy' !in app.protocols.mcp.sessions
}
