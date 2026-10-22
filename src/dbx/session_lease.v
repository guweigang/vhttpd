module dbx

import sync
import time

// The runtime owns the entry. Exactly one lease owns its native handle while
// executing; waiting borrowers never hold the application mutex.
@[heap]
pub struct TransactionSession {
pub:
	id string @[required]
	pool_origin ?PoolOrigin
mut:
	mu sync.Mutex
	connection ?SessionHandle
	active bool
	closing bool
}

pub fn TransactionSession.new(id string, conn SessionHandle) &TransactionSession {
	return &TransactionSession{id: id, connection: conn}
}

pub fn (mut session TransactionSession) borrow(finalizing bool) !&ConnectionLease {
	for {
		session.mu.@lock()
		if session.closing { session.mu.unlock(); return error('invalid_session') }
		if !session.active {
			conn := session.connection or { session.mu.unlock(); return error('invalid_session') }
			session.connection = none
			session.active = true
			session.closing = finalizing
			session.mu.unlock()
			return &ConnectionLease{connection: conn, transaction: session, pool_origin: session.pool_origin}
		}
		session.mu.unlock()
		time.sleep(time.millisecond)
	}
}

pub fn (mut session TransactionSession) request_close() {
	session.mu.@lock()
	session.closing = true
	session.mu.unlock()
}

// Notify all entries before draining any of them. An executing lease either
// returns its handle here, or retires it and signals after physical cleanup.
pub fn (mut session TransactionSession) drain() ?SessionHandle {
	session.request_close()
	for {
		session.mu.@lock()
		if !session.active {
			owned := session.connection
			session.connection = none
			session.mu.unlock()
			return owned
		}
		session.mu.unlock()
		time.sleep(time.millisecond)
	}
}

@[heap]
pub struct ConnectionLease {
	pool_origin ?PoolOrigin
mut:
	mu sync.Mutex
	connection ?SessionHandle
	transaction ?&TransactionSession
	retiring bool
}

pub fn ConnectionLease.pooled(conn SessionHandle) &ConnectionLease {
	return &ConnectionLease{connection: conn}
}

pub fn (lease &ConnectionLease) transaction_owner() ?&TransactionSession {
	return lease.transaction
}

// A regular transaction release returns the mutated handle to its owner.
// Only a nontransactional lease transfers a handle back to the pool adapter.
pub fn (mut lease ConnectionLease) release() ?SessionHandle {
	lease.mu.@lock()
	defer { lease.mu.unlock() }
	owned := lease.connection
	lease.connection = none
	conn := owned or { return none }
	if mut session := lease.transaction {
		session.mu.@lock()
		session.connection = conn
		session.active = false
		session.mu.unlock()
		return none
	}
	return conn
}

// Keep the entry active until reset/return/discard has physically completed.
// A concurrent drain must not close the pool underneath that cleanup.
pub fn (mut lease ConnectionLease) retire() ?SessionHandle {
	lease.mu.@lock()
	defer { lease.mu.unlock() }
	owned := lease.connection
	lease.connection = none
	conn := owned or { return none }
	if mut session := lease.transaction {
		session.request_close()
		lease.retiring = true
	}
	return conn
}

pub fn (mut lease ConnectionLease) finish_retirement() {
	lease.mu.@lock()
	defer { lease.mu.unlock() }
	if !lease.retiring { return }
	lease.retiring = false
	if mut session := lease.transaction {
		session.mu.@lock()
		session.active = false
		session.mu.unlock()
	}
}

$if enable_db ? {
	pub fn (mut lease ConnectionLease) ping() !bool {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		return conn.ping()!
	}

	pub fn (mut lease ConnectionLease) begin() ! {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		conn.begin()!
	}

	pub fn (mut lease ConnectionLease) commit() ! {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		conn.commit()!
	}

	pub fn (mut lease ConnectionLease) rollback() ! {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		conn.rollback()!
	}

	pub fn (mut lease ConnectionLease) query(query string, params []string) !QueryResult {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		return conn.query(query, params)!
	}

	pub fn (mut lease ConnectionLease) execute(query string, params []string) !ExecResult {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		return conn.execute(query, params)!
	}

	pub fn (mut lease ConnectionLease) escape(value string) !string {
		lease.mu.@lock()
		defer { lease.mu.unlock() }
		mut conn := lease.connection or { return error('db_lease_released') }
		defer { lease.connection = conn }
		return conn.escape(value)!
	}

}

// Nontransactional release and terminal transaction return share the same
// immutable origin. Driver cleanup stays with the resource that issued it.
pub fn (mut lease ConnectionLease) release_to_pool() {
	if conn := lease.release() { lease.return_connection(conn) }
}

pub fn (lease &ConnectionLease) return_connection(conn SessionHandle) {
	if origin := lease.pool_origin {
		origin.return_connection(conn)
	} else {
		mut owned := conn
		lease.close_connection(mut owned)
	}
}

pub fn (lease &ConnectionLease) close_connection(mut conn SessionHandle) {
	close_origin_connection(lease.pool_origin, mut conn)
}

pub fn (session &TransactionSession) close_connection(mut conn SessionHandle) {
	close_origin_connection(session.pool_origin, mut conn)
}

fn close_origin_connection(origin ?PoolOrigin, mut conn SessionHandle) {
	if source := origin {
		mut permit := source.permit
		defer { permit.finish() }
		source.resource.factory.close_connection_fn(mut conn)
	} else {
		$if enable_db ? { conn.close() or {} }
	}
}

pub fn (lease &ConnectionLease) refill_pool() ! {
	origin := lease.pool_origin or { return error('db_pool_unavailable') }
	origin.refill()!
}
