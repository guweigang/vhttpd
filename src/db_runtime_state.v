module main

import dbx
import net.unix

$if !enable_db ? {
	fn db_runtime_state_import_anchor(_ dbx.SessionHandle, _ &unix.StreamListener) {}
}

$if enable_db ? {
	pub fn (mut app App) db_runtime_snapshot() string {
		ready := app.provider_enabled('db')
		app.mu.@lock()
		defer {
			app.mu.unlock()
		}
		return app.transport.db.snapshot_json(ready)
	}

	fn (mut app App) db_runtime_driver() string {
		app.mu.@lock()
		driver := app.transport.db.driver_name()
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_accepts_pool(name string) bool {
		app.mu.@lock()
		accepted := app.transport.db.accepts_pool(name)
		app.mu.unlock()
		return accepted
	}

	fn (mut app App) db_runtime_note_error(message string) {
		app.mu.@lock()
		app.transport.db.note_error(message)
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_note_query_success() string {
		app.mu.@lock()
		driver := app.transport.db.note_query_success()
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_note_execute_success() string {
		app.mu.@lock()
		driver := app.transport.db.note_execute_success()
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_note_query_observation(op string, req dbx.Request, duration_ms i64, ok bool, message string) string {
		app.mu.@lock()
		driver := app.transport.db.note_query_observation(op, req, duration_ms, ok, message)
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_next_session_id() string {
		app.mu.@lock()
		session_id := app.transport.db.next_session_id()
		app.mu.unlock()
		return session_id
	}

	fn (mut app App) db_runtime_track_transaction(session_id string, conn dbx.SessionHandle) string {
		app.mu.@lock()
		driver := app.transport.db.track_transaction(session_id, conn)
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_mark_started(started_at_unix i64, listener &unix.StreamListener) string {
		app.mu.@lock()
		driver := app.transport.db.mark_started(started_at_unix, listener)
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_mark_stopped() {
		app.mu.@lock()
		app.transport.db.mark_stopped()
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_stop_requested() bool {
		app.mu.@lock()
		stop_requested := app.transport.db.stop_requested_flag()
		app.mu.unlock()
		return stop_requested
	}
}

$if !enable_db ? {
	pub fn (mut app App) db_runtime_snapshot() string {
		app.mu.@lock()
		defer {
			app.mu.unlock()
		}
		return app.transport.db.snapshot_json(false)
	}
}
