module main

$if enable_db ? {
	import db.mysql
	import db.pg
	import os
}
import json
import net.unix
import time

// ── Shared types (both enable_db and !enable_db) ──

struct DbRuntimeSnapshotCapabilities {
	pool         bool
	transactions bool
	parameters   bool
	prepared     bool
	savepoints   bool
}

struct DbRuntimeSnapshot {
	enabled             bool
	compiled            bool
	socket              string
	driver              string
	host                string
	port                int
	database            string
	pool_size           int
	pool_ready          bool
	started             bool
	started_at_unix     i64
	last_error          string
	total_queries       u64
	total_executes      u64
	failed_queries      u64
	active_transactions int
	ready               bool
	capabilities        DbRuntimeSnapshotCapabilities
	snapshot_at_unix    i64
}

pub struct DbProviderRuntime {
pub mut:
	enabled             bool
	socket              string
	driver              string
	host                string
	port                int
	username            string
	password            string
	database            string
	pool_size           int
	started             bool
	started_at_unix     i64
	last_error          string
	pool_ready          bool
	pool                DbPoolHandle
	total_queries       u64
	total_executes      u64
	failed_queries      u64
	active_transactions int
	session_counter     u64
	stop_requested      bool
	listener            &unix.StreamListener = unsafe { nil }
	tx_sessions         map[string]DbSessionHandle
}

fn (mut rt DbProviderRuntime) request_stop() &unix.StreamListener {
	rt.stop_requested = true
	listener := rt.listener
	rt.started = false
	return listener
}

fn (mut rt DbProviderRuntime) mark_not_compiled() {
	rt.started = false
	rt.last_error = 'db_not_compiled'
}

fn (mut rt DbProviderRuntime) clear_transaction_count() {
	rt.active_transactions = 0
}

fn (rt DbProviderRuntime) driver_name() string {
	return rt.driver
}

struct DbUpstreamRequest {
	mode       string
	op         string
	pool       string
	version    int
	timeout_ms int    @[json: 'timeout_ms']
	session_id string @[json: 'session_id']
	sql_text   string @[json: 'sql']
	params     []string
}

struct DbUpstreamResponse {
	ok             bool
	error          string
	driver         string
	pong           bool
	session_id     string @[json: 'session_id']
	rows           []map[string]string
	affected_rows  int @[json: 'affected_rows']
	last_insert_id i64 @[json: 'last_insert_id']
}

fn DbUpstreamResponse.error(driver string, message string) DbUpstreamResponse {
	return DbUpstreamResponse{
		ok:     false
		error:  message
		driver: driver
	}
}

fn DbUpstreamResponse.pong(driver string) DbUpstreamResponse {
	return DbUpstreamResponse{
		ok:     true
		pong:   true
		driver: driver
	}
}

fn DbUpstreamResponse.ok(driver string) DbUpstreamResponse {
	return DbUpstreamResponse{
		ok:     true
		driver: driver
	}
}

fn DbUpstreamResponse.transaction_started(driver string, session_id string) DbUpstreamResponse {
	return DbUpstreamResponse{
		ok:         true
		driver:     driver
		session_id: session_id
	}
}

fn DbUpstreamResponse.query_result(driver string, result DbQueryResult, session_id string) DbUpstreamResponse {
	return DbUpstreamResponse{
		ok:             true
		driver:         driver
		rows:           result.rows
		affected_rows:  0
		last_insert_id: 0
		session_id:     session_id
	}
}

fn DbUpstreamResponse.exec_result(driver string, result DbExecResult, session_id string) DbUpstreamResponse {
	return DbUpstreamResponse{
		ok:             true
		driver:         driver
		affected_rows:  result.affected_rows
		last_insert_id: result.last_insert_id
		session_id:     session_id
	}
}

struct DbRuntimeFrameCodec {}

struct DbRuntimeServer {}

struct DbRuntimeServerContext {
	driver_fn   fn () string = unsafe { nil }
	dispatch_fn fn (DbUpstreamRequest) DbUpstreamResponse = unsafe { nil }
}

fn (ctx DbRuntimeServerContext) driver() string {
	return ctx.driver_fn()
}

fn (ctx DbRuntimeServerContext) dispatch(req DbUpstreamRequest) DbUpstreamResponse {
	return ctx.dispatch_fn(req)
}

struct DbDriverName {}

fn DbDriverName.normalize(name string) string {
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

// ── enable_db: real types ──

$if enable_db ? {
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
		pg_pool    &pg.DB = unsafe { nil }
	}

	pub struct DbSessionHandle {
	pub mut:
		driver     string
		mysql_conn mysql.DB
		pg_conn    &pg.Conn = unsafe { nil }
	}
}

// ── !enable_db: stub types ──

$if !enable_db ? {
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

	pub struct DbPoolHandle {}

	pub struct DbSessionHandle {
	pub mut:
		driver string
	}
}

// ══════════════════════════════════════════════════════════════════════
// enable_db implementation
// ══════════════════════════════════════════════════════════════════════

$if enable_db ? {
	fn DbDriverName.capabilities(name string) DbDriverCapabilities {
		return match DbDriverName.normalize(name) {
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

	fn DbPoolHandle.open(settings DbRuntimeSettings) !DbPoolHandle {
		driver := DbDriverName.normalize(settings.driver)
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

	fn (mut pool DbPoolHandle) close() {
		match pool.driver {
			'mysql' {
				pool.mysql_pool.close()
			}
			'pgsql' {
				pool.pg_pool.close() or {}
			}
			else {}
		}
	}

	fn (mut pool DbPoolHandle) acquire() !DbSessionHandle {
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
					pg_conn: pool.pg_pool.conn()!
				}
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	fn (mut pool DbPoolHandle) release(session DbSessionHandle) {
		match pool.driver {
			'mysql' {
				if session.driver == 'mysql' {
					pool.mysql_pool.release(session.mysql_conn)
				}
			}
			'pgsql' {
				if session.driver == 'pgsql' {
					session.pg_conn.close() or {}
				}
			}
			else {}
		}
	}

	fn (mut session DbSessionHandle) close() ! {
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

	fn (mut session DbSessionHandle) ping() !bool {
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

	fn (mut session DbSessionHandle) begin() ! {
		match session.driver {
			'mysql' {
				session.mysql_conn.autocommit(false)!
				session.mysql_conn.begin()!
			}
			'pgsql' {
				session.pg_conn.begin_on_conn(pg.PQTransactionParam{})!
			}
			else {
				return error('unsupported_driver')
			}
		}
	}

	fn (mut session DbSessionHandle) commit() ! {
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

	fn (mut session DbSessionHandle) rollback() ! {
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

	fn (mut session DbSessionHandle) reset_for_pool() ! {
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

	fn DbQueryResult.column_key(columns []string, idx int) string {
		if idx >= 0 && idx < columns.len && columns[idx] != '' {
			return columns[idx]
		}
		return '${idx}'
	}

	fn (mut session DbSessionHandle) query(query string, params []string) !DbQueryResult {
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
						key := DbQueryResult.column_key(columns, i)
						item[key] = if v := value { v } else { '' }
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

	fn (mut session DbSessionHandle) execute(query string, params []string) !DbExecResult {
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

	fn DbProviderRuntime.compiled() bool {
		return true
	}

	fn DbProviderRuntime.from_settings(settings DbRuntimeSettings) DbProviderRuntime {
		return DbProviderRuntime{
			enabled:     settings.enabled
			socket:      settings.socket
			driver:      settings.driver
			host:        settings.host
			port:        settings.port
			username:    settings.username
			password:    settings.password
			database:    settings.database
			pool_size:   settings.pool_size
			started:     false
			tx_sessions: map[string]DbSessionHandle{}
		}
	}

	fn (rt DbProviderRuntime) snapshot_json(ready bool) string {
		caps := DbDriverName.capabilities(rt.driver)
		return json.encode(DbRuntimeSnapshot{
			enabled:             rt.enabled
			compiled:            true
			socket:              rt.socket
			driver:              DbDriverName.normalize(rt.driver)
			host:                rt.host
			port:                rt.port
			database:            rt.database
			pool_size:           rt.pool_size
			pool_ready:          rt.pool_ready
			started:             rt.started
			started_at_unix:     rt.started_at_unix
			last_error:          rt.last_error
			total_queries:       rt.total_queries
			total_executes:      rt.total_executes
			failed_queries:      rt.failed_queries
			active_transactions: rt.active_transactions
			ready:               ready
			capabilities:        DbRuntimeSnapshotCapabilities{
				pool:         caps.pool
				transactions: caps.transactions
				parameters:   caps.parameters
				prepared:     caps.prepared
				savepoints:   caps.savepoints
			}
			snapshot_at_unix:    time.now().unix()
		})
	}

	fn (rt DbProviderRuntime) settings() DbRuntimeSettings {
		return DbRuntimeSettings{
			enabled:   rt.enabled
			socket:    rt.socket
			driver:    rt.driver
			host:      rt.host
			port:      rt.port
			username:  rt.username
			password:  rt.password
			database:  rt.database
			pool_size: rt.pool_size
		}
	}

	fn (rt DbProviderRuntime) single_connection_settings() DbRuntimeSettings {
		settings := rt.settings()
		return DbRuntimeSettings{
			driver:    settings.driver
			host:      settings.host
			port:      settings.port
			username:  settings.username
			password:  settings.password
			database:  settings.database
			pool_size: 1
		}
	}

	fn (mut rt DbProviderRuntime) note_error(message string) {
		rt.last_error = message
		rt.failed_queries++
	}

	fn (mut rt DbProviderRuntime) note_query_success() string {
		rt.total_queries++
		return rt.driver
	}

	fn (mut rt DbProviderRuntime) note_execute_success() string {
		rt.total_executes++
		return rt.driver
	}

	fn (mut rt DbProviderRuntime) next_session_id() string {
		rt.session_counter++
		return 'dbtx_${time.now().unix_micro()}_${rt.session_counter}'
	}

	fn (mut rt DbProviderRuntime) track_transaction(session_id string, conn DbSessionHandle) string {
		rt.tx_sessions[session_id] = conn
		rt.active_transactions = rt.tx_sessions.len
		return rt.driver
	}

	fn (mut rt DbProviderRuntime) mark_started(started_at_unix i64, listener &unix.StreamListener) string {
		rt.started = true
		rt.started_at_unix = started_at_unix
		rt.last_error = ''
		rt.stop_requested = false
		rt.listener = unsafe { listener }
		return rt.driver
	}

	fn (mut rt DbProviderRuntime) mark_stopped() {
		rt.listener = unsafe { nil }
		rt.started = false
		rt.stop_requested = false
	}

	fn (rt DbProviderRuntime) stop_requested_flag() bool {
		return rt.stop_requested
	}

	fn (mut rt DbProviderRuntime) mark_listen_error(message string) {
		rt.started = false
		rt.last_error = message
	}

	fn (mut rt DbProviderRuntime) drain_sessions() []DbSessionHandle {
		mut sessions := []DbSessionHandle{}
		for _, conn in rt.tx_sessions {
			sessions << conn
		}
		rt.tx_sessions = map[string]DbSessionHandle{}
		rt.active_transactions = 0
		return sessions
	}

	fn (mut rt DbProviderRuntime) detach_pool() (bool, DbPoolHandle) {
		pool_ready := rt.pool_ready
		mut pool := rt.pool
		rt.pool_ready = false
		return pool_ready, pool
	}

	fn (mut rt DbProviderRuntime) detach_transaction(session_id string) (bool, DbPoolHandle) {
		rt.tx_sessions.delete(session_id)
		rt.active_transactions = rt.tx_sessions.len
		pool_ready := rt.pool_ready
		mut pool := rt.pool
		return pool_ready, pool
	}

	fn (rt DbProviderRuntime) pool_settings_if_needed() !DbRuntimeSettings {
		caps := DbDriverName.capabilities(rt.driver)
		if !caps.pool {
			return error('unsupported_driver')
		}
		if rt.pool_ready {
			return error('pool_ready')
		}
		return rt.settings()
	}

	fn (mut rt DbProviderRuntime) install_pool_if_missing(pool DbPoolHandle) bool {
		if rt.pool_ready {
			return false
		}
		rt.pool = pool
		rt.pool_ready = true
		return true
	}

	fn (rt DbProviderRuntime) pool_handle() (bool, DbPoolHandle) {
		return rt.pool_ready, rt.pool
	}

	fn (rt DbProviderRuntime) transaction_session(session_id string) ?DbSessionHandle {
		return rt.tx_sessions[session_id] or { return none }
	}

	pub fn (mut app App) db_runtime_snapshot() string {
		ready := app.provider_enabled('db')
		app.mu.@lock()
		defer {
			app.mu.unlock()
		}
		return app.db_runtime.snapshot_json(ready)
	}

	fn (mut app App) build_db_runtime_server_context() DbRuntimeServerContext {
		return DbRuntimeServerContext{
			driver_fn:   fn [mut app] () string {
				return app.db_runtime_driver()
			}
			dispatch_fn: fn [mut app] (req DbUpstreamRequest) DbUpstreamResponse {
				return app.db_runtime_dispatch(req)
			}
		}
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

	fn (mut app App) db_runtime_track_transaction(session_id string, conn DbSessionHandle) string {
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
		mut pool := DbPoolHandle.open(settings)!
		app.mu.@lock()
		installed := app.db_runtime.install_pool_if_missing(pool)
		if !installed {
			app.mu.unlock()
			pool.close()
			return
		}
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_release_conn(conn DbSessionHandle, session_id string) {
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

	fn (mut app App) db_runtime_acquire_conn(session_id string) !DbSessionHandle {
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

	fn (mut app App) db_runtime_discard_conn(mut conn DbSessionHandle) {
		conn.close() or {}
		app.mu.@lock()
		pool_ready, _ := app.db_runtime.pool_handle()
		settings := app.db_runtime.single_connection_settings()
		app.mu.unlock()
		if !pool_ready {
			return
		}
		replacement := DbPoolHandle.open(settings) or {
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

	fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn DbSessionHandle, reusable bool) ! {
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

	fn (mut app App) db_runtime_dispatch(req DbUpstreamRequest) DbUpstreamResponse {
		driver := app.db_runtime_driver()
		if req.mode != 'db' {
			return DbUpstreamResponse.error(driver, 'invalid_mode')
		}
		return match req.op {
			'ping' {
				app.db_runtime_ensure_pool() or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				mut conn := app.db_runtime_acquire_conn('') or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				defer {
					app.db_runtime_release_conn(conn, '')
				}
				conn.ping() or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				DbUpstreamResponse.pong(driver)
			}
			'begin_transaction' {
				mut conn := app.db_runtime_acquire_conn('') or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				conn.begin() or {
					conn.reset_for_pool() or {}
					app.db_runtime_release_conn(conn, '')
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				session_id := app.db_runtime_next_session_id()
				driver_name := app.db_runtime_track_transaction(session_id, conn)
				DbUpstreamResponse.transaction_started(driver_name, session_id)
			}
			'commit' {
				if req.session_id.trim_space() == '' {
					DbUpstreamResponse.ok(driver)
				} else {
					mut conn := app.db_runtime_acquire_conn(req.session_id) or {
						app.db_runtime_note_error(err.msg())
						return DbUpstreamResponse.error(driver, err.msg())
					}
					conn.commit() or {
						app.db_runtime_finalize_tx_session(req.session_id, mut conn, false) or {}
						app.db_runtime_note_error(err.msg())
						return DbUpstreamResponse.error(driver, err.msg())
					}
					app.db_runtime_finalize_tx_session(req.session_id, mut conn, true) or {
						app.db_runtime_note_error(err.msg())
						return DbUpstreamResponse.error(driver, err.msg())
					}
					DbUpstreamResponse.ok(driver)
				}
			}
			'rollback' {
				if req.session_id.trim_space() == '' {
					DbUpstreamResponse.ok(driver)
				} else {
					mut conn := app.db_runtime_acquire_conn(req.session_id) or {
						app.db_runtime_note_error(err.msg())
						return DbUpstreamResponse.error(driver, err.msg())
					}
					conn.rollback() or {
						app.db_runtime_finalize_tx_session(req.session_id, mut conn, false) or {}
						app.db_runtime_note_error(err.msg())
						return DbUpstreamResponse.error(driver, err.msg())
					}
					app.db_runtime_finalize_tx_session(req.session_id, mut conn, true) or {
						app.db_runtime_note_error(err.msg())
						return DbUpstreamResponse.error(driver, err.msg())
					}
					DbUpstreamResponse.ok(driver)
				}
			}
			'query' {
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				query_result := conn.query(req.sql_text, req.params) or {
					app.db_runtime_release_conn(conn, req.session_id)
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				app.db_runtime_release_conn(conn, req.session_id)
				driver_name := app.db_runtime_note_query_success()
				DbUpstreamResponse.query_result(driver_name, query_result, req.session_id)
			}
			'execute' {
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				exec_result := conn.execute(req.sql_text, req.params) or {
					app.db_runtime_release_conn(conn, req.session_id)
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse.error(driver, err.msg())
				}
				app.db_runtime_release_conn(conn, req.session_id)
				driver_name := app.db_runtime_note_execute_success()
				DbUpstreamResponse.exec_result(driver_name, exec_result, req.session_id)
			}
			else {
				DbUpstreamResponse.error(driver, 'unsupported_op')
			}
		}
	}

	fn DbRuntimeFrameCodec.write(mut conn unix.StreamConn, payload string) ! {
		size := payload.len
		header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff),
			u8(size & 0xff)]
		conn.write_ptr(&header[0], 4)!
		conn.write_string(payload)!
	}

	fn DbRuntimeFrameCodec.read_exact(mut conn unix.StreamConn, size int) ![]u8 {
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

	fn DbRuntimeFrameCodec.read(mut conn unix.StreamConn) !string {
		header := DbRuntimeFrameCodec.read_exact(mut conn, 4)!
		size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
		size := int(size_u32)
		if size <= 0 || size > 16 * 1024 * 1024 {
			return error('invalid frame size ${size}')
		}
		body := DbRuntimeFrameCodec.read_exact(mut conn, size)!
		return body.bytestr()
	}

	fn DbRuntimeServer.handle_connection(ctx DbRuntimeServerContext, mut conn unix.StreamConn) {
		defer {
			conn.close() or {}
		}
		payload := DbRuntimeFrameCodec.read(mut conn) or { return }
		req := json.decode(DbUpstreamRequest, payload) or {
			DbRuntimeFrameCodec.write(mut conn, json.encode(DbUpstreamResponse.error(ctx.driver(),
				'invalid_json'))) or {}
			return
		}
		resp := ctx.dispatch(req)
		DbRuntimeFrameCodec.write(mut conn, json.encode(resp)) or {}
	}

	fn DbRuntimeServer.run(mut app App, socket_path string) {
		if socket_path.trim_space() == '' {
			return
		}
		os.mkdir_all(os.dir(socket_path)) or {}
		if os.exists(socket_path) {
			os.rm(socket_path) or {}
		}
		mut listener := unix.listen_stream(socket_path) or {
			app.mu.@lock()
			app.db_runtime.mark_listen_error(err.msg())
			app.mu.unlock()
			app.emit('db.error', {
				'socket': socket_path
				'error':  err.msg()
			})
			return
		}
		driver := app.db_runtime_mark_started(time.now().unix(), listener)
		app.emit('db.started', {
			'socket': socket_path
			'driver': driver
		})
		defer {
			app.db_runtime_mark_stopped()
			app.db_runtime_cleanup_sessions()
			app.db_runtime_close_pool()
		}
		server_ctx := app.build_db_runtime_server_context()
		for {
			mut conn := listener.accept() or {
				if app.db_runtime_stop_requested() {
					break
				}
				app.db_runtime_note_error(err.msg())
				app.emit('db.error', {
					'socket': socket_path
					'error':  err.msg()
				})
				continue
			}
			go DbRuntimeServer.handle_connection(server_ctx, mut conn)
		}
	}
}

// ══════════════════════════════════════════════════════════════════════
// !enable_db stub implementation
// ══════════════════════════════════════════════════════════════════════

$if !enable_db ? {
	fn DbProviderRuntime.compiled() bool {
		return false
	}

	fn DbProviderRuntime.from_settings(settings DbRuntimeSettings) DbProviderRuntime {
		return DbProviderRuntime{
			enabled:    settings.enabled
			socket:     settings.socket
			driver:     settings.driver
			host:       settings.host
			port:       settings.port
			username:   settings.username
			password:   settings.password
			database:   settings.database
			pool_size:  settings.pool_size
			last_error: if settings.enabled { 'db_not_compiled' } else { '' }
			started:    false
		}
	}

	fn (rt DbProviderRuntime) snapshot_json(ready bool) string {
		return json.encode(DbRuntimeSnapshot{
			enabled:             rt.enabled
			compiled:            false
			socket:              rt.socket
			driver:              DbDriverName.normalize(rt.driver)
			host:                rt.host
			port:                rt.port
			database:            rt.database
			pool_size:           rt.pool_size
			pool_ready:          rt.pool_ready
			started:             rt.started
			started_at_unix:     rt.started_at_unix
			last_error:          rt.last_error
			total_queries:       rt.total_queries
			total_executes:      rt.total_executes
			failed_queries:      rt.failed_queries
			active_transactions: rt.active_transactions
			ready:               ready
			capabilities:        DbRuntimeSnapshotCapabilities{}
			snapshot_at_unix:    time.now().unix()
		})
	}

	pub fn (mut app App) db_runtime_snapshot() string {
		app.mu.@lock()
		defer {
			app.mu.unlock()
		}
		return app.db_runtime.snapshot_json(false)
	}

	fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn DbSessionHandle, reusable bool) ! {
		_ = session_id
		_ = reusable
		_ = conn
		app.mu.@lock()
		app.db_runtime.clear_transaction_count()
		app.mu.unlock()
	}

	fn (mut app App) db_runtime_dispatch(req DbUpstreamRequest) DbUpstreamResponse {
		driver := DbDriverName.normalize(app.db_runtime.driver_name())
		if req.mode != 'db' {
			return DbUpstreamResponse.error(driver, 'invalid_mode')
		}
		return DbUpstreamResponse.error(driver, 'db_not_compiled')
	}

	fn DbRuntimeServer.run(mut app App, socket_path string) {
		_ = socket_path
		app.mu.@lock()
		app.db_runtime.mark_not_compiled()
		app.mu.unlock()
		app.emit('db.error', {
			'socket': socket_path
			'error':  'db_not_compiled'
		})
	}
}
