module dbx

import os
import provider

fn test_mysql_prepared_results_preserve_lengths_nulls_and_column_names() {
	$if enable_db ? {
		port := os.getenv('VHTTPD_TEST_MYSQL_PORT').int()
		if port == 0 {
			println('SKIP MySQL result regression: set VHTTPD_TEST_MYSQL_PORT')
			return
		}
		mut pool := PoolHandle.open(provider.DbRuntimeSettings{
			enabled:   true
			driver:    'mysql'
			host:      '127.0.0.1'
			port:      port
			username:  os.getenv_opt('VHTTPD_TEST_MYSQL_USER') or { 'root' }
			database:  os.getenv_opt('VHTTPD_TEST_MYSQL_DATABASE') or { 'vhttpd_async_test' }
			pool_size: 1
			init_sql:  ['SET NAMES utf8mb4']
		}) or { panic(err) }
		defer { pool.close() }
		mut conn := pool.acquire() or { panic(err) }
		defer { pool.release(conn) }
		large := '中文' + 'x'.repeat(16384)
		for _ in 0 .. 3 {
			result := conn.query('SELECT ? AS payload, ? AS empty_value, CAST(NULL AS CHAR) AS nullable, CONCAT(?,CHAR(0),?) AS binary_value', [
				large,
				'',
				'left',
				'right',
			]) or { panic(err) }
			assert result.columns == ['payload', 'empty_value', 'nullable', 'binary_value']
			assert result.rows.len == 1
			assert result.rows[0]['payload'] == large
			assert result.rows[0]['empty_value'] == ''
			assert result.rows[0]['nullable'] == ''
			assert result.rows[0]['binary_value'] == 'left\x00right'
		}
		empty := conn.query('SELECT ? AS payload WHERE 1=0', ['none']) or { panic(err) }
		assert empty.columns == ['payload']
		assert empty.rows.len == 0
		if _ := conn.query('INVALID SQL ?', ['bad']) {
			assert false
		}
		clean := conn.query('SELECT ? AS recovered', ['ok']) or { panic(err) }
		assert clean.rows[0]['recovered'] == 'ok'
	}
}
