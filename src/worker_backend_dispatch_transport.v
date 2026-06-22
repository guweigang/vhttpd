module main

import upstream.transport
import json
import log
import worker

struct WorkerBackendDispatchRuntime {}

struct WorkerBackendDispatchContext {
	open_fn    fn () !worker.WorkerBackendConnection = unsafe { nil }
	start_fn   fn (string) = unsafe { nil }
	finish_fn  fn (string) = unsafe { nil }
	timeout_ms int
}

fn (ctx WorkerBackendDispatchContext) open() !worker.WorkerBackendConnection {
	return ctx.open_fn()
}

fn (ctx WorkerBackendDispatchContext) started(socket_path string) {
	ctx.start_fn(socket_path)
}

fn (ctx WorkerBackendDispatchContext) finished(socket_path string) {
	ctx.finish_fn(socket_path)
}

fn (mut app App) build_worker_backend_dispatch_context() WorkerBackendDispatchContext {
	return WorkerBackendDispatchContext{
		open_fn:    fn [mut app] () !worker.WorkerBackendConnection {
			return app.worker_backend_open_connection()
		}
		start_fn:   fn [mut app] (socket_path string) {
			app.on_worker_request_started(socket_path)
		}
		finish_fn:  fn [mut app] (socket_path string) {
			app.on_worker_request_finished(socket_path)
		}
		timeout_ms: app.engines.read_timeout_ms('')
	}
}

fn WorkerBackendDispatchRuntime.stream(ctx WorkerBackendDispatchContext, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	mut worker_conn := ctx.open()!
	ctx.started(worker_conn.socket_path)
	defer {
		ctx.finished(worker_conn.socket_path)
		worker_conn.close()
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	worker_conn.write_json(req)!
	return worker_conn.read_stream_response()!
}

fn WorkerBackendDispatchRuntime.mcp(ctx WorkerBackendDispatchContext, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut worker_conn := ctx.open()!
	ctx.started(worker_conn.socket_path)
	defer {
		ctx.finished(worker_conn.socket_path)
		worker_conn.close()
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	worker_conn.write_json(req)!
	return worker_conn.read_mcp_response()!
}

fn WorkerBackendDispatchRuntime.websocket_upstream(ctx WorkerBackendDispatchContext, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut worker_conn := ctx.open()!
	ctx.started(worker_conn.socket_path)
	defer {
		ctx.finished(worker_conn.socket_path)
		worker_conn.close()
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	raw_req := json.encode(req)
	log.info('[worker-transport] 📤 dispatching websocket_upstream: ${raw_req}')
	worker_conn.write_payload(raw_req)!
	return worker_conn.read_websocket_upstream_response()!
}

fn WorkerBackendDispatchRuntime.websocket_event(ctx WorkerBackendDispatchContext, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut worker_conn := ctx.open()!
	ctx.started(worker_conn.socket_path)
	defer {
		ctx.finished(worker_conn.socket_path)
		worker_conn.close()
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	worker_conn.write_websocket_frame(frame)!
	return worker_conn.read_websocket_dispatch_response()!
}

fn (mut app App) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return WorkerBackendDispatchRuntime.stream(ctx, req)
}

fn (mut app App) worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return WorkerBackendDispatchRuntime.mcp(ctx, req)
}

fn (mut app App) worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return WorkerBackendDispatchRuntime.websocket_upstream(ctx, req)
}

fn (mut app App) worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return WorkerBackendDispatchRuntime.websocket_event(ctx, frame)
}
