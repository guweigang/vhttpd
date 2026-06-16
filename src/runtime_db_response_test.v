module main

import dbx

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
