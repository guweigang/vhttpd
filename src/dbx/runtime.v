module dbx

$if enable_db ? {
	import db.mysql
	import db.pg
	import os
	import net.unix
	import net
}

import encoding.base64
import json2 as json
import listener_runtime
import provider
import time

$if enable_db ? {
	fn C.mysql_fetch_lengths(res &C.MYSQL_RES) &u64
}

// ── Shared types (both enable_db and !enable_db) ──

pub struct SnapshotCapabilities {
pub:
	pool         bool
	transactions bool
	parameters   bool
	prepared     bool
	savepoints   bool
}

pub struct QueryObservation {
pub:
	at_unix     i64 @[json: 'at_unix']
	op          string
	pool        string
	session_id  string @[json: 'session_id']
	trace_id    string @[json: 'trace_id']
	request_id  string @[json: 'request_id']
	duration_ms i64    @[json: 'duration_ms']
	ok          bool
	slow        bool
	query       string @[json: 'sql']
	error       string
}

pub struct Snapshot {
pub:
	enabled             bool
	compiled            bool
	socket              string
	driver              string
	pool_name           string @[json: 'pool_name']
	host                string
	port                int
	database            string
	pool_size           int
	idle_ping_ms        int @[json: 'idle_ping_ms']
	pool_ready          bool
	started             bool
	started_at_unix     i64
	last_error          string
	total_queries       u64
	total_executes      u64
	failed_queries      u64
	slow_queries        u64                @[json: 'slow_queries']
	last_query_ms       i64                @[json: 'last_query_ms']
	recent_queries      []QueryObservation @[json: 'recent_queries']
	active_transactions int
	ready               bool
	capabilities        SnapshotCapabilities
	snapshot_at_unix    i64
}

pub struct Runtime {
pub mut:
	enabled             bool
	socket              string
	driver              string
	pool_name           string
	host                string
	port                int
	username            string
	password            string
	database            string
	pool_size           int
	idle_ping_ms        int
	init_sql            []string
	started             bool
	started_at_unix     i64
	last_error          string
	pool_owner          &PoolOwner = &PoolOwner{}
	total_queries       u64
	total_executes      u64
	failed_queries      u64
	slow_queries        u64
	last_query_ms       i64
	slow_query_ms       int = 200 @[json: 'slow_query_ms']
	recent_queries      []QueryObservation
	active_transactions int
	session_counter     u64
	listener_owner      listener_runtime.Owner
	tx_sessions         map[string]&TransactionSession
	transactions_closing bool
}

pub fn (rt Runtime) pool_is_ready() bool {
	mut owner := rt.pool_owner
	return owner.is_ready()
}

// Call under the runtime metadata lock (App.mu in the application adapter).
pub fn (mut rt Runtime) request_stop() ?u64 {
	return rt.request_stop_with(false)
}

pub fn (mut rt Runtime) request_shutdown() ?u64 {
	return rt.request_stop_with(true)
}

fn (mut rt Runtime) request_stop_with(terminal bool) ?u64 {
	// Reject parked transaction borrowers before the listener drains handlers.
	// Otherwise each waiter could enter native work after the active request.
	rt.pool_owner.request_stop()
	rt.transactions_closing = true
	for _, mut owner in rt.tx_sessions { owner.request_close() }
	generation := if terminal {
		rt.listener_owner.request_shutdown()
	} else {
		rt.listener_owner.request_stop()
	}
	rt.started = false
	return generation
}

pub fn (mut rt Runtime) mark_not_compiled() {
	rt.started = false
	rt.last_error = 'db_not_compiled'
}

pub fn (mut rt Runtime) clear_transaction_count() {
	rt.active_transactions = 0
}

pub fn (rt Runtime) driver_name() string {
	return rt.driver
}

pub struct Request {
pub:
	mode          string
	op            string
	pool          string
	version       int
	timeout_ms    int    @[json: 'timeout_ms']
	session_id    string @[json: 'session_id']
	trace_id      string @[json: 'trace_id']
	request_id    string @[json: 'request_id']
	sql_text      string @[json: 'sql']
	params        []string
	params_base64 []string @[json: 'params_base64']
}

pub struct Response {
pub:
	ok             bool
	error          string
	driver         string
	pong           bool
	session_id     string @[json: 'session_id']
	escaped        string
	columns        []string
	rows           []map[string]string
	affected_rows  int @[json: 'affected_rows']
	last_insert_id i64 @[json: 'last_insert_id']
}

const max_recent_queries = 50

fn compact_sql(query string) string {
	mut out := []u8{cap: query.len}
	mut previous_space := false
	for ch in query.bytes() {
		is_space := ch in [` `, `\t`, `\r`, `\n`]
		if is_space {
			if previous_space {
				continue
			}
			out << ` `
			previous_space = true
			continue
		}
		out << ch
		previous_space = false
	}
	clean := out.bytestr().trim_space()
	if clean.len <= 300 {
		return clean
	}
	return clean[..300] + '...'
}

pub fn is_connection_lost_error(message string) bool {
	clean := message.to_lower()
	return clean.contains('lost connection to mysql server')
		|| clean.contains('mysql server has gone away')
		|| clean.contains('server closed the connection unexpectedly')
		|| clean.contains('connection reset by peer') || clean.contains('broken pipe')
		|| clean.contains('eof')
}

pub fn (mut rt Runtime) note_query_observation(op string, req Request, duration_ms i64, ok bool, message string) string {
	if op == 'query' {
		if ok {
			rt.total_queries++
		} else {
			rt.failed_queries++
		}
	} else if op == 'execute' {
		if ok {
			rt.total_executes++
		} else {
			rt.failed_queries++
		}
	}
	rt.last_query_ms = duration_ms
	if !ok {
		rt.last_error = message
	}
	slow := duration_ms >= i64(rt.slow_query_ms)
	if slow {
		rt.slow_queries++
	}
	rt.recent_queries << QueryObservation{
		at_unix:     time.now().unix()
		op:          op
		pool:        req.pool
		session_id:  req.session_id
		trace_id:    req.trace_id
		request_id:  req.request_id
		duration_ms: duration_ms
		ok:          ok
		slow:        slow
		query:       compact_sql(req.sql_text)
		error:       message
	}
	if rt.recent_queries.len > max_recent_queries {
		rt.recent_queries = rt.recent_queries[rt.recent_queries.len - max_recent_queries..].clone()
	}
	return rt.driver
}

pub fn Response.error(driver string, message string) Response {
	return Response{
		ok:     false
		error:  message
		driver: driver
	}
}

pub fn Response.pong(driver string) Response {
	return Response{
		ok:     true
		pong:   true
		driver: driver
	}
}

pub fn (req Request) decoded_params() []string {
	if req.params_base64.len == 0 {
		return req.params
	}
	mut params := []string{cap: req.params_base64.len}
	for encoded in req.params_base64 {
		params << base64.decode_str(encoded)
	}
	return params
}

pub fn Response.ok(driver string) Response {
	return Response{
		ok:     true
		driver: driver
	}
}

pub fn Response.transaction_started(driver string, session_id string) Response {
	return Response{
		ok:         true
		driver:     driver
		session_id: session_id
	}
}

pub fn Response.query_result(driver string, result QueryResult, session_id string) Response {
	return Response{
		ok:             true
		driver:         driver
		columns:        result.columns
		rows:           result.rows
		affected_rows:  0
		last_insert_id: 0
		session_id:     session_id
	}
}

pub fn Response.escaped(driver string, escaped string, session_id string) Response {
	return Response{
		ok:         true
		driver:     driver
		escaped:    escaped
		session_id: session_id
	}
}

pub fn Response.exec_result(driver string, result ExecResult, session_id string) Response {
	return Response{
		ok:             true
		driver:         driver
		affected_rows:  result.affected_rows
		last_insert_id: result.last_insert_id
		session_id:     session_id
	}
}

pub struct FrameCodec {}

pub struct Server {}

// ServerContext is the closure-based interface for server dispatch operations.
pub struct ServerContext {
pub:
	driver_fn   fn () string          @[required]
	dispatch_fn fn (Request) Response @[required]
}

pub fn (ctx ServerContext) driver() string {
	return ctx.driver_fn()
}

pub fn (ctx ServerContext) dispatch(req Request) Response {
	return ctx.dispatch_fn(req)
}

pub struct DriverName {}

pub fn DriverName.normalize(name string) string {
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

// RuntimeContext is the closure-based interface that Server.run needs from the App.
pub struct RuntimeContext {
pub:
	lifecycle           &listener_runtime.Owner @[required]
	mark_listen_error_fn fn (u64, string) @[required]
	mark_started_fn      fn (u64, i64) ?string @[required]
	mark_stopped_fn      fn (u64)               @[required]
	note_error_fn        fn (string)         @[required]
	cleanup_sessions_fn  fn ()               @[required]
	close_pool_fn        fn ()               @[required]
	build_server_ctx_fn  fn () ServerContext @[required]
	emit_started_fn      fn (string, string) @[required]
	emit_error_fn        fn (string, string) @[required]
}

// ── enable_db: real types ──

$if enable_db ? {
	pub struct DriverCapabilities {
	pub:
		pool         bool
		transactions bool
		parameters   bool
		prepared     bool
		savepoints   bool
	}

	pub struct QueryResult {
	pub:
		columns []string
		rows    []map[string]string
	}

	pub struct ExecResult {
	pub:
		affected_rows      int
		last_insert_id     i64
		has_last_insert_id bool
	}

	pub struct MySqlPooledConn {
	pub mut:
		conn         mysql.DB
		last_used_ms i64
	}

	pub struct PoolHandle {
	pub mut:
		driver       string
		init_sql     []string
		mysql_pool   chan MySqlPooledConn
		mysql_config mysql.Config
		pool_size    int
		idle_ping_ms int
		pg_pool      ?&pg.DB
	}

	pub struct SessionHandle {
	pub mut:
		driver             string
		init_sql           []string
		mysql_conn         mysql.DB
		mysql_last_used_ms i64
		pg_conn            ?&pg.Conn
	}
}

// ── !enable_db: stub types ──

$if !enable_db ? {
	pub struct DriverCapabilities {
	pub:
		pool         bool
		transactions bool
		parameters   bool
		prepared     bool
		savepoints   bool
	}

	pub struct QueryResult {
	pub:
		columns []string
		rows    []map[string]string
	}

	pub struct ExecResult {
	pub:
		affected_rows      int
		last_insert_id     i64
		has_last_insert_id bool
	}

	pub struct PoolHandle {}

	pub struct SessionHandle {
	pub mut:
		driver string
	}
}

// ══════════════════════════════════════════════════════════════════════
// enable_db implementation
// ══════════════════════════════════════════════════════════════════════

$if enable_db ? {
	pub fn DriverName.capabilities(name string) DriverCapabilities {
		return match DriverName.normalize(name) {
			'mysql' {
				DriverCapabilities{
					pool:         true
					transactions: true
					parameters:   true
					prepared:     true
					savepoints:   true
				}
			}
			'pgsql', 'pg', 'postgres', 'postgresql' {
				DriverCapabilities{
					pool:         true
					transactions: true
					parameters:   true
					prepared:     true
					savepoints:   true
				}
			}
			else {
				DriverCapabilities{}
			}
		}
	}

	fn mysql_connect_initialized(config mysql.Config, init_sql []string) !mysql.DB {
		mut conn := mysql.connect(config)!
		for statement in init_sql {
			statement_sql := statement.trim_space()
			if statement_sql != '' {
				_ = conn.exec_none(statement_sql)
			}
		}
		return conn
	}

	pub fn PoolHandle.open(settings provider.DbRuntimeSettings) !PoolHandle {
		driver := DriverName.normalize(settings.driver)
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
				mysql_config := mysql.Config{
					host:     host
					port:     port
					username: settings.username
					password: settings.password
					dbname:   database
				}
				mut mysql_pool := chan MySqlPooledConn{cap: pool_size}
				for _ in 0 .. pool_size {
					mysql_pool <- MySqlPooledConn{
						conn:         mysql_connect_initialized(mysql_config, settings.init_sql) or {
							for mysql_pool.len > 0 { mut opened := <-mysql_pool; opened.conn.close() or {} }
							return err
						}
						last_used_ms: time.now().unix_milli()
					}
				}
				PoolHandle{
					driver:       'mysql'
					init_sql:     settings.init_sql.clone()
					mysql_pool:   mysql_pool
					mysql_config: mysql_config
					pool_size:    pool_size
					idle_ping_ms: settings.idle_ping_ms
				}
			}
			'pgsql', 'pg', 'postgres', 'postgresql' {
				PoolHandle{
					driver:  'pgsql'
					pg_pool: pg.connect(pg.Config{
						host:     host
						port:     int(port)
						user:     settings.username
						password: settings.password
						dbname:   database
					}, pg.PoolConfig{
						max_open_conns: pool_size
					})!
				}
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut pool PoolHandle) close() {
		match pool.driver {
			'mysql' {
				for _ in 0 .. pool.mysql_pool.len {
					mut pooled := <-pool.mysql_pool or { break }
					pooled.conn.close() or {}
				}
			}
			'pgsql' {
				if mut handle := pool.pg_pool { handle.close() or {} }
				pool.pg_pool = none
			}
			else {}
		}
	}

	pub fn (mut pool PoolHandle) acquire() !SessionHandle {
		return pool.acquire_until(pool_acquire_running)!
	}

	fn pool_acquire_running() bool { return false }

	fn mysql_acquire_slot(available chan MySqlPooledConn, should_stop fn () bool) !MySqlPooledConn {
		for {
			if should_stop() { return error('db_stopping') }
			select { conn := <-available { return conn } else {} }
			time.sleep(time.millisecond)
		}
	}

	pub fn (mut pool PoolHandle) acquire_until(should_stop fn () bool) !SessionHandle {
		if should_stop() { return error('db_stopping') }
		return match pool.driver {
			'mysql' {
				mut pooled := mysql_acquire_slot(pool.mysql_pool, should_stop)!
				if pool.idle_ping_ms > 0
					&& time.now().unix_milli() - pooled.last_used_ms >= i64(pool.idle_ping_ms) {
					pooled.conn.ping() or {
						pooled.conn.close() or {}
						pooled.conn = mysql_connect_initialized(pool.mysql_config, pool.init_sql)!
					}
				}
				mut session := SessionHandle{
					driver:             'mysql'
					init_sql:           pool.init_sql.clone()
					mysql_conn:         pooled.conn
					mysql_last_used_ms: pooled.last_used_ms
				}
				session.apply_init_sql() or { session.close() or {}; return err }
				session
			}
			'pgsql' {
				mut handle := pool.pg_pool or { return error('pgsql_pool_unavailable') }
				SessionHandle{
					driver:  'pgsql'
					pg_conn: handle.conn()!
				}
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut pool PoolHandle) release(session SessionHandle) {
		match pool.driver {
			'mysql' {
				if session.driver == 'mysql' {
					pool.mysql_pool <- MySqlPooledConn{
						conn:         session.mysql_conn
						last_used_ms: time.now().unix_milli()
					}
				}
			}
			'pgsql' {
				if session.driver == 'pgsql' {
					if mut handle := session.pg_conn { handle.close() or {} }
				}
			}
			else {}
		}
	}

	pub fn (mut session SessionHandle) close() ! {
		match session.driver {
			'mysql' {
				session.mysql_conn.close()!
			}
			'pgsql' {
				handle := session.pg_conn or { return }
				session.pg_conn = none
				handle.close()!
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) ping() !bool {
		return match session.driver {
			'mysql' {
				session.mysql_conn.ping()!
			}
			'pgsql' {
				handle := session.pg_conn or { return error('pgsql_session_unavailable') }
				rows := handle.exec('select 1')!
				rows.len > 0
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) begin() ! {
		match session.driver {
			'mysql' {
				session.mysql_conn.autocommit(false)!
				session.mysql_conn.begin()!
			}
			'pgsql' {
				handle := session.pg_conn or { return error('pgsql_session_unavailable') }
				handle.begin_on_conn(pg.PQTransactionParam{})!
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) commit() ! {
		match session.driver {
			'mysql' {
				session.mysql_conn.commit()!
			}
			'pgsql' {
				handle := session.pg_conn or { return error('pgsql_session_unavailable') }
				handle.commit()!
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) rollback() ! {
		match session.driver {
			'mysql' {
				session.mysql_conn.rollback()!
			}
			'pgsql' {
				handle := session.pg_conn or { return error('pgsql_session_unavailable') }
				handle.rollback()!
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) reset_for_pool() ! {
		match session.driver {
			'mysql' {
				session.mysql_conn.autocommit(true)!
				session.apply_init_sql()!
			}
			'pgsql' {
				// PostgreSQL connections can be returned to the pool after commit/rollback directly.
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) apply_init_sql() ! {
		if session.driver != 'mysql' {
			return
		}
		for statement in session.init_sql {
			statement_sql := statement.trim_space()
			if statement_sql != '' {
				_ = session.mysql_conn.exec_none(statement_sql)
			}
		}
	}

	pub fn (mut session SessionHandle) escape(value string) !string {
		return match session.driver {
			'mysql' {
				session.mysql_conn.escape_string(value)
			}
			'pgsql' {
				value.replace("'", "''").replace('\\', '\\\\')
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

	fn mysql_result_maps(result mysql.Result) []map[string]string {
		columns := mysql_field_names_from_result(result)
		mut rows := []map[string]string{}
		field_count := result.n_fields()
		for {
			row := C.mysql_fetch_row(result.result)
			if row == unsafe { nil } {
				break
			}
			lengths := C.mysql_fetch_lengths(result.result)
			mut item := map[string]string{}
			for i in 0 .. field_count {
				key := if i < columns.len && columns[i] != '' { columns[i] } else { '${i}' }
				if unsafe { row[i] == 0 } {
					item[key] = ''
					continue
				}
				length := if lengths == unsafe { nil } { 0 } else { int(unsafe { lengths[i] }) }
				item[key] = unsafe { (&u8(row[i])).vstring_with_len(length).clone() }
			}
			rows << item
		}
		return rows
	}

	fn mysql_stmt_query_rows(mut conn mysql.DB, query string, params []string) !QueryResult {
		// The legacy buffered StmtHandle fetcher treats length-delimited MySQL
		// columns as NUL-terminated strings. Use the length-aware prepared
		// stream API and keep its connection guard for the complete result.
		mut stmt := conn.prepare_stream(query)!
		defer {
			stmt.close()
		}
		stmt.execute(params)!
		columns := stmt.fields().map(it.name)
		mut rows := []map[string]string{}
		for {
			batch := stmt.next_batch(128)!
			if batch.len == 0 {
				break
			}
			for response_row in batch {
				mut item := map[string]string{}
				for i, value in response_row.vals {
					key := QueryResult.column_key(columns, i)
					item[key] = value or { '' }
				}
				rows << item
			}
		}
		return QueryResult{
			columns: columns
			rows:    rows
		}
	}

	pub fn QueryResult.column_key(columns []string, idx int) string {
		if idx >= 0 && idx < columns.len && columns[idx] != '' {
			return columns[idx]
		}
		return '${idx}'
	}

	pub fn (mut session SessionHandle) query(query string, params []string) !QueryResult {
		return match session.driver {
			'mysql' {
				if params.len == 0 {
					mut result := session.mysql_conn.real_query(query)!
					columns := mysql_field_names_from_result(result)
					rows := mysql_result_maps(result)
					unsafe {
						result.free()
					}
					QueryResult{
						columns: columns
						rows:    rows
					}
				} else {
					mysql_stmt_query_rows(mut session.mysql_conn, query, params)!
				}
			}
			'pgsql' {
				handle := session.pg_conn or { return error('pgsql_session_unavailable') }
				mut result := pg.Result{}
				if params.len == 0 {
					result = handle.exec_result(query)!
				} else {
					result = handle.exec_param_many_result(query, params)!
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
						key := QueryResult.column_key(columns, i)
						item[key] = if v := value { v } else { '' }
					}
					rows << item
				}
				QueryResult{
					columns: columns
					rows:    rows
				}
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	pub fn (mut session SessionHandle) execute(query string, params []string) !ExecResult {
		return match session.driver {
			'mysql' {
				if params.len == 0 {
					mut result := session.mysql_conn.real_query(query)!
					unsafe {
						result.free()
					}
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
				ExecResult{
					affected_rows:      int(session.mysql_conn.affected_rows())
					last_insert_id:     i64(session.mysql_conn.last_id())
					has_last_insert_id: true
				}
			}
			'pgsql' {
				handle := session.pg_conn or { return error('pgsql_session_unavailable') }
				mut result := pg.Result{}
				if params.len == 0 {
					result = handle.exec_result(query)!
				} else {
					result = handle.exec_param_many_result(query, params)!
				}
				ExecResult{
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

	pub fn Runtime.compiled() bool {
		return true
	}

	pub fn Runtime.from_settings(settings provider.DbRuntimeSettings) Runtime {
		return Runtime{
			enabled:      settings.enabled
			socket:       settings.socket
			driver:       settings.driver
			pool_name:    if settings.pool_name.trim_space() != '' {
				settings.pool_name
			} else {
				'default'
			}
			host:         settings.host
			port:         settings.port
			username:     settings.username
			password:     settings.password
			database:     settings.database
			pool_size:    settings.pool_size
			idle_ping_ms: settings.idle_ping_ms
			init_sql:     settings.init_sql.clone()
			started:      false
			tx_sessions:  map[string]&TransactionSession{}
		}
	}

	pub fn (rt Runtime) snapshot_json(ready bool) string {
		caps := DriverName.capabilities(rt.driver)
		return json.encode(Snapshot{
			enabled:             rt.enabled
			compiled:            true
			socket:              rt.socket
			driver:              DriverName.normalize(rt.driver)
			pool_name:           rt.normalized_pool_name()
			host:                rt.host
			port:                rt.port
			database:            rt.database
			pool_size:           rt.pool_size
			idle_ping_ms:        rt.idle_ping_ms
			pool_ready:          rt.pool_is_ready()
			started:             rt.started
			started_at_unix:     rt.started_at_unix
			last_error:          rt.last_error
			total_queries:       rt.total_queries
			total_executes:      rt.total_executes
			failed_queries:      rt.failed_queries
			slow_queries:        rt.slow_queries
			last_query_ms:       rt.last_query_ms
			recent_queries:      rt.recent_queries.clone()
			active_transactions: rt.active_transactions
			ready:               ready
			capabilities:        SnapshotCapabilities{
				pool:         caps.pool
				transactions: caps.transactions
				parameters:   caps.parameters
				prepared:     caps.prepared
				savepoints:   caps.savepoints
			}
			snapshot_at_unix:    time.now().unix()
		}, escape_unicode: true, time_as_unix: true)
	}

	pub fn (rt Runtime) settings() provider.DbRuntimeSettings {
		return provider.DbRuntimeSettings{
			enabled:      rt.enabled
			socket:       rt.socket
			driver:       rt.driver
			pool_name:    rt.normalized_pool_name()
			host:         rt.host
			port:         rt.port
			username:     rt.username
			password:     rt.password
			database:     rt.database
			pool_size:    rt.pool_size
			idle_ping_ms: rt.idle_ping_ms
			init_sql:     rt.init_sql.clone()
		}
	}


	pub fn (mut rt Runtime) note_error(message string) {
		rt.last_error = message
		rt.failed_queries++
	}

	pub fn (rt Runtime) normalized_pool_name() string {
		name := rt.pool_name.trim_space()
		return if name == '' { 'default' } else { name }
	}

	pub fn (rt Runtime) accepts_pool(name string) bool {
		clean := name.trim_space()
		return clean == '' || clean == 'default' || clean == rt.normalized_pool_name()
	}

	pub fn (mut rt Runtime) note_query_success() string {
		rt.total_queries++
		return rt.driver
	}

	pub fn (mut rt Runtime) note_execute_success() string {
		rt.total_executes++
		return rt.driver
	}

	pub fn (mut rt Runtime) next_session_id() string {
		rt.session_counter++
		return 'dbtx_${time.now().unix_micro()}_${rt.session_counter}'
	}

	pub fn (mut rt Runtime) track_transaction(session_id string, conn SessionHandle) !string {
		return rt.register_transaction(session_id, conn, none)!
	}

	pub fn (mut rt Runtime) track_transaction_lease(session_id string, mut lease ConnectionLease) !string {
		if rt.transactions_closing { return error('db_stopping') }
		if session_id in rt.tx_sessions { return error('duplicate_session') }
		conn := lease.release() or { return error('db_lease_released') }
		return rt.register_transaction(session_id, conn, lease.pool_origin)!
	}

	fn (mut rt Runtime) register_transaction(session_id string, conn SessionHandle, origin ?PoolOrigin) !string {
		if rt.transactions_closing { return error('db_stopping') }
		if session_id in rt.tx_sessions { return error('duplicate_session') }
		rt.tx_sessions[session_id] = &TransactionSession{id: session_id, connection: conn, pool_origin: origin}
		rt.active_transactions = rt.tx_sessions.len
		return rt.driver
	}

	pub fn (mut rt Runtime) mark_started(generation u64, started_at_unix i64) ?string {
		if rt.listener_owner.should_stop(generation) || !rt.pool_owner.reopen() { return none }
		rt.started = true
		rt.transactions_closing = false
		rt.started_at_unix = started_at_unix
		rt.last_error = ''
		return rt.driver
	}

	pub fn (mut rt Runtime) mark_stopped(generation u64) {
		if rt.listener_owner.is_current(generation) { rt.started = false }
	}

	pub fn (mut rt Runtime) mark_listen_error(generation u64, message string) {
		if !rt.listener_owner.should_stop(generation) {
			rt.started = false
			rt.last_error = message
		}
	}

	pub fn (mut rt Runtime) drain_sessions() []&TransactionSession {
		rt.transactions_closing = true
		mut sessions := []&TransactionSession{}
		for _, conn in rt.tx_sessions {
			sessions << conn
		}
		rt.tx_sessions = map[string]&TransactionSession{}
		rt.active_transactions = 0
		return sessions
	}


	pub fn (mut rt Runtime) detach_transaction(owner &TransactionSession) {
		if current := rt.tx_sessions[owner.id] {
			if voidptr(current) == voidptr(owner) { rt.tx_sessions.delete(owner.id) }
		}
		rt.active_transactions = rt.tx_sessions.len
	}


	pub fn (rt Runtime) transaction_session(session_id string) ?&TransactionSession {
		return rt.tx_sessions[session_id] or { return none }
	}

	// ── Server (enable_db) ──

	fn FrameCodec.write(mut conn unix.StreamConn, payload string) ! {
		size := payload.len
		header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff),
			u8(size & 0xff)]
		conn.write_ptr(&header[0], 4)!
		conn.write_string(payload)!
	}

	fn FrameCodec.read_exact(mut conn unix.StreamConn, size int) ![]u8 {
		mut out := []u8{len: size}
		mut read := 0
		for read < size {
			n := conn.read(mut out[read..])!
			if n <= 0 {
				return error('unexpected EOF')
			}
			read += n
		}
		return out
	}

	fn FrameCodec.read(mut conn unix.StreamConn) !string {
		header := FrameCodec.read_exact(mut conn, 4)!
		size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
		size := int(size_u32)
		if size <= 0 || size > 16 * 1024 * 1024 {
			return error('invalid frame size ${size}')
		}
		body := FrameCodec.read_exact(mut conn, size)!
		return body.bytestr()
	}

	fn Server.handle_connection(ctx ServerContext, mut lifecycle listener_runtime.Owner, mut conn unix.StreamConn, generation u64, request u64) {
		defer {
			conn.close() or {}
			lifecycle.complete_request(request)
		}
		payload := FrameCodec.read(mut conn) or { return }
		if !lifecycle.begin_request(generation, request) { return }
		req := json.decode[Request](payload) or {
			FrameCodec.write(mut conn, json.encode(Response.error(ctx.driver(), 'invalid_json'),
				escape_unicode: true
				time_as_unix:   true
			)) or {}
			return
		}
		resp := ctx.dispatch(req)
		FrameCodec.write(mut conn, json.encode(resp, escape_unicode: true, time_as_unix: true)) or {}
	}

	// Start takes the reservation synchronously, before scheduling the serving loop.
	pub fn Server.start(ctx RuntimeContext, socket_path string) bool {
		if socket_path.trim_space() == '' { return false }
		mut lifecycle := ctx.lifecycle
		generation := lifecycle.reserve() or { return false }
		spawn Server.run_reserved(ctx, socket_path, generation)
		return true
	}

	pub fn Server.run(ctx RuntimeContext, socket_path string) {
		if socket_path.trim_space() == '' { return }
		mut lifecycle := ctx.lifecycle
		generation := lifecycle.reserve() or { return }
		Server.run_reserved(ctx, socket_path, generation)
	}

	fn Server.run_reserved(ctx RuntimeContext, socket_path string, generation u64) {
		mut lifecycle := ctx.lifecycle
		mut published := false
		defer {
			// Drain handlers before destroying transaction sessions or their pool.
			lifecycle.drain_requests(generation)
			// Keep the reservation until shared DB resources are cleaned as well.
			if published {
				ctx.cleanup_sessions_fn()
				ctx.close_pool_fn()
			}
			ctx.mark_stopped_fn(generation)
			lifecycle.finish(generation)
		}
		if lifecycle.should_stop(generation) { return }
		os.mkdir_all(os.dir(socket_path)) or {}
		mut listener := listener_runtime.listen(socket_path) or {
			ctx.mark_listen_error_fn(generation, err.msg())
			if !lifecycle.should_stop(generation) { ctx.emit_error_fn(socket_path, err.msg()) }
			return
		}
		published = lifecycle.publish(generation, listener)
		if !published { listener.close() or {}; return }
		driver := ctx.mark_started_fn(generation, time.now().unix()) or { return }
		ctx.emit_started_fn(socket_path, driver)
		server_ctx := ctx.build_server_ctx_fn()
		for !lifecycle.should_stop(generation) {
			mut conn := listener.accept() or {
				if lifecycle.should_stop(generation) { break }
				if err.code() == net.err_timed_out_code { continue }
				ctx.note_error_fn(err.msg())
				ctx.emit_error_fn(socket_path, err.msg())
				continue
			}
			if lifecycle.should_stop(generation) { conn.close() or {}; break }
			request := lifecycle.accept_request(generation, conn.sock.handle) or { conn.close() or {}; continue }
			go Server.handle_connection(server_ctx, mut lifecycle, mut conn, generation, request)
		}
	}

}

// ══════════════════════════════════════════════════════════════════════
// !enable_db stub implementation
// ══════════════════════════════════════════════════════════════════════

$if !enable_db ? {
	pub fn Runtime.compiled() bool {
		return false
	}

	pub fn Runtime.from_settings(settings provider.DbRuntimeSettings) Runtime {
		return Runtime{
			enabled:      settings.enabled
			socket:       settings.socket
			driver:       settings.driver
			pool_name:    if settings.pool_name.trim_space() != '' {
				settings.pool_name
			} else {
				'default'
			}
			host:         settings.host
			port:         settings.port
			username:     settings.username
			password:     settings.password
			database:     settings.database
			pool_size:    settings.pool_size
			idle_ping_ms: settings.idle_ping_ms
			init_sql:     settings.init_sql.clone()
			last_error:   if settings.enabled { 'db_not_compiled' } else { '' }
			started:      false
		}
	}

	pub fn (rt Runtime) snapshot_json(ready bool) string {
		return json.encode(Snapshot{
			enabled:             rt.enabled
			compiled:            false
			socket:              rt.socket
			driver:              DriverName.normalize(rt.driver)
			pool_name:           rt.normalized_pool_name()
			host:                rt.host
			port:                rt.port
			database:            rt.database
			pool_size:           rt.pool_size
			idle_ping_ms:        rt.idle_ping_ms
			pool_ready:          rt.pool_is_ready()
			started:             rt.started
			started_at_unix:     rt.started_at_unix
			last_error:          rt.last_error
			total_queries:       rt.total_queries
			total_executes:      rt.total_executes
			failed_queries:      rt.failed_queries
			slow_queries:        rt.slow_queries
			last_query_ms:       rt.last_query_ms
			recent_queries:      rt.recent_queries.clone()
			active_transactions: rt.active_transactions
			ready:               ready
			capabilities:        SnapshotCapabilities{}
			snapshot_at_unix:    time.now().unix()
		}, escape_unicode: true, time_as_unix: true)
	}

	pub fn (rt Runtime) normalized_pool_name() string {
		name := rt.pool_name.trim_space()
		return if name == '' { 'default' } else { name }
	}

	pub fn (rt Runtime) accepts_pool(name string) bool {
		clean := name.trim_space()
		return clean == '' || clean == 'default' || clean == rt.normalized_pool_name()
	}

	// ── Server (!enable_db) ──

	pub fn Server.run(ctx RuntimeContext, socket_path string) {
		mut lifecycle := ctx.lifecycle
		generation := lifecycle.reserve() or { return }
		defer {
			ctx.mark_stopped_fn(generation)
			lifecycle.finish(generation)
		}
		ctx.mark_listen_error_fn(generation, 'db_not_compiled')
		ctx.emit_error_fn(socket_path, 'db_not_compiled')
	}

	pub fn Server.start(ctx RuntimeContext, socket_path string) bool {
		Server.run(ctx, socket_path)
		return false
	}
}
