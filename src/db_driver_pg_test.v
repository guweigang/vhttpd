module main

import os

fn test_db_driver_pgsql_query_and_transaction_roundtrip() {
	$if !network ? {
		eprintln('> Skipping test ${@FN}, since `-d network` is not passed.')
		return
	}
	host := if os.getenv('VHTTPD_TEST_PG_HOST') != '' {
		os.getenv('VHTTPD_TEST_PG_HOST')
	} else {
		'/tmp'
	}
	port_raw := os.getenv('VHTTPD_TEST_PG_PORT')
	port := if port_raw != '' { port_raw.int() } else { 5432 }
	username := if os.getenv('VHTTPD_TEST_PG_USER') != '' {
		os.getenv('VHTTPD_TEST_PG_USER')
	} else {
		os.getenv('USER')
	}
	password := os.getenv('VHTTPD_TEST_PG_PASSWORD')
	database := if os.getenv('VHTTPD_TEST_PG_DATABASE') != '' {
		os.getenv('VHTTPD_TEST_PG_DATABASE')
	} else {
		username
	}
	mut pool := db_open_pool(DbRuntimeSettings{
		driver:    'pgsql'
		host:      host
		port:      port
		username:  username
		password:  password
		database:  database
		pool_size: 1
	}) or { panic(err) }
	defer {
		db_pool_close(mut pool)
	}
	mut session := db_pool_acquire(mut pool) or { panic(err) }
	defer {
		db_pool_release(mut pool, session)
	}
	query_result := db_session_query(mut session, 'select $1::text as value, current_database() as db_name',
		[
		'hello-pg',
	]) or { panic(err) }
	assert query_result.columns.len == 2
	assert query_result.columns[0] == 'value'
	assert query_result.columns[1] == 'db_name'
	assert query_result.rows.len == 1
	assert query_result.rows[0]['value'] == 'hello-pg'
	assert query_result.rows[0]['db_name'] == database
	db_session_begin(mut session) or { panic(err) }
	transaction_result := db_session_query(mut session, 'select $1::text as tx_value',
		['in-tx']) or { panic(err) }
	assert transaction_result.columns.len == 1
	assert transaction_result.columns[0] == 'tx_value'
	assert transaction_result.rows[0]['tx_value'] == 'in-tx'
	db_session_rollback(mut session) or { panic(err) }
}
