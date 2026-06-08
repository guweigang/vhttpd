module main

import dbx
import net.unix

// ── Type aliases: main → db ──
type DbProviderRuntime = dbx.Runtime

// ══════════════════════════════════════════════════════════════════════
// enable_db implementation
// ══════════════════════════════════════════════════════════════════════

$if enable_db ? {
	// ── RuntimeContext builder ──

	fn (mut app App) build_db_runtime_context() dbx.RuntimeContext {
		return dbx.RuntimeContext{
			mark_listen_error_fn: fn [mut app] (message string) {
				app.mu.@lock()
				app.db_runtime.mark_listen_error(message)
				app.mu.unlock()
			}
			mark_started_fn:    fn [mut app] (started_at i64, listener &unix.StreamListener) string {
				app.mu.@lock()
				driver := app.db_runtime.mark_started(started_at, listener)
				app.mu.unlock()
				return driver
			}
			mark_stopped_fn:    fn [mut app] () {
				app.mu.@lock()
				app.db_runtime.mark_stopped()
				app.mu.unlock()
			}
			stop_requested_fn:  fn [mut app] () bool {
				app.mu.@lock()
				flag := app.db_runtime.stop_requested_flag()
				app.mu.unlock()
				return flag
			}
			note_error_fn:      fn [mut app] (message string) {
				app.db_runtime_note_error(message)
			}
			cleanup_sessions_fn: fn [mut app] () {
				app.db_runtime_cleanup_sessions()
			}
			close_pool_fn:      fn [mut app] () {
				app.db_runtime_close_pool()
			}
			build_server_ctx_fn: fn [mut app] () dbx.ServerContext {
				return app.build_db_runtime_server_context()
			}
			emit_started_fn:    fn [mut app] (socket string, driver string) {
				app.emit('db.started', {
					'socket': socket
					'driver': driver
				})
			}
			emit_error_fn:      fn [mut app] (socket string, error string) {
				app.emit('db.error', {
					'socket': socket
					'error':  error
				})
			}
		}
	}

	// ── ServerContext builder ──

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

	// ── Mutex-protected App method wrappers ──

	pub fn (mut app App) db_runtime_snapshot() string {
		ready := app.provider_enabled('db')
		app.mu.@lock()
		defer {
			app.mu.unlock()
		}
		return app.db_runtime.snapshot_json(ready)
	}

	fn (mut app App) db_runtime_driver() string {
		app.mu.@lock()
		driver := app.db_runtime.driver_name()
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_note_error(message string) {
		app.mu.@lock()
		app.db_runtime.note_error(message)
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_note_query_success() string {
		app.mu.@lock()
		driver := app.db_runtime.note_query_success()
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_note_execute_success() string {
		app.mu.@lock()
		driver := app.db_runtime.note_execute_success()
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_next_session_id() string {
		app.mu.@lock()
		session_id := app.db_runtime.next_session_id()
		app.mu.unlock()
		return session_id
	}

	fn (mut app App) db_runtime_track_transaction(session_id string, conn dbx.SessionHandle) string {
		app.mu.@lock()
		driver := app.db_runtime.track_transaction(session_id, conn)
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_mark_started(started_at_unix i64, listener &unix.StreamListener) string {
		app.mu.@lock()
		driver := app.db_runtime.mark_started(started_at_unix, listener)
		app.mu.unlock()
		return driver
	}

	fn (mut app App) db_runtime_mark_stopped() {
		app.mu.@lock()
		app.db_runtime.mark_stopped()
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_stop_requested() bool {
		app.mu.@lock()
		stop_requested := app.db_runtime.stop_requested_flag()
		app.mu.unlock()
		return stop_requested
	}

	fn (mut app App) db_runtime_ensure_pool() ! {
		app.mu.@lock()
		settings := app.db_runtime.pool_settings_if_needed() or {
			app.mu.unlock()
			if err.msg() == 'pool_ready' {
				return
			}
			return err
		}
		app.mu.unlock()
		mut pool := dbx.PoolHandle.open(settings)!
		app.mu.@lock()
		installed := app.db_runtime.install_pool_if_missing(pool)
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
		pool_ready, mut pool := app.db_runtime.pool_handle()
		app.mu.unlock()
		if pool_ready {
			pool.release(conn)
		}
	}

	fn (mut app App) db_runtime_acquire_conn(session_id string) !dbx.SessionHandle {
		app.db_runtime_ensure_pool()!
		if session_id != '' {
			app.mu.@lock()
			conn := app.db_runtime.transaction_session(session_id) or {
				app.mu.unlock()
				return error('invalid_session')
			}
			app.mu.unlock()
			return conn
		}
		app.mu.@lock()
		_, mut pool := app.db_runtime.pool_handle()
		app.mu.unlock()
		return pool.acquire()!
	}

	fn (mut app App) db_runtime_discard_conn(mut conn dbx.SessionHandle) {
		conn.close() or {}
		app.mu.@lock()
		pool_ready, _ := app.db_runtime.pool_handle()
		settings := app.db_runtime.single_connection_settings()
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
		still_ready, mut pool := app.db_runtime.pool_handle()
		app.mu.unlock()
		if still_ready {
			pool.release(replacement_session)
			return
		}
		replacement_session.close() or {}
	}

	fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn dbx.SessionHandle, reusable bool) ! {
		app.mu.@lock()
		pool_ready, mut pool := app.db_runtime.detach_transaction(session_id)
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
		mut sessions := app.db_runtime.drain_sessions()
		app.mu.unlock()
		for mut conn in sessions {
			conn.reset_for_pool() or {}
			conn.close() or {}
		}
	}

	fn (mut app App) db_runtime_close_pool() {
		app.mu.@lock()
		pool_ready, mut pool := app.db_runtime.detach_pool()
		app.mu.unlock()
		if pool_ready {
			pool.close()
		}
	}

	fn (mut app App) db_runtime_dispatch(req dbx.Request) dbx.Response {
		driver := app.db_runtime_driver()
		if req.mode != 'db' {
			return dbx.Response.error(driver, 'invalid_mode')
		}
		return match req.op {
			'ping' {
				app.db_runtime_ensure_pool() or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				mut conn := app.db_runtime_acquire_conn('') or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				defer {
					app.db_runtime_release_conn(conn, '')
				}
				conn.ping() or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				dbx.Response.pong(driver)
			}
			'begin_transaction' {
				mut conn := app.db_runtime_acquire_conn('') or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				conn.begin() or {
					conn.reset_for_pool() or {}
					app.db_runtime_release_conn(conn, '')
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				session_id := app.db_runtime_next_session_id()
				driver_name := app.db_runtime_track_transaction(session_id, conn)
				dbx.Response.transaction_started(driver_name, session_id)
			}
			'commit' {
				if req.session_id.trim_space() == '' {
					dbx.Response.ok(driver)
				} else {
					mut conn := app.db_runtime_acquire_conn(req.session_id) or {
						app.db_runtime_note_error(err.msg())
						return dbx.Response.error(driver, err.msg())
					}
					conn.commit() or {
						app.db_runtime_finalize_tx_session(req.session_id, mut conn, false) or {}
						app.db_runtime_note_error(err.msg())
						return dbx.Response.error(driver, err.msg())
					}
					app.db_runtime_finalize_tx_session(req.session_id, mut conn, true) or {
						app.db_runtime_note_error(err.msg())
						return dbx.Response.error(driver, err.msg())
					}
					dbx.Response.ok(driver)
				}
			}
			'rollback' {
				if req.session_id.trim_space() == '' {
					dbx.Response.ok(driver)
				} else {
					mut conn := app.db_runtime_acquire_conn(req.session_id) or {
						app.db_runtime_note_error(err.msg())
						return dbx.Response.error(driver, err.msg())
					}
					conn.rollback() or {
						app.db_runtime_finalize_tx_session(req.session_id, mut conn, false) or {}
						app.db_runtime_note_error(err.msg())
						return dbx.Response.error(driver, err.msg())
					}
					app.db_runtime_finalize_tx_session(req.session_id, mut conn, true) or {
						app.db_runtime_note_error(err.msg())
						return dbx.Response.error(driver, err.msg())
					}
					dbx.Response.ok(driver)
				}
			}
			'query' {
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				query_result := conn.query(req.sql_text, req.params) or {
					app.db_runtime_release_conn(conn, req.session_id)
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				app.db_runtime_release_conn(conn, req.session_id)
				driver_name := app.db_runtime_note_query_success()
				dbx.Response.query_result(driver_name, query_result, req.session_id)
			}
			'execute' {
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				exec_result := conn.execute(req.sql_text, req.params) or {
					app.db_runtime_release_conn(conn, req.session_id)
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				app.db_runtime_release_conn(conn, req.session_id)
				driver_name := app.db_runtime_note_execute_success()
				dbx.Response.exec_result(driver_name, exec_result, req.session_id)
			}
			else {
				dbx.Response.error(driver, 'unsupported_op')
			}
		}
	}

	// ── Server entry point ──

	fn (mut app App) db_runtime_server_run(socket_path string) {
		ctx := app.build_db_runtime_context()
		dbx.Server.run(ctx, socket_path)
	}
}

// ══════════════════════════════════════════════════════════════════════
// !enable_db stub implementation
// ══════════════════════════════════════════════════════════════════════

$if !enable_db ? {
	pub fn (mut app App) db_runtime_snapshot() string {
		app.mu.@lock()
		defer {
			app.mu.unlock()
		}
		return app.db_runtime.snapshot_json(false)
	}

	fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn dbx.SessionHandle, reusable bool) ! {
		_ = session_id
		_ = reusable
		_ = conn
		app.mu.@lock()
		app.db_runtime.clear_transaction_count()
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_dispatch(req dbx.Request) dbx.Response {
		driver := dbx.DriverName.normalize(app.db_runtime.driver_name())
		if req.mode != 'db' {
			return dbx.Response.error(driver, 'invalid_mode')
		}
		return dbx.Response.error(driver, 'db_not_compiled')
	}

	fn (mut app App) db_runtime_server_run(socket_path string) {
		ctx := dbx.RuntimeContext{
			mark_listen_error_fn: fn [mut app] (message string) {
				app.mu.@lock()
				app.db_runtime.mark_not_compiled()
				app.mu.unlock()
			}
			emit_error_fn: fn [mut app] (socket string, error string) {
				app.emit('db.error', {
					'socket': socket
					'error':  error
				})
			}
			mark_started_fn:    fn (_ i64, _ &unix.StreamListener) string { return '' }
			mark_stopped_fn:    fn () {}
			stop_requested_fn:  fn () bool { return false }
			note_error_fn:      fn (_ string) {}
			cleanup_sessions_fn: fn () {}
			close_pool_fn:      fn () {}
			build_server_ctx_fn: fn () dbx.ServerContext { return dbx.ServerContext{} }
			emit_started_fn:    fn (_ string, _ string) {}
		}
		dbx.Server.run(ctx, socket_path)
	}
}
