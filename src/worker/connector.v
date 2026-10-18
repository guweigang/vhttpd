module worker

import net.unix
import time

pub struct ConnectorRuntime {}

pub struct ConnectorContext {
pub:
	select_socket_fn fn () !string                  @[required]
	connect_fn       fn (string) !&unix.StreamConn  @[required]
	release_fn       fn (string)                    @[required]
	emit_fn          fn (string, map[string]string) @[required]
}

pub fn (ctx ConnectorContext) select_socket() !string {
	return ctx.select_socket_fn()
}

pub fn (ctx ConnectorContext) emit(kind string, fields map[string]string) {
	ctx.emit_fn(kind, fields)
}

pub fn (ctx ConnectorContext) release(socket_path string) {
	ctx.release_fn(socket_path)
}

pub fn ConnectorRuntime.socket_with_retry(ctx ConnectorContext) !string {
	mut last_err := 'worker unavailable'
	for attempt in 0 .. 10 {
		socket_path := ctx.select_socket() or {
			last_err = err.msg()
			if last_err == 'worker_backend_stopping' || last_err.contains('worker queue full') || last_err.contains('worker queue timeout') {
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

pub fn ConnectorRuntime.connect_selected(ctx ConnectorContext) !(string, unix.StreamConn) {
	mut last_err := 'worker connect failed'
	for attempt in 0 .. 10 {
		// One attempt budget covers selection and dialing. Queue backpressure
		// already owns its wait/deadline and must return directly to the caller.
		socket_path := ctx.select_socket() or {
			last_err = err.msg()
			if last_err == 'worker_backend_stopping' || last_err.contains('worker queue full') || last_err.contains('worker queue timeout') {
				return error(last_err)
			}
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		mut conn := ctx.connect_fn(socket_path) or {
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
