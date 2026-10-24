module dbx

import provider
import sync
import json2 as json

$if enable_db ? {
	import time
}

// Plain V capability: no QuickJS pointers or values may cross into a worker.
pub struct AsyncDatabaseAccess {
pub:
	settings provider.DbRuntimeSettings
	owner    &PoolOwner = &PoolOwner{}
}

@[heap]
pub struct AsyncDatabase {
	access AsyncDatabaseAccess
mut:
	mu           sync.Mutex
	closed       bool
	next_id      u64
	transactions map[string]&AsyncDatabaseTransaction
}

@[heap]
struct AsyncDatabaseTransaction {
	lease    &ConnectionLease @[required]
	deadline i64
mut:
	mu     sync.Mutex
	closed bool
}

pub fn AsyncDatabase.new(access AsyncDatabaseAccess) &AsyncDatabase {
	return &AsyncDatabase{ access: access }
}

pub fn (mut database AsyncDatabase) run_json(request string, cancelled fn () bool) !string {
	req := json.decode[Request](request)!
	return json.encode(database.run(req, cancelled)!)
}

pub fn (mut database AsyncDatabase) is_closed() bool {
	database.mu.@lock()
	defer { database.mu.unlock() }
	return database.closed
}

// Call off the JS lane. Closing a lane never closes the application's pool.
pub fn (mut database AsyncDatabase) close() {
	database.mu.@lock()
	database.closed = true
	mut entries := database.transactions.values()
	database.transactions.clear()
	database.mu.unlock()
	$if enable_db ? {
		for mut tx in entries {
			tx.mu.@lock()
			tx.finish(false) or {}
			tx.mu.unlock()
		}
	}
}

// Blocking native driver calls run only on background workers. Cancellation is
// logical: an executing SQL statement is not interrupted, and its lease stays
// reserved until the driver returns. Never retry SQL automatically.
pub fn (mut database AsyncDatabase) run(req Request, cancelled fn () bool) !Response {
	$if enable_db ? {
		stop := fn [mut database, cancelled] () bool { return cancelled() || database.is_closed() }
		if stop() { return error('db_cancelled') }
		settings := database.access.settings
		if !settings.enabled { return error('database_disabled') }
		if req.op !in ['query', 'execute', 'begin', 'commit', 'rollback'] {
			return error('unsupported_db_operation')
		}
		if req.session_id != '' {
			database.mu.@lock()
			mut tx := database.transactions[req.session_id] or {
				database.mu.unlock()
				return error('invalid_transaction')
			}
			database.mu.unlock()
			for !tx.mu.try_lock() {
				if stop() { return error('db_cancelled') }
				time.sleep(time.millisecond)
			}
			defer { tx.mu.unlock() }
			if tx.closed { return error('transaction_closed') }
			if stop() || (tx.deadline > 0 && time.sys_mono_now() >= tx.deadline) {
				tx.finish(false) or {}
				database.forget(req.session_id)
				return error('db_cancelled')
			}
			if req.op in ['commit', 'rollback'] {
				defer { database.forget(req.session_id) }
				tx.finish(req.op == 'commit')!
				return Response{ ok: true, driver: settings.driver }
			}
			result := async_database_query(mut tx.lease, req, settings.driver) or {
				tx.finish(false) or {}
				database.forget(req.session_id)
				return err
			}
			if stop() {
				tx.finish(false) or {}
				database.forget(req.session_id)
				return error('db_cancelled')
			}
			return result
		}
		if req.op in ['commit', 'rollback'] { return error('missing_transaction') }
		mut owner := database.access.owner
		owner.ensure(settings, PoolFactory.native())!
		if stop() { return error('db_cancelled') }
		mut lease := owner.acquire_until(stop)!
		if req.op == 'begin' {
			lease.begin() or {
				async_database_discard(mut lease)
				return err
			}
			database.mu.@lock()
			database.next_id++
			id := database.next_id.str()
			mut tx := &AsyncDatabaseTransaction{
				lease:    lease
				deadline: if req.timeout_ms > 0 {
					time.sys_mono_now() + i64(req.timeout_ms) * time.millisecond
				} else {
					i64(0)
				}
			}
			if database.closed || cancelled() || database.transactions.len >= 32 {
				database.mu.unlock()
				tx.finish(false) or {}
				return error('database_closed_cancelled_or_transaction_limit')
			}
			database.transactions[id] = tx
			database.mu.unlock()
			return Response{ ok: true, driver: settings.driver, session_id: id }
		}
		result := async_database_query(mut lease, req, settings.driver) or {
			if is_connection_lost_error(err.msg()) {
				async_database_discard(mut lease)
			} else {
				lease.release_to_pool()
			}
			return err
		}
		lease.release_to_pool()
		return result
	} $else {
		return error('database_not_compiled')
	}
}

fn (mut database AsyncDatabase) forget(id string) {
	database.mu.@lock()
	database.transactions.delete(id)
	database.mu.unlock()
}

$if enable_db ? {
	fn async_database_query(mut lease ConnectionLease, req Request, driver string) !Response {
		return match req.op {
			'query' {
				Response.query_result(driver, lease.query(req.sql_text, req.params)!, req.session_id)
			}
			'execute' {
				Response.exec_result(driver, lease.execute(req.sql_text, req.params)!, req.session_id)
			}
			else { return error('unsupported_db_operation') }
		}
	}

	fn async_database_discard(mut lease ConnectionLease) {
		if mut conn := lease.retire() {
			driver := conn.driver
			lease.close_connection(mut conn)
			if driver == 'mysql' { lease.refill_pool() or {} }
		}
	}

	// Caller holds tx.mu; a connection cannot be reused before rollback/reset.
	fn (mut tx AsyncDatabaseTransaction) finish(commit bool) ! {
		if tx.closed { return }
		tx.closed = true
		if commit {
			tx.lease.commit() or {
				async_database_discard(mut tx.lease)
				return err
			}
		} else {
			tx.lease.rollback() or {
				async_database_discard(mut tx.lease)
				return err
			}
		}
		mut conn := tx.lease.retire() or { return }
		conn.reset_for_pool() or {
			driver := conn.driver
			tx.lease.close_connection(mut conn)
			if driver == 'mysql' { tx.lease.refill_pool() or {} }
			return err
		}
		tx.lease.return_connection(conn)
	}
}
