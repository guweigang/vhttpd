module main

import dbx

$if enable_db ? {
	import time
}

$if enable_db ? {
	fn (mut app App) db_runtime_dispatch(req dbx.Request) dbx.Response {
		driver := app.db_runtime_driver()
		if req.mode != 'db' {
			return dbx.Response.error(driver, 'invalid_mode')
		}
		if !app.db_runtime_accepts_pool(req.pool) {
			message := 'unknown_pool:${req.pool}'
			app.db_runtime_note_error(message)
			return dbx.Response.error(driver, message)
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
				conn.ping() or {
					err_msg := err.msg()
					if dbx.is_connection_lost_error(err_msg) {
						app.db_runtime_discard_conn(mut conn)
						mut retry_conn := app.db_runtime_acquire_conn('') or {
							app.db_runtime_note_error(err.msg())
							return dbx.Response.error(driver, err.msg())
						}
						retry_conn.ping() or {
							retry_err := err.msg()
							app.db_runtime_release_failed_conn(mut retry_conn, '', retry_err)
							app.db_runtime_note_error(retry_err)
							return dbx.Response.error(driver, retry_err)
						}
						app.db_runtime_release_conn(retry_conn, '')
						return dbx.Response.pong(driver)
					}
					app.db_runtime_note_error(err_msg)
					return dbx.Response.error(driver, err_msg)
				}
				app.db_runtime_release_conn(conn, '')
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
				start_ms := time.now().unix_milli()
				params := req.decoded_params()
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_query_observation('query', req,
						time.now().unix_milli() - start_ms, false, err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				query_result := conn.query(req.sql_text, params) or {
					err_msg := err.msg()
					app.db_runtime_release_failed_conn(mut conn, req.session_id, err_msg)
					if req.session_id.trim_space() == '' && dbx.is_connection_lost_error(err_msg) {
						mut retry_conn := app.db_runtime_acquire_conn('') or {
							app.db_runtime_note_query_observation('query', req,
								time.now().unix_milli() - start_ms, false, err.msg())
							return dbx.Response.error(driver, err.msg())
						}
						retry_result := retry_conn.query(req.sql_text, params) or {
							retry_err := err.msg()
							app.db_runtime_release_failed_conn(mut retry_conn, '', retry_err)
							app.db_runtime_note_query_observation('query', req,
								time.now().unix_milli() - start_ms, false, retry_err)
							return dbx.Response.error(driver, retry_err)
						}
						app.db_runtime_release_conn(retry_conn, '')
						driver_name := app.db_runtime_note_query_observation('query', req,
							time.now().unix_milli() - start_ms, true, '')
						return dbx.Response.query_result(driver_name, retry_result, req.session_id)
					}
					app.db_runtime_note_query_observation('query', req,
						time.now().unix_milli() - start_ms, false, err_msg)
					return dbx.Response.error(driver, err_msg)
				}
				app.db_runtime_release_conn(conn, req.session_id)
				driver_name := app.db_runtime_note_query_observation('query', req,
					time.now().unix_milli() - start_ms, true, '')
				dbx.Response.query_result(driver_name, query_result, req.session_id)
			}
			'escape' {
				params := req.decoded_params()
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				value := if params.len > 0 { params[0] } else { req.sql_text }
				escaped := conn.escape(value) or {
					err_msg := err.msg()
					app.db_runtime_release_failed_conn(mut conn, req.session_id, err_msg)
					if req.session_id.trim_space() == '' && dbx.is_connection_lost_error(err_msg) {
						mut retry_conn := app.db_runtime_acquire_conn('') or {
							app.db_runtime_note_error(err.msg())
							return dbx.Response.error(driver, err.msg())
						}
						retry_escaped := retry_conn.escape(value) or {
							retry_err := err.msg()
							app.db_runtime_release_failed_conn(mut retry_conn, '', retry_err)
							app.db_runtime_note_error(retry_err)
							return dbx.Response.error(driver, retry_err)
						}
						app.db_runtime_release_conn(retry_conn, '')
						return dbx.Response.escaped(driver, retry_escaped, req.session_id)
					}
					app.db_runtime_note_error(err_msg)
					return dbx.Response.error(driver, err_msg)
				}
				app.db_runtime_release_conn(conn, req.session_id)
				dbx.Response.escaped(driver, escaped, req.session_id)
			}
			'execute' {
				start_ms := time.now().unix_milli()
				params := req.decoded_params()
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_query_observation('execute', req,
						time.now().unix_milli() - start_ms, false, err.msg())
					return dbx.Response.error(driver, err.msg())
				}
				exec_result := conn.execute(req.sql_text, params) or {
					err_msg := err.msg()
					app.db_runtime_release_failed_conn(mut conn, req.session_id, err_msg)
					app.db_runtime_note_query_observation('execute', req,
						time.now().unix_milli() - start_ms, false, err_msg)
					return dbx.Response.error(driver, err_msg)
				}
				app.db_runtime_release_conn(conn, req.session_id)
				driver_name := app.db_runtime_note_query_observation('execute', req,
					time.now().unix_milli() - start_ms, true, '')
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
