module dbx

import sync
import time

@[heap]
struct LeaseCounter {
mut:
	mu sync.Mutex
	active int
	completed int
}

fn borrow_transaction_fixture(mut owner TransactionSession, mut counter LeaseCounter, done chan bool) {
	mut lease := owner.borrow(false) or { panic(err) }
	counter.mu.@lock()
	counter.active++
	assert counter.active == 1
	counter.mu.unlock()
	time.sleep(time.millisecond)
	counter.mu.@lock()
	counter.active--
	counter.completed++
	counter.mu.unlock()
	assert lease.release() == none
	done <- true
}

fn lease_signal(ch chan bool) { select { _ := <-ch {} 3 * time.second { panic('lease fixture timed out') } } }

fn test_transaction_borrowers_use_native_handle_exclusively() {
	mut owner := TransactionSession.new('tx', SessionHandle{driver: 'fixture'})
	mut counter := &LeaseCounter{}
	done := chan bool{cap: 24}
	for _ in 0 .. 24 { spawn borrow_transaction_fixture(mut owner, mut counter, done) }
	for _ in 0 .. 24 { lease_signal(done) }
	assert counter.completed == 24
	mut conn := owner.drain() or { panic('handle lost') }
	assert conn.driver == 'fixture'
	assert owner.drain() == none
}

fn waiting_borrow_fixture(mut owner TransactionSession, done chan bool) {
	mut lease := owner.borrow(false) or { assert err.msg() == 'invalid_session'; done <- true; return }
	lease.release()
	panic('borrower entered closed transaction')
}

fn test_close_rejects_waiters_before_active_lease_returns() {
	mut owner := TransactionSession.new('tx', SessionHandle{})
	mut held := owner.borrow(false) or { panic(err) }
	done := chan bool{cap: 1}
	spawn waiting_borrow_fixture(mut owner, done)
	owner.request_close()
	lease_signal(done)
	assert owner.active
	held.release()
	assert owner.drain() != none
}

fn drain_transaction_fixture(mut owner TransactionSession, expect_handle bool, done chan bool) {
	conn := owner.drain()
	assert (conn != none) == expect_handle
	done <- true
}

fn terminal_borrow_fixture(mut owner TransactionSession, result chan &ConnectionLease) {
	lease := owner.borrow(true) or { panic(err) }
	result <- lease
}

fn await_terminal_lease(result chan &ConnectionLease) &ConnectionLease {
	select { lease := <-result { return lease } 3 * time.second {} }
	panic('terminal lease did not acquire')
}

fn test_terminal_lease_blocks_drain_through_physical_retirement() {
	mut owner := TransactionSession.new('tx', SessionHandle{driver: 'fixture'})
	mut query := owner.borrow(false) or { panic(err) }
	result := chan &ConnectionLease{cap: 1}
	spawn terminal_borrow_fixture(mut owner, result)
	select { _ := <-result { panic('terminal lease overtook active query') } 30 * time.millisecond {} }
	query.release()
	mut lease := await_terminal_lease(result)
	if _ := owner.borrow(false) { panic('terminal lease admitted another borrower') }
	owned := lease.retire() or { panic('no retired handle') }
	assert owned.driver == 'fixture'
	assert lease.retire() == none
	assert owner.active
	done := chan bool{cap: 1}
	spawn drain_transaction_fixture(mut owner, false, done)
	select { _ := <-done { panic('drain preceded physical cleanup') } 30 * time.millisecond {} }
	lease.finish_retirement()
	lease.finish_retirement()
	lease_signal(done)
	assert lease.release() == none
}

fn test_drain_waits_for_regular_release_and_takes_handle_once() {
	mut owner := TransactionSession.new('tx', SessionHandle{driver: 'fixture'})
	mut lease := owner.borrow(false) or { panic(err) }
	done := chan bool{cap: 1}
	spawn drain_transaction_fixture(mut owner, true, done)
	select { _ := <-done { panic('drain closed borrowed handle') } 30 * time.millisecond {} }
	lease.release()
	lease_signal(done)
	assert owner.drain() == none
}

fn test_late_release_does_not_end_replacement_lease() {
	mut owner := TransactionSession.new('tx', SessionHandle{})
	mut first := owner.borrow(false) or { panic(err) }
	first.release()
	mut second := owner.borrow(false) or { panic(err) }
	first.release()
	first.finish_retirement()
	assert owner.active
	assert second.retire() != none
	second.finish_retirement()
	assert owner.drain() == none
}

fn test_pooled_lease_transfers_handle_once() {
	mut lease := ConnectionLease.pooled(SessionHandle{driver: 'fixture'})
	assert (lease.release() or { panic('no handle') }).driver == 'fixture'
	assert lease.release() == none
	assert lease.retire() == none
	lease.finish_retirement()
}

$if enable_db ? {
	fn test_transaction_registry_rejects_late_registration_and_stale_detach() {
		mut rt := Runtime{driver: 'pgsql'}
		rt.track_transaction('tx', SessionHandle{driver: 'pgsql'}) or { panic(err) }
		first := rt.transaction_session('tx') or { panic('missing owner') }
		rt.track_transaction('tx', SessionHandle{}) or { assert err.msg() == 'duplicate_session' }
		assert rt.active_transactions == 1
		rt.detach_transaction(first)
		rt.track_transaction('tx', SessionHandle{driver: 'pgsql'}) or { panic(err) }
		rt.detach_transaction(first)
		assert rt.active_transactions == 1
		mut drained := rt.drain_sessions()
		assert drained.len == 1
		assert rt.active_transactions == 0
		rt.track_transaction('late', SessionHandle{}) or { assert err.msg() == 'db_stopping' }
		assert rt.active_transactions == 0
		generation := rt.listener_owner.reserve() or { panic('no reservation') }
		assert rt.mark_started(generation, 1) != none
		rt.track_transaction('next', SessionHandle{}) or { panic(err) }
		assert rt.active_transactions == 1
		assert rt.listener_owner.finish(generation)
	}

	fn test_runtime_stop_closes_transaction_admission_before_request_drain() {
		mut rt := Runtime{driver: 'pgsql'}
		rt.track_transaction('tx', SessionHandle{}) or { panic(err) }
		mut owner := rt.transaction_session('tx') or { panic('no owner') }
		mut held := owner.borrow(false) or { panic(err) }
		done := chan bool{cap: 1}
		spawn waiting_borrow_fixture(mut owner, done)
		generation := rt.listener_owner.reserve() or { panic('no generation') }
		assert rt.request_stop() or { panic('no stopped generation') } == generation
		lease_signal(done)
		assert owner.active
		rt.track_transaction('late', SessionHandle{}) or { assert err.msg() == 'db_stopping' }
		assert rt.active_transactions == 1
		held.release()
		assert owner.drain() != none
		assert rt.listener_owner.finish(generation)
	}

	fn test_released_native_lease_rejects_driver_access() {
		mut lease := ConnectionLease.pooled(SessionHandle{driver: 'pgsql'})
		lease.release()
		lease.query('select 1', []) or { assert err.msg() == 'db_lease_released'; return }
		panic('released lease entered driver')
	}
}
