module main

import json
import net.unix
import time

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
	return false
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
	_ = name
	return DbDriverCapabilities{}
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
		last_error:  if settings.enabled { 'db_not_compiled' } else { '' }
		started:     false
		tx_sessions: map[string]DbSessionHandle{}
	}
}

pub fn (mut app App) db_runtime_snapshot() string {
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
	return json.encode(DbRuntimeSnapshot{
		enabled:             enabled
		compiled:            false
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
		ready:               false
		capabilities:        DbRuntimeSnapshotCapabilities{}
		snapshot_at_unix:    time.now().unix()
	})
}

fn (mut app App) db_runtime_finalize_tx_session(session_id string, mut conn DbSessionHandle, reusable bool) ! {
	_ = reusable
	_ = conn
	app.mu.@lock()
	app.db_runtime.tx_sessions.delete(session_id)
	app.db_runtime.active_transactions = app.db_runtime.tx_sessions.len
	app.mu.unlock()
}

fn (mut app App) db_runtime_dispatch(req DbUpstreamRequest) DbUpstreamResponse {
	driver := normalize_db_driver_name(app.db_runtime.driver)
	if req.mode != 'db' {
		return DbUpstreamResponse{
			ok:     false
			error:  'invalid_mode'
			driver: driver
		}
	}
	return DbUpstreamResponse{
		ok:     false
		error:  'db_not_compiled'
		driver: driver
	}
}

fn run_db_runtime_server(mut app App, socket_path string) {
	_ = socket_path
	app.mu.@lock()
	app.db_runtime.started = false
	app.db_runtime.last_error = 'db_not_compiled'
	app.mu.unlock()
	app.emit('db.error', {
		'socket': socket_path
		'error':  'db_not_compiled'
	})
}
