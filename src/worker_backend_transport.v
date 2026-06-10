module main

import transport
import ws
import json
import log
import net.unix
import time
import worker


struct WorkerWebSocketDispatchCommandRuntime {}

struct WorkerBackendDispatchRuntime {}

struct WorkerBackendConnectorRuntime {}

struct WorkerBackendConnectorContext {
	select_socket_fn fn () !string                  = unsafe { nil }
	emit_fn          fn (string, map[string]string) = unsafe { nil }
}

fn (ctx WorkerBackendConnectorContext) select_socket() !string {
	return ctx.select_socket_fn()
}

fn (ctx WorkerBackendConnectorContext) emit(kind string, fields map[string]string) {
	ctx.emit_fn(kind, fields)
}

struct WorkerBackendDispatchContext {
	open_fn    fn () !worker.WorkerBackendConnection = unsafe { nil }
	start_fn   fn (string)                    = unsafe { nil }
	finish_fn  fn (string)                    = unsafe { nil }
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

fn (mut app App) worker_backend_open_connection() !worker.WorkerBackendConnection {
	ctx := app.build_worker_backend_connector_context()
	socket_path, conn := WorkerBackendConnectorRuntime.connect_selected(ctx)!
	return worker.WorkerBackendConnection.from_selected(socket_path, conn)
}

fn (mut app App) build_worker_backend_connector_context() WorkerBackendConnectorContext {
	return WorkerBackendConnectorContext{
		select_socket_fn: fn [mut app] () !string {
			return app.worker_backend_select_socket_queued()
		}
		emit_fn:          fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
	}
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
		timeout_ms: app.worker.worker_backend.read_timeout_ms
	}
}

fn WorkerWebSocketDispatchCommandRuntime.execute(rt ws.RuntimeContext, commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	mut close_frame := transport.WorkerWebSocketFrame{}
	mut has_close := false
	mut failures := []transport.WorkerWebSocketDispatchCommandFailure{}
	for cmd in commands {
		if cmd.event == 'close' && cmd.target_id == '' {
			close_frame = cmd
			has_close = true
			continue
		}
		if failure := rt.process_worker_frame(cmd) {
			failures << failure
		}
	}
	return transport.WorkerWebSocketDispatchCommandsResult{
		close_frame: close_frame
		has_close:   has_close
		failures:    failures
	}
}

fn WorkerWebSocketDispatchCommandRuntime.first_close(result transport.WorkerWebSocketDispatchCommandsResult) ?transport.WorkerWebSocketFrame {
	if result.has_close {
		return result.close_frame
	}
	return none
}

fn WorkerBackendConnectorRuntime.socket_with_retry(ctx WorkerBackendConnectorContext) !string {
	mut last_err := 'worker unavailable'
	for attempt in 0 .. 10 {
		socket_path := ctx.select_socket() or {
			last_err = err.msg()
			if last_err.contains('worker queue full') || last_err.contains('worker queue timeout') {
				return error(last_err)
			}
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		return socket_path
	}
	return error(last_err)
}

fn WorkerBackendConnectorRuntime.connect_selected(ctx WorkerBackendConnectorContext) !(string, unix.StreamConn) {
	mut last_err := 'worker connect failed'
	for attempt in 0 .. 10 {
		socket_path := WorkerBackendConnectorRuntime.socket_with_retry(ctx) or {
			last_err = err.msg()
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		mut conn := unix.connect_stream(socket_path) or {
			last_err = err.msg()
			ctx.emit('worker.connect.failed', {
				'socket':  socket_path
				'attempt': '${attempt + 1}'
				'error':   last_err
			})
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		return socket_path, *conn
	}
	return error(last_err)
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

fn (mut app App) worker_backend_connect_socket_with_retry() !string {
	ctx := app.build_worker_backend_connector_context()
	return WorkerBackendConnectorRuntime.socket_with_retry(ctx)
}

fn (mut app App) worker_backend_connect_selected() !(string, unix.StreamConn) {
	ctx := app.build_worker_backend_connector_context()
	return WorkerBackendConnectorRuntime.connect_selected(ctx)
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

fn (mut app App) execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	websocket_runtime := app.build_websocket_runtime_context()
	return WorkerWebSocketDispatchCommandRuntime.execute(websocket_runtime, commands)
}

fn (mut app App) execute_websocket_dispatch_commands(commands []transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketFrame {
	result := app.execute_websocket_dispatch_commands_result(commands)
	return WorkerWebSocketDispatchCommandRuntime.first_close(result)
}
