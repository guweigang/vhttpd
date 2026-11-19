module dbx

fn test_transaction_sweeper_admission_is_idempotent_and_terminal() {
	mut database := AsyncDatabase.new(AsyncDatabaseAccess{})
	database.start_transaction_sweeper()
	database.start_transaction_sweeper()
	$if enable_db ? { assert database.sweeper_started }
	database.close()
	database.start_transaction_sweeper()
	assert database.is_closed()
	assert database.transactions.len == 0
}
