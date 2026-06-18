module main

import dbx

$if enable_db ? {
	fn (mut app App) db_runtime_ensure_pool() ! {
		app.mu.@lock()
		settings := app.transport.db.pool_settings_if_needed() or {
			app.mu.unlock()
			if err.msg() == 'pool_ready' {
				return
			}
			return err
		}
		app.mu.unlock()
		mut pool := dbx.PoolHandle.open(settings)!
		app.mu.@lock()
		installed := app.transport.db.install_pool_if_missing(pool)
		if !installed {
			app.mu.unlock()
			pool.close()
			return
		}
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_release_conn(conn dbx.SessionHandle, session_id string) {
		if session_id != '' {
			return
		}
		app.mu.@lock()
		pool_ready, mut pool := app.transport.db.pool_handle()
		app.mu.unlock()
		if pool_ready {
			pool.release(conn)
		}
	}

	fn (mut app App) db_runtime_release_failed_conn(mut conn dbx.SessionHandle, session_id string, message string) {
		if !dbx.is_connection_lost_error(message) {
			app.db_runtime_release_conn(conn, session_id)
			return
		}
		if session_id != '' {
			app.mu.@lock()
			pool_ready, _ := app.transport.db.detach_transaction(session_id)
			app.mu.unlock()
			if pool_ready {
				app.db_runtime_discard_conn(mut conn)
			} else {
				conn.close() or {}
			}
			return
		}
		app.db_runtime_discard_conn(mut conn)
	}

	fn (mut app App) db_runtime_acquire_conn(session_id string) !dbx.SessionHandle {
		app.db_runtime_ensure_pool()!
		if session_id != '' {
			app.mu.@lock()
			conn := app.transport.db.transaction_session(session_id) or {
				app.mu.unlock()
				return error('invalid_session')
			}
			app.mu.unlock()
			return conn
		}
		app.mu.@lock()
		_, mut pool := app.transport.db.pool_handle()
		app.mu.unlock()
		return pool.acquire()!
	}

	fn (mut app App) db_runtime_discard_conn(mut conn dbx.SessionHandle) {
		conn.close() or {}
		app.mu.@lock()
		pool_ready, _ := app.transport.db.pool_handle()
		settings := app.transport.db.single_connection_settings()
		app.mu.unlock()
		if !pool_ready {
			return
		}
		replacement := dbx.PoolHandle.open(settings) or {
			app.db_runtime_note_error(err.msg())
			return
		}
		mut replacement_pool := replacement
		mut replacement_session := replacement_pool.acquire() or {
			replacement_pool.close()
			app.db_runtime_note_error(err.msg())
			return
		}
		replacement_pool.close()
		app.mu.@lock()
		still_ready, mut pool := app.transport.db.pool_handle()
		app.mu.unlock()
		if still_ready {
			pool.release(replacement_session)
			return
		}
		replacement_session.close() or {}
	}

	fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn dbx.SessionHandle, reusable bool) ! {
		app.mu.@lock()
		pool_ready, mut pool := app.transport.db.detach_transaction(session_id)
		app.mu.unlock()
		if reusable {
			conn.reset_for_pool() or {
				app.db_runtime_discard_conn(mut conn)
				return err
			}
			if pool_ready {
				pool.release(conn)
			} else {
				conn.close() or {}
			}
			return
		}
		conn.reset_for_pool() or {}
		app.db_runtime_discard_conn(mut conn)
	}

	fn (mut app App) db_runtime_cleanup_sessions() {
		app.mu.@lock()
		mut sessions := app.transport.db.drain_sessions()
		app.mu.unlock()
		for mut conn in sessions {
			conn.reset_for_pool() or {}
			conn.close() or {}
		}
	}

	fn (mut app App) db_runtime_close_pool() {
		app.mu.@lock()
		pool_ready, mut pool := app.transport.db.detach_pool()
		app.mu.unlock()
		if pool_ready {
			pool.close()
		}
	}
}

$if !enable_db ? {
	fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn dbx.SessionHandle, reusable bool) ! {
		_ = session_id
		_ = reusable
		_ = conn
		app.mu.@lock()
		app.transport.db.clear_transaction_count()
		app.mu.unlock()
	}
}
