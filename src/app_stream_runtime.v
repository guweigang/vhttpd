module main

import upstream.transport
import executor
import dispatch
import veb
import net.unix
import worker

// Application assembly boundary for stream dispatch and response rendering.
struct StreamDispatchHost {
	snapshot WorkerBackendRequestSnapshot
}

fn (mut host StreamDispatchHost) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return worker.DispatchRuntime.stream(host.snapshot.dispatch_context(), req)
}

fn (mut app App) build_stream_runtime_context() StreamRuntimeContext {
	app.mu.@lock()
	state := app.engines.primary
	app.mu.unlock()
	return app.build_stream_runtime_context_for_state(state)
}

fn (mut app App) build_stream_runtime_context_for_state(state &worker.WorkerState) StreamRuntimeContext {
	port := executor.logic_executor_stream_port(state.logic_executor)
	mut host := StreamDispatchHost{ snapshot: new_worker_backend_request_snapshot(state, app.build_engine_lifecycle_port()) }
	mut facade := app.as_facade()
	return StreamRuntimeContext{
		render_open_failure_fn: fn [mut app] (mut ctx Context, req HttpIngressRequest, failure executor.KernelStreamDispatchFailure) veb.Result {
			return HttpStreamRuntime.render_open_failure(mut app, mut ctx, req, failure)
		}
		emit_fn:                fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		dispatch_open_fn:       fn [port, mut facade, mut host] (method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
			return port.dispatch_stream_with_worker_port(mut facade, mut host, dispatch.build_stream_open_request(method, path, body, remote_addr, req_id, trace_id, query, headers))
		}
		dispatch_next_fn:       fn [port, mut facade, mut host] (method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
			return port.dispatch_stream_with_worker_port(mut facade, mut host, dispatch.build_stream_next_request(method, path, remote_addr, req_id, trace_id, query, headers, state))
		}
		dispatch_close_fn:      fn [port, mut facade, mut host] (req_id string, trace_id string, state map[string]string, reason string) !transport.StreamDispatchResponse {
			return port.dispatch_stream_with_worker_port(mut facade, mut host, dispatch.build_stream_close_request(req_id, trace_id, state, reason))
		}
	}
}

fn HttpStreamRuntime.via_dispatch(mut app App, mut ctx Context, selection EngineDispatchSelection, method string, path string, req_id string, trace_id string, remote_addr string) ?veb.Result {
	stream_runtime := app.build_stream_runtime_context_for_state(selection.state)
	return HttpStreamRuntime.dispatch(stream_runtime, mut ctx, method, path, req_id,
		trace_id, remote_addr)
}

fn HttpStreamRuntime.via_sse(mut app App, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	stream_runtime := app.build_stream_runtime_context()
	return HttpStreamRuntime.direct_sse(stream_runtime, mut ctx, mut conn, start, method, path,
		req_id, trace_id, start_ms)
}

fn HttpStreamRuntime.via_passthrough(mut app App, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	stream_runtime := app.build_stream_runtime_context()
	return HttpStreamRuntime.direct_passthrough(stream_runtime, mut ctx, mut conn, start, method,
		path, req_id, trace_id, start_ms)
}

fn HttpStreamRuntime.render_open_failure(mut app App, mut ctx Context, req HttpIngressRequest, failure executor.KernelStreamDispatchFailure) veb.Result {
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, req, dispatch.outcome_with_metadata(dispatch.response_outcome(500, {
		'content-type':          'text/plain; charset=utf-8'
		'x-vhttpd-error-class':  failure.error_class
		'x-vhttpd-stream-mode':  'dispatch'
		'x-vhttpd-stream-stage': 'open'
	}, 'Internal Server Error'), {
		'error_class':  failure.error_class
		'error':        failure.error
		'stream_mode':  'dispatch'
		'stream_stage': 'open'
	}), none)
}
