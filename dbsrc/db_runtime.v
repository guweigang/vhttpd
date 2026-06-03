module main

import json
import net.unix
import os
import time

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

fn db_runtime_compiled() bool {
	return true
}

fn build_db_runtime(settings DbRuntimeSettings) DbProviderRuntime {
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

pub fn (mut app App) db_runtime_snapshot() string {
	ready := app.provider_enabled('db')
	app.mu.@lock()
	enabled := app.db_runtime.enabled
	socket := app.db_runtime.socket
	driver := app.db_runtime.driver
	host := app.db_runtime.host
	port := app.db_runtime.port
	database := app.db_runtime.database
	pool_size := app.db_runtime.pool_size
	pool_ready := app.db_runtime.pool_ready
	started := app.db_runtime.started
	started_at_unix := app.db_runtime.started_at_unix
	last_error := app.db_runtime.last_error
	total_queries := app.db_runtime.total_queries
	total_executes := app.db_runtime.total_executes
	failed_queries := app.db_runtime.failed_queries
	active_transactions := app.db_runtime.active_transactions
	app.mu.unlock()
	caps := db_driver_capabilities(driver)
	return json.encode(DbRuntimeSnapshot{
		enabled:             enabled
		compiled:            true
		socket:              socket
		driver:              normalize_db_driver_name(driver)
		host:                host
		port:                port
		database:            database
		pool_size:           pool_size
		pool_ready:          pool_ready
		started:             started
		started_at_unix:     started_at_unix
		last_error:          last_error
		total_queries:       total_queries
		total_executes:      total_executes
		failed_queries:      failed_queries
		active_transactions: active_transactions
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

fn (mut app App) db_runtime_driver() string {
	app.mu.@lock()
	driver := app.db_runtime.driver
	app.mu.unlock()
	return driver
}

fn (mut app App) db_runtime_note_error(message string) {
	app.mu.@lock()
	app.db_runtime.last_error = message
	app.db_runtime.failed_queries++
	app.mu.unlock()
}

fn (mut app App) db_runtime_note_query_success() string {
	app.mu.@lock()
	app.db_runtime.total_queries++
	driver := app.db_runtime.driver
	app.mu.unlock()
	return driver
}

fn (mut app App) db_runtime_note_execute_success() string {
	app.mu.@lock()
	app.db_runtime.total_executes++
	driver := app.db_runtime.driver
	app.mu.unlock()
	return driver
}

fn (mut app App) db_runtime_next_session_id() string {
	app.mu.@lock()
	app.db_runtime.session_counter++
	session_id := 'dbtx_${time.now().unix_micro()}_${app.db_runtime.session_counter}'
	app.mu.unlock()
	return session_id
}

fn (mut app App) db_runtime_track_transaction(session_id string, conn DbSessionHandle) string {
	app.mu.@lock()
	app.db_runtime.tx_sessions[session_id] = conn
	app.db_runtime.active_transactions = app.db_runtime.tx_sessions.len
	driver := app.db_runtime.driver
	app.mu.unlock()
	return driver
}

fn (mut app App) db_runtime_mark_started(started_at_unix i64, listener &unix.StreamListener) string {
	app.mu.@lock()
	app.db_runtime.started = true
	app.db_runtime.started_at_unix = started_at_unix
	app.db_runtime.last_error = ''
	app.db_runtime.stop_requested = false
	app.db_runtime.listener = unsafe { listener }
	driver := app.db_runtime.driver
	app.mu.unlock()
	return driver
}

fn (mut app App) db_runtime_mark_stopped() {
	app.mu.@lock()
	app.db_runtime.listener = unsafe { nil }
	app.db_runtime.started = false
	app.db_runtime.stop_requested = false
	app.mu.unlock()
}

fn (mut app App) db_runtime_stop_requested() bool {
	app.mu.@lock()
	stop_requested := app.db_runtime.stop_requested
	app.mu.unlock()
	return stop_requested
}

fn (mut app App) db_runtime_ensure_pool() ! {
	app.mu.@lock()
	driver := app.db_runtime.driver
	caps := db_driver_capabilities(driver)
	if !caps.pool {
		app.mu.unlock()
		return error('unsupported_driver')
	}
	if app.db_runtime.pool_ready {
		app.mu.unlock()
		return
	}
	settings := DbRuntimeSettings{
		enabled:   app.db_runtime.enabled
		socket:    app.db_runtime.socket
		driver:    app.db_runtime.driver
		host:      app.db_runtime.host
		port:      app.db_runtime.port
		username:  app.db_runtime.username
		password:  app.db_runtime.password
		database:  app.db_runtime.database
		pool_size: app.db_runtime.pool_size
	}
	app.mu.unlock()
	mut pool := db_open_pool(settings)!
	app.mu.@lock()
	if app.db_runtime.pool_ready {
		app.mu.unlock()
		db_pool_close(mut pool)
		return
	}
	app.db_runtime.pool = pool
	app.db_runtime.pool_ready = true
	app.mu.unlock()
}

fn (mut app App) db_runtime_release_conn(conn DbSessionHandle, session_id string) {
	if session_id != '' {
		return
	}
	app.mu.@lock()
	pool_ready := app.db_runtime.pool_ready
	mut pool := app.db_runtime.pool
	app.mu.unlock()
	if pool_ready {
		db_pool_release(mut pool, conn)
	}
}

fn (mut app App) db_runtime_acquire_conn(session_id string) !DbSessionHandle {
	app.db_runtime_ensure_pool()!
	if session_id != '' {
		app.mu.@lock()
		conn := app.db_runtime.tx_sessions[session_id] or {
			app.mu.unlock()
			return error('invalid_session')
		}
		app.mu.unlock()
		return conn
	}
	app.mu.@lock()
	mut pool := app.db_runtime.pool
	app.mu.unlock()
	return db_pool_acquire(mut pool)!
}

fn (mut app App) db_runtime_discard_conn(mut conn DbSessionHandle) {
	db_session_close(mut conn) or {}
	app.mu.@lock()
	pool_ready := app.db_runtime.pool_ready
	settings := DbRuntimeSettings{
		enabled:   app.db_runtime.enabled
		socket:    app.db_runtime.socket
		driver:    app.db_runtime.driver
		host:      app.db_runtime.host
		port:      app.db_runtime.port
		username:  app.db_runtime.username
		password:  app.db_runtime.password
		database:  app.db_runtime.database
		pool_size: app.db_runtime.pool_size
	}
	app.mu.unlock()
	if !pool_ready {
		return
	}
	replacement := db_open_pool(DbRuntimeSettings{
		driver:    settings.driver
		host:      settings.host
		port:      settings.port
		username:  settings.username
		password:  settings.password
		database:  settings.database
		pool_size: 1
	}) or {
		app.db_runtime_note_error(err.msg())
		return
	}
	mut replacement_pool := replacement
	mut replacement_session := db_pool_acquire(mut replacement_pool) or {
		db_pool_close(mut replacement_pool)
		app.db_runtime_note_error(err.msg())
		return
	}
	db_pool_close(mut replacement_pool)
	app.mu.@lock()
	still_ready := app.db_runtime.pool_ready
	mut pool := app.db_runtime.pool
	app.mu.unlock()
	if still_ready {
		db_pool_release(mut pool, replacement_session)
		return
	}
	db_session_close(mut replacement_session) or {}
}

fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn DbSessionHandle, reusable bool) ! {
	app.mu.@lock()
	app.db_runtime.tx_sessions.delete(session_id)
	app.db_runtime.active_transactions = app.db_runtime.tx_sessions.len
	pool_ready := app.db_runtime.pool_ready
	mut pool := app.db_runtime.pool
	app.mu.unlock()
	if reusable {
		db_session_reset_for_pool(mut conn) or {
			app.db_runtime_discard_conn(mut conn)
			return err
		}
		if pool_ready {
			db_pool_release(mut pool, conn)
		} else {
			db_session_close(mut conn) or {}
		}
		return
	}
	db_session_reset_for_pool(mut conn) or {}
	app.db_runtime_discard_conn(mut conn)
}

fn (mut app App) db_runtime_cleanup_sessions() {
	app.mu.@lock()
	mut sessions := []DbSessionHandle{}
	for _, conn in app.db_runtime.tx_sessions {
		sessions << conn
	}
	app.db_runtime.tx_sessions = map[string]DbSessionHandle{}
	app.db_runtime.active_transactions = 0
	app.mu.unlock()
	for mut conn in sessions {
		db_session_reset_for_pool(mut conn) or {}
		db_session_close(mut conn) or {}
	}
}

fn (mut app App) db_runtime_close_pool() {
	app.mu.@lock()
	pool_ready := app.db_runtime.pool_ready
	mut pool := app.db_runtime.pool
	app.db_runtime.pool_ready = false
	app.mu.unlock()
	if pool_ready {
		db_pool_close(mut pool)
	}
}

fn (mut app App) db_runtime_dispatch(req DbUpstreamRequest) DbUpstreamResponse {
	driver := app.db_runtime_driver()
	if req.mode != 'db' {
		return DbUpstreamResponse{
			ok:     false
			error:  'invalid_mode'
			driver: driver
		}
	}
	return match req.op {
		'ping' {
			app.db_runtime_ensure_pool() or {
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			mut conn := app.db_runtime_acquire_conn('') or {
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			defer {
				app.db_runtime_release_conn(conn, '')
			}
			db_session_ping(mut conn) or {
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			DbUpstreamResponse{
				ok:     true
				pong:   true
				driver: driver
			}
		}
		'begin_transaction' {
			mut conn := app.db_runtime_acquire_conn('') or {
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			db_session_begin(mut conn) or {
				db_session_reset_for_pool(mut conn) or {}
				app.db_runtime_release_conn(conn, '')
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			session_id := app.db_runtime_next_session_id()
			driver_name := app.db_runtime_track_transaction(session_id, conn)
			DbUpstreamResponse{
				ok:         true
				driver:     driver_name
				session_id: session_id
			}
		}
		'commit' {
			if req.session_id.trim_space() == '' {
				DbUpstreamResponse{
					ok:     true
					driver: driver
				}
			} else {
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse{
						ok:     false
						error:  err.msg()
						driver: driver
					}
				}
				db_session_commit(mut conn) or {
					app.db_runtime_finalize_tx_session(req.session_id, mut conn, false) or {}
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse{
						ok:     false
						error:  err.msg()
						driver: driver
					}
				}
				app.db_runtime_finalize_tx_session(req.session_id, mut conn, true) or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse{
						ok:     false
						error:  err.msg()
						driver: driver
					}
				}
				DbUpstreamResponse{
					ok:     true
					driver: driver
				}
			}
		}
		'rollback' {
			if req.session_id.trim_space() == '' {
				DbUpstreamResponse{
					ok:     true
					driver: driver
				}
			} else {
				mut conn := app.db_runtime_acquire_conn(req.session_id) or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse{
						ok:     false
						error:  err.msg()
						driver: driver
					}
				}
				db_session_rollback(mut conn) or {
					app.db_runtime_finalize_tx_session(req.session_id, mut conn, false) or {}
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse{
						ok:     false
						error:  err.msg()
						driver: driver
					}
				}
				app.db_runtime_finalize_tx_session(req.session_id, mut conn, true) or {
					app.db_runtime_note_error(err.msg())
					return DbUpstreamResponse{
						ok:     false
						error:  err.msg()
						driver: driver
					}
				}
				DbUpstreamResponse{
					ok:     true
					driver: driver
				}
			}
		}
		'query' {
			mut conn := app.db_runtime_acquire_conn(req.session_id) or {
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			query_result := db_session_query(mut conn, req.sql_text, req.params) or {
				app.db_runtime_release_conn(conn, req.session_id)
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			app.db_runtime_release_conn(conn, req.session_id)
			driver_name := app.db_runtime_note_query_success()
			DbUpstreamResponse{
				ok:             true
				driver:         driver_name
				rows:           query_result.rows
				affected_rows:  0
				last_insert_id: 0
				session_id:     req.session_id
			}
		}
		'execute' {
			mut conn := app.db_runtime_acquire_conn(req.session_id) or {
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			exec_result := db_session_execute(mut conn, req.sql_text, req.params) or {
				app.db_runtime_release_conn(conn, req.session_id)
				app.db_runtime_note_error(err.msg())
				return DbUpstreamResponse{
					ok:     false
					error:  err.msg()
					driver: driver
				}
			}
			app.db_runtime_release_conn(conn, req.session_id)
			driver_name := app.db_runtime_note_execute_success()
			DbUpstreamResponse{
				ok:             true
				driver:         driver_name
				affected_rows:  exec_result.affected_rows
				last_insert_id: exec_result.last_insert_id
				session_id:     req.session_id
			}
		}
		else {
			DbUpstreamResponse{
				ok:     false
				error:  'unsupported_op'
				driver: driver
			}
		}
	}
}

fn db_runtime_write_frame(mut conn unix.StreamConn, payload string) ! {
	size := payload.len
	header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff),
		u8(size & 0xff)]
	conn.write_ptr(&header[0], 4)!
	conn.write_string(payload)!
}

fn db_runtime_read_exact(mut conn unix.StreamConn, size int) ![]u8 {
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

fn db_runtime_read_frame(mut conn unix.StreamConn) !string {
	header := db_runtime_read_exact(mut conn, 4)!
	size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
	size := int(size_u32)
	if size <= 0 || size > 16 * 1024 * 1024 {
		return error('invalid frame size ${size}')
	}
	body := db_runtime_read_exact(mut conn, size)!
	return body.bytestr()
}

fn handle_db_runtime_connection(mut app App, mut conn unix.StreamConn) {
	defer {
		conn.close() or {}
	}
	payload := db_runtime_read_frame(mut conn) or { return }
	req := json.decode(DbUpstreamRequest, payload) or {
		db_runtime_write_frame(mut conn, json.encode(DbUpstreamResponse{
			ok:     false
			error:  'invalid_json'
			driver: app.db_runtime_driver()
		})) or {}
		return
	}
	resp := app.db_runtime_dispatch(req)
	db_runtime_write_frame(mut conn, json.encode(resp)) or {}
}

fn run_db_runtime_server(mut app App, socket_path string) {
	if socket_path.trim_space() == '' {
		return
	}
	os.mkdir_all(os.dir(socket_path)) or {}
	if os.exists(socket_path) {
		os.rm(socket_path) or {}
	}
	mut listener := unix.listen_stream(socket_path) or {
		app.mu.@lock()
		app.db_runtime.started = false
		app.db_runtime.last_error = err.msg()
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
		go handle_db_runtime_connection(mut app, mut conn)
	}
}
