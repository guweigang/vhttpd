module main

import db.mysql
import db.pg

pub struct DbDriverCapabilities {
pub:
	pool         bool
	transactions bool
	parameters   bool
	prepared     bool
	savepoints   bool
}

pub struct DbQueryResult {
pub:
	columns []string
	rows    []map[string]string
}

pub struct DbExecResult {
pub:
	affected_rows      int
	last_insert_id     i64
	has_last_insert_id bool
}

pub struct DbPoolHandle {
pub mut:
	driver     string
	mysql_pool mysql.ConnectionPool
	pg_pool    pg.ConnectionPool
}

pub struct DbSessionHandle {
pub mut:
	driver     string
	mysql_conn mysql.DB
	pg_conn    pg.DB
}

fn normalize_db_driver_name(name string) string {
	driver := name.trim_space().to_lower()
	return match driver {
		'pg', 'postgres', 'postgresql' {
			'pgsql'
		}
		'mysql' {
			'mysql'
		}
		else {
			if driver != '' {
				driver
			} else {
				'mysql'
			}
		}
	}
}

fn db_driver_capabilities(name string) DbDriverCapabilities {
	return match normalize_db_driver_name(name) {
		'mysql' {
			DbDriverCapabilities{
				pool:         true
				transactions: true
				parameters:   true
				prepared:     true
				savepoints:   true
			}
		}
		'pgsql', 'pg', 'postgres', 'postgresql' {
			DbDriverCapabilities{
				pool:         true
				transactions: true
				parameters:   true
				prepared:     true
				savepoints:   true
			}
		}
		else {
			DbDriverCapabilities{}
		}
	}
}

fn db_open_pool(settings DbRuntimeSettings) !DbPoolHandle {
	driver := normalize_db_driver_name(settings.driver)
	host := if settings.host.trim_space() != '' { settings.host } else { '127.0.0.1' }
	default_port := if driver == 'pgsql' { 5432 } else { 3306 }
	port := u32(if settings.port > 0 { settings.port } else { default_port })
	default_database := if driver == 'pgsql' { 'postgres' } else { 'mysql' }
	database := if settings.database.trim_space() != '' {
		settings.database
	} else {
		default_database
	}
	pool_size := if settings.pool_size > 0 { settings.pool_size } else { 5 }
	return match driver {
		'mysql' {
			DbPoolHandle{
				driver:     'mysql'
				mysql_pool: mysql.new_connection_pool(mysql.Config{
					host:     host
					port:     port
					username: settings.username
					password: settings.password
					dbname:   database
				}, pool_size)!
			}
		}
		'pgsql', 'pg', 'postgres', 'postgresql' {
			DbPoolHandle{
				driver:  'pgsql'
				pg_pool: pg.new_connection_pool(pg.Config{
					host:     host
					port:     int(port)
					user:     settings.username
					password: settings.password
					dbname:   database
				}, pool_size)!
			}
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_pool_close(mut pool DbPoolHandle) {
	match pool.driver {
		'mysql' {
			pool.mysql_pool.close()
		}
		'pgsql' {
			pool.pg_pool.close()
		}
		else {}
	}
}

fn db_pool_acquire(mut pool DbPoolHandle) !DbSessionHandle {
	return match pool.driver {
		'mysql' {
			DbSessionHandle{
				driver:     'mysql'
				mysql_conn: pool.mysql_pool.acquire()!
			}
		}
		'pgsql' {
			DbSessionHandle{
				driver:  'pgsql'
				pg_conn: pool.pg_pool.acquire()!
			}
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_pool_release(mut pool DbPoolHandle, session DbSessionHandle) {
	match pool.driver {
		'mysql' {
			if session.driver == 'mysql' {
				pool.mysql_pool.release(session.mysql_conn)
			}
		}
		'pgsql' {
			if session.driver == 'pgsql' {
				pool.pg_pool.release(session.pg_conn)
			}
		}
		else {}
	}
}

fn db_session_close(mut session DbSessionHandle) ! {
	match session.driver {
		'mysql' {
			session.mysql_conn.close()!
		}
		'pgsql' {
			session.pg_conn.close()!
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_session_ping(mut session DbSessionHandle) !bool {
	return match session.driver {
		'mysql' {
			session.mysql_conn.ping()!
		}
		'pgsql' {
			rows := session.pg_conn.exec('select 1')!
			rows.len > 0
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_session_begin(mut session DbSessionHandle) ! {
	match session.driver {
		'mysql' {
			session.mysql_conn.autocommit(false)!
			session.mysql_conn.begin()!
		}
		'pgsql' {
			session.pg_conn.begin(pg.PQTransactionParam{})!
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_session_commit(mut session DbSessionHandle) ! {
	match session.driver {
		'mysql' {
			session.mysql_conn.commit()!
		}
		'pgsql' {
			session.pg_conn.commit()!
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_session_rollback(mut session DbSessionHandle) ! {
	match session.driver {
		'mysql' {
			session.mysql_conn.rollback()!
		}
		'pgsql' {
			session.pg_conn.rollback()!
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_session_reset_for_pool(mut session DbSessionHandle) ! {
	match session.driver {
		'mysql' {
			session.mysql_conn.autocommit(true)!
		}
		'pgsql' {
			// PostgreSQL connections can be returned to the pool after commit/rollback directly.
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn mysql_field_names_from_result(result mysql.Result) []string {
	field_count := result.n_fields()
	field_defs := C.mysql_fetch_fields(result.result)
	mut columns := []string{cap: field_count}
	for i in 0 .. field_count {
		columns << unsafe { cstring_to_vstring(field_defs[i].name) }
	}
	return columns
}

fn mysql_stmt_query_columns(mut conn mysql.DB, query string) ![]string {
	mut stmt := conn.init_stmt(query)
	defer {
		stmt.close() or {}
	}
	stmt.prepare()!
	metadata := stmt.gen_metadata()
	if metadata == unsafe { nil } {
		return []string{}
	}
	field_count := mysql.Result{
		result: metadata
	}.n_fields()
	field_defs := stmt.fetch_fields(metadata)
	mut columns := []string{cap: field_count}
	for i in 0 .. field_count {
		columns << unsafe { cstring_to_vstring(field_defs[i].name) }
	}
	C.mysql_free_result(metadata)
	return columns
}

fn mysql_stmt_query_rows(mut conn mysql.DB, query string, params []string) !DbQueryResult {
	columns := mysql_stmt_query_columns(mut conn, query) or { []string{} }
	stmt := conn.prepare(query)!
	defer {
		stmt.close()
	}
	response := stmt.execute(params)!
	mut rows := []map[string]string{}
	for response_row in response {
		mut item := map[string]string{}
		for i, value in response_row.vals {
			key := if i < columns.len && columns[i] != '' { columns[i] } else { '${i}' }
			item[key] = value
		}
		rows << item
	}
	return DbQueryResult{
		columns: columns
		rows:    rows
	}
}

fn db_result_column_key(columns []string, idx int) string {
	if idx >= 0 && idx < columns.len && columns[idx] != '' {
		return columns[idx]
	}
	return '${idx}'
}

fn db_session_query(mut session DbSessionHandle, query string, params []string) !DbQueryResult {
	return match session.driver {
		'mysql' {
			if params.len == 0 {
				mut result := session.mysql_conn.query(query)!
				rows := result.maps()
				columns := mysql_field_names_from_result(result)
				unsafe {
					result.free()
				}
				DbQueryResult{
					columns: columns
					rows:    rows
				}
			} else {
				mysql_stmt_query_rows(mut session.mysql_conn, query, params)!
			}
		}
		'pgsql' {
			mut result := pg.Result{}
			if params.len == 0 {
				result = session.pg_conn.exec_result(query)!
			} else {
				result = session.pg_conn.exec_param_many_result(query, params)!
			}
			mut columns := []string{len: result.cols.len}
			for name, idx in result.cols {
				if idx >= 0 && idx < columns.len {
					columns[idx] = name
				}
			}
			mut rows := []map[string]string{cap: result.rows.len}
			for row in result.rows {
				mut item := map[string]string{}
				for i, value in row.vals {
					key := db_result_column_key(columns, i)
					item[key] = value or { '' }
				}
				rows << item
			}
			DbQueryResult{
				columns: columns
				rows:    rows
			}
		}
		else {
			return error('unsupported_driver')
		}
	}
}

fn db_session_execute(mut session DbSessionHandle, query string, params []string) !DbExecResult {
	return match session.driver {
		'mysql' {
			if params.len == 0 {
				_ = session.mysql_conn.exec_none(query)
			} else {
				mut stmt := session.mysql_conn.init_stmt(query)
				defer {
					stmt.close() or {}
				}
				stmt.prepare()!
				for param in params {
					stmt.bind_text(param)
				}
				stmt.bind_params()!
				stmt.execute()!
			}
			DbExecResult{
				affected_rows:      int(session.mysql_conn.affected_rows())
				last_insert_id:     i64(session.mysql_conn.last_id())
				has_last_insert_id: true
			}
		}
		'pgsql' {
			mut result := pg.Result{}
			if params.len == 0 {
				result = session.pg_conn.exec_result(query)!
			} else {
				result = session.pg_conn.exec_param_many_result(query, params)!
			}
			DbExecResult{
				affected_rows:      result.rows.len
				last_insert_id:     0
				has_last_insert_id: false
			}
		}
		else {
			return error('unsupported_driver')
		}
	}
}
