module main

import net.unix
import time
import worker

struct WorkerBackendConnectorRuntime {}

struct WorkerBackendConnectorContext {
	select_socket_fn fn () !string                  = unsafe { nil }
	release_fn       fn (string)                    = unsafe { nil }
	emit_fn          fn (string, map[string]string) = unsafe { nil }
}

fn (ctx WorkerBackendConnectorContext) select_socket() !string {
	return ctx.select_socket_fn()
}

fn (ctx WorkerBackendConnectorContext) emit(kind string, fields map[string]string) {
	ctx.emit_fn(kind, fields)
}

fn (ctx WorkerBackendConnectorContext) release(socket_path string) {
	ctx.release_fn(socket_path)
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
		release_fn:       fn [mut app] (socket_path string) {
			app.on_worker_request_released(socket_path)
		}
		emit_fn:          fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
	}
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
			ctx.release(socket_path)
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

fn (mut app App) worker_backend_connect_socket_with_retry() !string {
	ctx := app.build_worker_backend_connector_context()
	return WorkerBackendConnectorRuntime.socket_with_retry(ctx)
}

fn (mut app App) worker_backend_connect_selected() !(string, unix.StreamConn) {
	ctx := app.build_worker_backend_connector_context()
	return WorkerBackendConnectorRuntime.connect_selected(ctx)
}
