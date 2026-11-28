module relaydb

fn test_export_preserves_only_explicit_session_isolation() {
	assert export_session_init_sql([
		'CREATE TABLE must_not_run (id INT)',
		'  set session transaction isolation level repeatable   read; ',
		'SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE; DROP TABLE must_not_run',
		'SET GLOBAL transaction_isolation = "SERIALIZABLE"',
	], false) == ['SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ']
}

fn test_export_read_only_applies_after_isolation_and_cannot_be_overridden() {
	assert export_session_init_sql([
		'SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE',
		'SET SESSION TRANSACTION READ WRITE',
	], true) == [
		'SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE',
		'SET SESSION TRANSACTION READ ONLY',
	]
	assert export_session_init_sql([], false) == []string{}
	assert export_session_init_sql([], true) == ['SET SESSION TRANSACTION READ ONLY']
}
