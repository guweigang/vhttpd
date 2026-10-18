module dbx

import provider
import sync
import time

@[heap]
struct PoolFixture {
mut:
	mu sync.Mutex
	opens int
	closes int
	connects int
	refill_host string
	refill_size int
	returns int
	connection_closes int
	fail_open bool
	acquires int
	gate_acquire bool
	fail_acquire bool
	acquiring chan bool = chan bool{cap: 32}
	continue_acquire chan bool = chan bool{cap: 32}
	gate_open bool
	gate_close bool
	gate_connect bool
	gate_connection_close bool
	opened chan bool = chan bool{cap: 32}
	continue_open chan bool = chan bool{cap: 32}
	closing chan bool = chan bool{cap: 32}
	continue_close chan bool = chan bool{cap: 32}
	connecting chan bool = chan bool{cap: 32}
	continue_connect chan bool = chan bool{cap: 32}
	connection_closing chan bool = chan bool{cap: 32}
	continue_connection_close chan bool = chan bool{cap: 32}
}

fn (mut fixture PoolFixture) factory() PoolFactory {
	return PoolFactory{
		open_fn: fn [mut fixture] (_ provider.DbRuntimeSettings) !PoolHandle {
			fixture.mu.@lock()
			fixture.opens++
			gate, fail := fixture.gate_open, fixture.fail_open
			fixture.mu.unlock()
			fixture.opened <- true
			if gate { _ := <-fixture.continue_open }
			if fail { return error('fixture_open_failed') }
			return PoolHandle{}
		}
		close_fn: fn [mut fixture] (mut _pool PoolHandle) {
			fixture.mu.@lock()
			fixture.closes++
			gate := fixture.gate_close
			fixture.mu.unlock()
			fixture.closing <- true
			if gate { _ := <-fixture.continue_close }
		}
		acquire_fn: fn [mut fixture] (_ PoolHandle, _ fn () bool) !SessionHandle {
			fixture.mu.@lock()
			fixture.acquires++
			gate, fail := fixture.gate_acquire, fixture.fail_acquire
			fixture.mu.unlock()
			fixture.acquiring <- true
			if gate { _ := <-fixture.continue_acquire }
			if fail { return error('fixture_acquire_failed') }
			return SessionHandle{driver: 'fixture'}
		}
		release_fn: fn [mut fixture] (_ PoolHandle, _ SessionHandle) {
			fixture.mu.@lock(); fixture.returns++; fixture.mu.unlock()
		}
		connect_fn: fn [mut fixture] (settings provider.DbRuntimeSettings) !SessionHandle {
			fixture.mu.@lock()
			fixture.connects++
			fixture.refill_host = settings.host
			fixture.refill_size = settings.pool_size
			gate := fixture.gate_connect
			fixture.mu.unlock()
			fixture.connecting <- true
			if gate { _ := <-fixture.continue_connect }
			return SessionHandle{driver: 'fixture'}
		}
		close_connection_fn: fn [mut fixture] (mut _conn SessionHandle) {
			fixture.mu.@lock()
			fixture.connection_closes++
			gate := fixture.gate_connection_close
			fixture.mu.unlock()
			fixture.connection_closing <- true
			if gate { _ := <-fixture.continue_connection_close }
		}
	}
}

fn pool_signal(ch chan bool) { select { _ := <-ch {} 3 * time.second { panic('pool fixture timed out') } } }
fn pool_result(ch chan string) string {
	select { result := <-ch { return result } 3 * time.second {} }
	panic('pool result timed out')
}
fn ensure_pool_fixture(mut owner PoolOwner, factory PoolFactory, done chan string) {
	owner.ensure(provider.DbRuntimeSettings{}, factory) or { done <- err.msg(); return }
	done <- ''
}
fn close_pool_fixture(mut owner PoolOwner, done chan bool) { owner.close(); done <- true }
fn refill_pool_fixture(lease &ConnectionLease, done chan string) {
	lease.refill_pool() or { done <- err.msg(); return }
	done <- ''
}
fn wait_build_fixture(mut owner PoolOwner, build &PoolBuild, done chan string) {
	owner.wait_build(build) or { done <- err.msg(); return }
	done <- ''
}

fn test_concurrent_ensure_builds_one_pool_and_closes_once() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{gate_open: true}
	factory := fixture.factory()
	done := chan string{cap: 16}
	for _ in 0 .. 16 { spawn ensure_pool_fixture(mut owner, factory, done) }
	pool_signal(fixture.opened)
	fixture.continue_open <- true
	for _ in 0 .. 16 { assert pool_result(done) == '' }
	assert fixture.opens == 1
	assert owner.is_ready()
	owner.close()
	owner.close()
	assert fixture.closes == 1
	assert !owner.is_ready()
}

fn test_failed_build_result_is_shared_and_later_ensure_can_retry() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{gate_open: true, fail_open: true}
	factory := fixture.factory()
	done := chan string{cap: 2}
	spawn ensure_pool_fixture(mut owner, factory, done)
	pool_signal(fixture.opened)
	owner.mu.@lock()
	build := owner.building or { panic('missing build') }
	owner.mu.unlock()
	spawn wait_build_fixture(mut owner, build, done)
	fixture.continue_open <- true
	for _ in 0 .. 2 { assert pool_result(done) == 'fixture_open_failed' }
	assert fixture.opens == 1
	assert fixture.closes == 0
	fixture.gate_open = false
	fixture.fail_open = false
	owner.ensure(provider.DbRuntimeSettings{}, factory) or { panic(err) }
	assert fixture.opens == 2
	owner.close()
}

fn test_stop_waits_for_rejected_candidate_cleanup_before_reopen() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{gate_open: true, gate_close: true}
	done := chan string{cap: 1}
	spawn ensure_pool_fixture(mut owner, fixture.factory(), done)
	pool_signal(fixture.opened)
	owner.request_stop()
	closed := chan bool{cap: 1}
	spawn close_pool_fixture(mut owner, closed)
	assert !owner.reopen()
	fixture.continue_open <- true
	pool_signal(fixture.closing)
	select { _ := <-closed { panic('close preceded rejected candidate cleanup') } 30 * time.millisecond {} }
	assert !owner.reopen()
	fixture.continue_close <- true
	assert pool_result(done) == 'db_stopping'
	pool_signal(closed)
	assert fixture.closes == 1
	assert !owner.is_ready()
	assert owner.reopen()
}

fn test_concurrent_closers_wait_for_one_native_close() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{gate_close: true}
	owner.ensure(provider.DbRuntimeSettings{}, fixture.factory()) or { panic(err) }
	done := chan bool{cap: 8}
	for _ in 0 .. 8 { spawn close_pool_fixture(mut owner, done) }
	pool_signal(fixture.closing)
	select { _ := <-done { panic('closer returned before native close') } 30 * time.millisecond {} }
	assert !owner.reopen()
	fixture.continue_close <- true
	for _ in 0 .. 8 { pool_signal(done) }
	assert fixture.closes == 1
	assert owner.reopen()
}

fn test_old_lease_return_uses_old_disposer_after_pool_restart() {
	mut owner := &PoolOwner{}
	mut first := &PoolFixture{}
	mut second := &PoolFixture{}
	owner.ensure(provider.DbRuntimeSettings{}, first.factory()) or { panic(err) }
	mut lease := owner.acquire() or { panic(err) }
	owner.close()
	assert owner.reopen()
	owner.ensure(provider.DbRuntimeSettings{pool_size: 1}, second.factory()) or { panic(err) }
	mut next := owner.acquire() or { panic(err) }
	lease.release_to_pool()
	lease.release_to_pool()
	assert first.connection_closes == 1
	assert first.returns == 0
	assert second.returns == 0
	assert owner.borrowed == 1
	next.release_to_pool()
	assert second.returns == 1
	owner.close()
}

fn test_stop_prevents_new_refill_without_starting_driver_work() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{}
	owner.ensure(provider.DbRuntimeSettings{}, fixture.factory()) or { panic(err) }
	mut lease := owner.acquire() or { panic(err) }
	mut retired := lease.retire() or { panic('no retired handle') }
	lease.close_connection(mut retired)
	owner.request_stop()
	lease.refill_pool() or { assert err.msg() == 'db_stopping' }
	assert fixture.connects == 0
	lease.release_to_pool()
	assert fixture.connection_closes == 1
	assert fixture.returns == 0
	owner.close()
}

fn test_late_refill_is_disposed_before_close_and_never_reaches_new_pool() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{gate_connect: true}
	owner.ensure(provider.DbRuntimeSettings{}, fixture.factory()) or { panic(err) }
	mut lease := owner.acquire() or { panic(err) }
	mut retired := lease.retire() or { panic('no retired handle') }
	lease.close_connection(mut retired)
	pool_signal(fixture.connection_closing)
	fixture.gate_connection_close = true
	done := chan string{cap: 1}
	spawn refill_pool_fixture(lease, done)
	pool_signal(fixture.connecting)
	owner.request_stop()
	closed := chan bool{cap: 1}
	spawn close_pool_fixture(mut owner, closed)
	fixture.continue_connect <- true
	pool_signal(fixture.connection_closing)
	select { _ := <-closed { panic('pool closed before rejected refill cleanup') } 30 * time.millisecond {} }
	fixture.continue_connection_close <- true
	assert pool_result(done) == 'db_stopping'
	pool_signal(closed)
	assert fixture.connection_closes == 2
	assert fixture.returns == 0
	fixture.gate_connection_close = false
	assert owner.reopen()
	mut next := &PoolFixture{}
	owner.ensure(provider.DbRuntimeSettings{}, next.factory()) or { panic(err) }
	lease.release_to_pool()
	assert fixture.connection_closes == 2
	assert next.returns == 0
	owner.close()
}

fn test_refill_uses_origin_settings_with_one_connection() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{}
	owner.ensure(provider.DbRuntimeSettings{host: 'original-host', pool_size: 5}, fixture.factory()) or { panic(err) }
	mut lease := owner.acquire() or { panic(err) }
	mut retired := lease.retire() or { panic('no retired handle') }
	lease.close_connection(mut retired)
	lease.refill_pool() or { panic(err) }
	assert fixture.refill_host == 'original-host'
	assert fixture.refill_size == 1
	lease.refill_pool() or { assert err.msg() == 'db_pool_refill_already_requested' }
	assert fixture.connects == 1
	lease.release_to_pool()
	owner.close()
}

fn wait_pool_capacity_fixture(mut owner PoolOwner, done chan string) {
	mut lease := owner.acquire() or { done <- err.msg(); return }
	lease.release_to_pool()
	done <- 'unexpected_acquire'
}

fn test_full_pool_waiters_stop_while_transaction_keeps_capacity() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{}
	owner.ensure(provider.DbRuntimeSettings{pool_size: 1}, fixture.factory()) or { panic(err) }
	mut lease := owner.acquire() or { panic(err) }
	done := chan string{cap: 1}
	spawn wait_pool_capacity_fixture(mut owner, done)
	select { _ := <-done { panic('pool admitted beyond capacity') } 30 * time.millisecond {} }
	owner.request_stop()
	assert pool_result(done) == 'db_stopping'
	assert owner.borrowed == 1
	lease.release_to_pool()
	assert owner.borrowed == 0
	owner.close()
}

fn test_runtime_pool_owners_are_independent_and_snapshot_is_read_only() {
	mut first := Runtime{}
	mut second := Runtime{}
	assert voidptr(first.pool_owner) != voidptr(second.pool_owner)
	mut fixture := &PoolFixture{}
	first.pool_owner.ensure(provider.DbRuntimeSettings{}, fixture.factory()) or { panic(err) }
	assert first.pool_is_ready()
	assert !second.pool_is_ready()
	first.pool_owner.close()
}

$if enable_db ? {
	@[heap]
	struct NativePoolCancel {
	mut:
		mu sync.Mutex
		checks int
		stopping bool
		entered chan bool = chan bool{cap: 1}
	}

	fn native_empty_pool_fixture(mut pool PoolHandle, mut control NativePoolCancel, done chan string) {
		stop := fn [mut control] () bool {
			control.mu.@lock()
			control.checks++
			if control.checks == 2 { control.entered <- true }
			stopping := control.stopping
			control.mu.unlock()
			return stopping
		}
		pool.acquire_until(stop) or { done <- err.msg(); return }
		done <- 'unexpected_acquire'
	}

	fn test_empty_native_mysql_channel_wait_is_interruptible() {
		mut pool := &PoolHandle{driver: 'mysql', mysql_pool: chan MySqlPooledConn{cap: 1}}
		mut control := &NativePoolCancel{}
		done := chan string{cap: 1}
		spawn native_empty_pool_fixture(mut pool, mut control, done)
		pool_signal(control.entered)
		control.mu.@lock(); control.stopping = true; control.mu.unlock()
		assert pool_result(done) == 'db_stopping'
	}

	fn test_transaction_registration_preserves_origin_through_pool_restart() {
		mut rt := Runtime{}
		mut first := &PoolFixture{}
		mut second := &PoolFixture{}
		rt.pool_owner.ensure(provider.DbRuntimeSettings{}, first.factory()) or { panic(err) }
		mut lease := rt.pool_owner.acquire() or { panic(err) }
		rt.track_transaction_lease('tx', mut lease) or { panic(err) }
		rt.pool_owner.close()
		assert rt.pool_owner.reopen()
		rt.pool_owner.ensure(provider.DbRuntimeSettings{}, second.factory()) or { panic(err) }
		mut owner := rt.transaction_session('tx') or { panic('no transaction') }
		mut terminal := owner.borrow(true) or { panic(err) }
		conn := terminal.retire() or { panic('no transaction handle') }
		terminal.return_connection(conn)
		terminal.finish_retirement()
		rt.detach_transaction(owner)
		assert first.connection_closes == 1
		assert second.returns == 0
		assert rt.active_transactions == 0
		rt.pool_owner.close()
	}
}


fn acquire_publication_fixture(mut owner PoolOwner, done chan string) {
	mut lease := owner.acquire() or {
		done <- err.msg()
		return
	}
	// Always release an unexpected result so the old-owner control is clean.
	lease.release_to_pool()
	done <- 'unexpected_lease'
}

fn test_acquire_returned_after_stop_is_disposed_instead_of_published() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{ gate_acquire: true }
	owner.ensure(provider.DbRuntimeSettings{ pool_size: 1 }, fixture.factory()) or { panic(err) }
	done := chan string{cap: 1}
	spawn acquire_publication_fixture(mut owner, done)
	pool_signal(fixture.acquiring)
	owner.request_stop()
	fixture.continue_acquire <- true
	result := pool_result(done)
	owner.close()
	assert result == 'db_stopping'
	assert fixture.connection_closes == 1
	assert fixture.returns == 0
	assert owner.borrowed == 0
	assert owner.activities == 0
}

fn test_pool_close_waits_for_late_acquire_candidate_disposal() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{ gate_acquire: true, gate_connection_close: true }
	owner.ensure(provider.DbRuntimeSettings{ pool_size: 1 }, fixture.factory()) or { panic(err) }
	done := chan string{cap: 1}
	spawn acquire_publication_fixture(mut owner, done)
	pool_signal(fixture.acquiring)
	owner.request_stop()
	closed := chan bool{cap: 1}
	spawn close_pool_fixture(mut owner, closed)
	fixture.continue_acquire <- true
	pool_signal(fixture.connection_closing)
	select {
		_ := <-closed {
			panic('native pool closed before candidate disposal')
		}
		30 * time.millisecond {
		}
	}
	assert !owner.reopen()
	assert owner.borrowed == 1
	fixture.continue_connection_close <- true
	assert pool_result(done) == 'db_stopping'
	pool_signal(closed)
	assert fixture.connection_closes == 1
	assert fixture.closes == 1
	assert fixture.returns == 0
	assert owner.borrowed == 0
	assert owner.activities == 0
	assert owner.reopen()
	mut next := &PoolFixture{}
	owner.ensure(provider.DbRuntimeSettings{ pool_size: 1 }, next.factory()) or { panic(err) }
	mut lease := owner.acquire() or { panic(err) }
	lease.release_to_pool()
	assert next.returns == 1
	assert fixture.connection_closes == 1
	owner.close()
}

fn test_acquire_driver_error_releases_capacity_for_retry() {
	mut owner := &PoolOwner{}
	mut fixture := &PoolFixture{ fail_acquire: true }
	owner.ensure(provider.DbRuntimeSettings{ pool_size: 1 }, fixture.factory()) or { panic(err) }
	if mut unexpected := owner.acquire() {
		unexpected.release_to_pool()
		panic('failed driver published a lease')
	} else {
		assert err.msg() == 'fixture_acquire_failed'
	}
	assert owner.borrowed == 0
	assert owner.activities == 0
	fixture.fail_acquire = false
	mut lease := owner.acquire() or { panic(err) }
	lease.release_to_pool()
	lease.release_to_pool()
	assert fixture.acquires == 2
	assert fixture.returns == 1
	assert owner.borrowed == 0
	owner.close()
}
