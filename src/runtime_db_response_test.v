module main

import cachex
import dbx
import json
import provider
import time

fn test_db_response_query_result_includes_columns() {
	resp := dbx.Response.query_result('mysql', dbx.QueryResult{
		columns: ['id', 'name']
		rows:    [
			{
				'id':   '1'
				'name': 'Ada'
			},
		]
	}, 'tx_1')
	assert resp.ok
	assert resp.columns == ['id', 'name']
	assert resp.rows.len == 1
	assert resp.session_id == 'tx_1'
}

fn test_db_response_escape_result_includes_escaped_value() {
	resp := dbx.Response.escaped('mysql', "O\\'Reilly", '')
	assert resp.ok
	assert resp.escaped == "O\\'Reilly"
	assert resp.driver == 'mysql'
}

fn test_db_runtime_accepts_default_or_configured_pool_name() {
	rt := dbx.Runtime{
		pool_name: 'analytics'
	}
	assert rt.normalized_pool_name() == 'analytics'
	assert rt.accepts_pool('')
	assert rt.accepts_pool('default')
	assert rt.accepts_pool('analytics')
	assert !rt.accepts_pool('reports')
}

fn test_db_runtime_records_query_observations() {
	mut rt := dbx.Runtime{
		driver:        'mysql'
		pool_name:     'wordpress'
		slow_query_ms: 10
	}
	driver := rt.note_query_observation('query', dbx.Request{
		pool:       'wordpress'
		session_id: 'tx_1'
		trace_id:   'trace_001'
		request_id: 'req_001'
		sql_text:   'SELECT  *' + '\n' + 'FROM wp_posts WHERE ID = 1'
	}, 3, true, '')
	assert driver == 'mysql'
	assert rt.total_queries == 1
	assert rt.failed_queries == 0
	assert rt.slow_queries == 0
	assert rt.last_query_ms == 3
	assert rt.recent_queries.len == 1
	assert rt.recent_queries[0].query == 'SELECT * FROM wp_posts WHERE ID = 1'
	assert rt.recent_queries[0].trace_id == 'trace_001'
	assert rt.recent_queries[0].request_id == 'req_001'
	assert rt.recent_queries[0].ok

	rt.note_query_observation('execute', dbx.Request{
		pool:     'wordpress'
		sql_text: 'UPDATE wp_posts SET post_title = ? WHERE ID = ?'
	}, 12, false, 'deadlock')
	assert rt.total_executes == 0
	assert rt.failed_queries == 1
	assert rt.slow_queries == 1
	assert rt.last_error == 'deadlock'
	assert rt.recent_queries.len == 2
	assert rt.recent_queries[1].op == 'execute'
	assert rt.recent_queries[1].slow
	assert rt.recent_queries[1].error == 'deadlock'
}

fn test_db_runtime_classifies_connection_lost_errors() {
	assert dbx.is_connection_lost_error('Lost connection to MySQL server during query')
	assert dbx.is_connection_lost_error('MySQL server has gone away')
	assert dbx.is_connection_lost_error('connection reset by peer')
	assert dbx.is_connection_lost_error('broken pipe')
	assert !dbx.is_connection_lost_error('syntax error near FROM')
}

fn test_db_request_decodes_binary_safe_params() {
	req := json.decode(dbx.Request,
		'{"params":["fallback"],"params_base64":["TzozMDoiQWN0aW9uU2NoZWR1bGVyX1NpbXBsZVNjaGVkdWxlIjoyOntzOjIyOiIAXgBzY2hlZHVsZWRfdGltZXN0YW1wIjtpOjE7fQ=="]}')!
	params := req.decoded_params()
	assert params.len == 1
	assert params[0].contains('\0')
	assert params[0].starts_with('O:30:"ActionScheduler_SimpleSchedule":2:{s:22:"')
}

fn test_db_runtime_snapshot_includes_idle_ping_ms() {
	rt := dbx.Runtime.from_settings(provider.DbRuntimeSettings{
		enabled:      true
		driver:       'mysql'
		pool_name:    'wordpress'
		idle_ping_ms: 300000
	})
	assert rt.idle_ping_ms == 300000
	assert rt.snapshot_json(false).contains('"idle_ping_ms":300000')
}

fn test_cache_runtime_local_value_helpers_respect_ttl() {
	mut rt := cachex.Runtime.new(true, '/tmp/cache.sock')
	assert rt.set_value('edge.response', 'GET:/', 'cached', 20)
	value := rt.get_value('edge.response', 'GET:/') or { panic('missing cached value') }
	assert value == 'cached'
	time.sleep(30 * time.millisecond)
	if _ := rt.get_value('edge.response', 'GET:/') {
		assert false
	} else {
		assert true
	}
}
