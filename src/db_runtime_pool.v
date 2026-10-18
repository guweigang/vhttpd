module main

import dbx

$if enable_db ? {
	fn (mut app App) db_runtime_ensure_pool() ! {
		app.db_runtime_ensure_pool_with(dbx.PoolFactory.native())!
	}

	fn (mut app App) db_runtime_ensure_pool_with(factory dbx.PoolFactory) ! {
		app.mu.@lock()
		settings := app.transport.db.settings()
		mut owner := app.transport.db.pool_owner
		app.mu.unlock()
		if !dbx.DriverName.capabilities(settings.driver).pool { return error('unsupported_driver') }
		owner.ensure(settings, factory)!
	}

	fn (mut app App) db_runtime_release_conn(mut lease dbx.ConnectionLease) {
		lease.release_to_pool()
	}

	fn (mut app App) db_runtime_release_failed_conn(mut lease dbx.ConnectionLease, message string) {
		if !dbx.is_connection_lost_error(message) {
			app.db_runtime_release_conn(mut lease)
			return
		}
		app.db_runtime_finalize_tx_session(mut lease, false) or {}
	}

	fn (mut app App) db_runtime_acquire_conn(session_id string, finalizing bool) !&dbx.ConnectionLease {
		if session_id != '' {
			app.mu.@lock()
			mut owner := app.transport.db.transaction_session(session_id) or {
				app.mu.unlock()
				return error('invalid_session')
			}
			app.mu.unlock()
			return owner.borrow(finalizing)!
		}
		app.db_runtime_ensure_pool()!
		app.mu.@lock()
		mut owner := app.transport.db.pool_owner
		app.mu.unlock()
		return owner.acquire()!
	}

	fn (mut app App) db_runtime_discard_conn(mut conn dbx.SessionHandle, lease &dbx.ConnectionLease) {
		driver := conn.driver
		lease.close_connection(mut conn)
		// PostgreSQL's native pool retires bad slots on release and replenishes on acquire.
		if driver != 'mysql' { return }
		lease.refill_pool() or {
			if err.msg() != 'db_stopping' && err.msg() != 'db_pool_unavailable' {
				app.db_runtime_note_error(err.msg())
			}
		}
	}

	fn (mut app App) db_runtime_finalize_tx_session(mut lease dbx.ConnectionLease, reusable bool) ! {
		mut conn := lease.retire() or { return }
		// Keep the entry registered and active until physical disposal finishes.
		defer {
			lease.finish_retirement()
			if owner := lease.transaction_owner() {
				app.mu.@lock()
				app.transport.db.detach_transaction(owner)
				app.mu.unlock()
			}
		}
		if reusable {
			conn.reset_for_pool() or {
				app.db_runtime_discard_conn(mut conn, lease)
				return err
			}
			lease.return_connection(conn)
			return
		}
		conn.rollback() or {}
		app.db_runtime_discard_conn(mut conn, lease)
	}

	fn (mut app App) db_runtime_cleanup_sessions() {
		app.mu.@lock()
		mut sessions := app.transport.db.drain_sessions()
		app.mu.unlock()
		// Close admission for every transaction before waiting for any borrower.
		for mut owner in sessions { owner.request_close() }
		for mut owner in sessions {
			if mut conn := owner.drain() {
				conn.rollback() or {}
				owner.close_connection(mut conn)
			}
		}
	}

	fn (mut app App) db_runtime_close_pool() {
		app.mu.@lock()
		mut owner := app.transport.db.pool_owner
		app.mu.unlock()
		owner.close()
	}
}
