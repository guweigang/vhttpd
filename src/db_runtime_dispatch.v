module main

import dbx

$if enable_db ? {
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
}

$if !enable_db ? {
	fn (mut app App) db_runtime_dispatch(req dbx.Request) dbx.Response {
		driver := dbx.DriverName.normalize(app.transport.db.driver_name())
		if req.mode != 'db' {
			return dbx.Response.error(driver, 'invalid_mode')
		}
		return dbx.Response.error(driver, 'db_not_compiled')
	}
}
