module main

import dbx
import net.unix

$if !enable_db ? {
	fn db_runtime_context_import_anchor(_ dbx.RuntimeContext, _ &unix.StreamListener) {}
}

$if enable_db ? {
	fn (mut app App) build_db_runtime_context() dbx.RuntimeContext {
		return dbx.RuntimeContext{
			mark_listen_error_fn: fn [mut app] (message string) {
				app.mu.@lock()
				app.transport.db.mark_listen_error(message)
				app.mu.unlock()
			}
			mark_started_fn:      fn [mut app] (started_at i64, listener &unix.StreamListener) string {
				app.mu.@lock()
				driver := app.transport.db.mark_started(started_at, listener)
				app.mu.unlock()
				return driver
			}
			mark_stopped_fn:      fn [mut app] () {
				app.mu.@lock()
				app.transport.db.mark_stopped()
				app.mu.unlock()
			}
			stop_requested_fn:    fn [mut app] () bool {
				app.mu.@lock()
				flag := app.transport.db.stop_requested_flag()
				app.mu.unlock()
				return flag
			}
			note_error_fn:        fn [mut app] (message string) {
				app.db_runtime_note_error(message)
			}
			cleanup_sessions_fn:  fn [mut app] () {
				app.db_runtime_cleanup_sessions()
			}
			close_pool_fn:        fn [mut app] () {
				app.db_runtime_close_pool()
			}
			build_server_ctx_fn:  fn [mut app] () dbx.ServerContext {
				return app.build_db_runtime_server_context()
			}
			emit_started_fn:      fn [mut app] (socket string, driver string) {
				app.emit('db.started', {
					'socket': socket
					'driver': driver
				})
			}
			emit_error_fn:        fn [mut app] (socket string, error string) {
				app.emit('db.error', {
					'socket': socket
					'error':  error
				})
			}
		}
	}

	fn (mut app App) build_db_runtime_server_context() dbx.ServerContext {
		return dbx.ServerContext{
			driver_fn:   fn [mut app] () string {
				return app.db_runtime_driver()
			}
			dispatch_fn: fn [mut app] (req dbx.Request) dbx.Response {
				return app.db_runtime_dispatch(req)
			}
		}
	}

	fn (mut app App) db_runtime_server_run(socket string) {
		ctx := app.build_db_runtime_context()
		dbx.Server.run(ctx, socket)
	}
}

$if !enable_db ? {
	fn (mut app App) db_runtime_server_run(socket string) {
		_ = socket
		app.mu.@lock()
		app.transport.db.mark_not_compiled()
		app.mu.unlock()
	}
}
