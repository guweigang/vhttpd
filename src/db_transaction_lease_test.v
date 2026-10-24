module main

import dbx
import os
import net.unix
import provider
import time
import sync

$if enable_db ? {
	fn test_db_transaction_query_error_releases_lease_and_commit_failure_retires() {
		mut app := &App{}
		app.transport.db.driver = 'pgsql'
		app.transport.db.track_transaction('tx', dbx.SessionHandle{driver: 'pgsql'}) or { panic(err) }
		// The absent driver handle produces an ordinary query error, not a lost connection.
		response := app.db_runtime_dispatch(dbx.Request{mode: 'db', op: 'query', session_id: 'tx', sql_text: 'select 1'})
		assert !response.ok
		assert response.error == 'pgsql_session_unavailable'
		assert app.transport.db.active_transactions == 1
		mut again := app.db_runtime_acquire_conn('tx', false) or { panic('query leaked its lease: ${err}') }
		app.db_runtime_release_conn(mut again)
		response_commit := app.db_runtime_dispatch(dbx.Request{mode: 'db', op: 'commit', session_id: 'tx'})
		assert !response_commit.ok
		assert response_commit.error == 'pgsql_session_unavailable'
		assert app.transport.db.active_transactions == 0
		app.db_runtime_acquire_conn('tx', false) or { assert err.msg() == 'invalid_session'; return }
		panic('retired transaction remained borrowable')
	}

	fn cleanup_transaction_fixture(mut app App, done chan bool) {
		app.db_runtime_cleanup_sessions()
		done <- true
	}

	fn test_db_cleanup_waits_for_borrower_without_holding_app_lock() {
		mut app := &App{}
		app.transport.db.driver = 'pgsql'
		app.transport.db.track_transaction('tx', dbx.SessionHandle{driver: 'pgsql'}) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('tx', false) or { panic(err) }
		done := chan bool{cap: 1}
		spawn cleanup_transaction_fixture(mut app, done)
		deadline := time.now().add(3 * time.second)
		for {
			app.mu.@lock()
			cleared := app.transport.db.active_transactions == 0
			app.mu.unlock()
			if cleared { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		select { _ := <-done { panic('cleanup overtook active lease') } 30 * time.millisecond {} }
		app.db_runtime_release_conn(mut lease)
		select { _ := <-done {} 3 * time.second { panic('cleanup did not finish') } }
		app.db_runtime_release_conn(mut lease)
		assert app.transport.db.transaction_session('tx') == none
	}

	fn test_db_lost_connection_retirement_is_idempotent_and_clears_registry() {
		mut app := &App{}
		app.transport.db.driver = 'pgsql'
		app.transport.db.track_transaction('tx', dbx.SessionHandle{driver: 'pgsql'}) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('tx', false) or { panic(err) }
		app.db_runtime_release_failed_conn(mut lease, 'connection reset by peer')
		app.db_runtime_release_failed_conn(mut lease, 'connection reset by peer')
		app.db_runtime_release_conn(mut lease)
		assert app.transport.db.active_transactions == 0
		assert app.transport.db.transaction_session('tx') == none
		app.db_runtime_cleanup_sessions()
	}

	fn test_db_rollback_failure_retires_transaction_without_opening_new_pool() {
		mut app := &App{}
		app.transport.db.driver = 'pgsql'
		app.transport.db.track_transaction('tx', dbx.SessionHandle{driver: 'pgsql'}) or { panic(err) }
		response := app.db_runtime_dispatch(dbx.Request{mode: 'db', op: 'rollback', session_id: 'tx'})
		assert !response.ok
		assert response.error == 'pgsql_session_unavailable'
		assert app.transport.db.active_transactions == 0
		assert !app.transport.db.pool_is_ready()
	}
	fn stop_leased_db_fixture(ctx provider.RuntimeContext, done chan bool) {
		ctx.stop() or { panic(err) }
		done <- true
	}

	fn wait_leased_db_started(mut app App) {
		deadline := time.now().add(3 * time.second)
		for {
			app.mu.@lock()
			started := app.transport.db.started
			app.mu.unlock()
			if started { return }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
	}

	fn test_db_provider_stop_waits_for_transaction_lease_then_restarts() {
		mut app := &App{}
		app.transport.db.enabled = true
		app.transport.db.driver = 'pgsql'
		path := '/tmp/vhttpd-db-lease-${os.getpid()}-${time.now().unix_micro()}.sock'
		app.transport.db.socket = path
		ctx := app.build_provider_context('db')
		ctx.start() or { panic(err) }
		wait_leased_db_started(mut app)
		app.mu.@lock()
		app.transport.db.track_transaction('tx', dbx.SessionHandle{driver: 'pgsql'}) or { panic(err) }
		app.mu.unlock()
		mut lease := app.db_runtime_acquire_conn('tx', false) or { panic(err) }
		mut peer := unix.connect_stream(path) or { panic(err) }
		defer { peer.close() or {} }
		payload := '{"mode":"db","op":"query","session_id":"tx","sql":"select 1"}'
		length := payload.len
		peer.write([u8(length >> 24), u8(length >> 16), u8(length >> 8), u8(length)]) or { panic(err) }
		peer.write_string(payload) or { panic(err) }
		accepted_deadline := time.now().add(3 * time.second)
		assert app.transport.db.listener_owner.is_current(1)
		for app.transport.db.listener_owner.active_requests(1) == 0 {
			assert time.now() < accepted_deadline
			time.sleep(time.millisecond)
		}
		done := chan bool{cap: 1}
		spawn stop_leased_db_fixture(ctx, done)
		deadline := time.now().add(3 * time.second)
		for {
			app.mu.@lock()
			cleared := app.transport.db.active_transactions == 0
			app.mu.unlock()
			if cleared { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		assert app.transport.db.listener_owner.active_requests(1) == 0
		select { _ := <-done { panic('provider stop overtook lease') } 30 * time.millisecond {} }
		mut busy := false
		ctx.start() or { assert err.msg() == 'db_listener_busy'; busy = true }
		assert busy
		app.db_runtime_release_conn(mut lease)
		select { _ := <-done {} 3 * time.second { panic('provider stop did not finish') } }
		assert !os.exists(path)
		ctx.start() or { panic(err) }
		wait_leased_db_started(mut app)
		app.mu.@lock()
		app.transport.db.track_transaction('next', dbx.SessionHandle{driver: 'pgsql'}) or { panic(err) }
		app.mu.unlock()
		ctx.stop() or { panic(err) }
		assert app.transport.db.active_transactions == 0
		assert !os.exists(path)
	}

	@[heap]
	struct AppPoolFixture {
	mut:
		mu sync.Mutex
		opens int
		closes int
		returns int
		connection_closes int
		connects int
		refill_host string
		refill_size int
		gate_open bool
		driver string = 'fixture'
		opened chan bool = chan bool{cap: 4}
		continue_open chan bool = chan bool{cap: 4}
	}

	fn (mut fixture AppPoolFixture) factory() dbx.PoolFactory {
		return dbx.PoolFactory{
			open_fn: fn [mut fixture] (_ provider.DbRuntimeSettings) !dbx.PoolHandle {
				fixture.mu.@lock(); fixture.opens++; gate := fixture.gate_open; fixture.mu.unlock()
				fixture.opened <- true
				if gate { _ := <-fixture.continue_open }
				return dbx.PoolHandle{}
			}
			close_fn: fn [mut fixture] (mut _pool dbx.PoolHandle) { fixture.mu.@lock(); fixture.closes++; fixture.mu.unlock() }
			acquire_fn: fn [mut fixture] (_ dbx.PoolHandle, _ fn () bool) !dbx.SessionHandle { return dbx.SessionHandle{driver: fixture.driver} }
			release_fn: fn [mut fixture] (_ dbx.PoolHandle, _ dbx.SessionHandle) { fixture.mu.@lock(); fixture.returns++; fixture.mu.unlock() }
			connect_fn: fn [mut fixture] (settings provider.DbRuntimeSettings) !dbx.SessionHandle { fixture.mu.@lock(); fixture.connects++; fixture.refill_host = settings.host; fixture.refill_size = settings.pool_size; fixture.mu.unlock(); return dbx.SessionHandle{driver: fixture.driver} }
			close_connection_fn: fn [mut fixture] (mut conn dbx.SessionHandle) { fixture.mu.@lock(); fixture.connection_closes++; fixture.mu.unlock(); conn.driver = '' }
		}
	}

	fn ensure_app_pool_fixture(mut app App, factory dbx.PoolFactory, done chan string) {
		app.db_runtime_ensure_pool_with(factory) or { done <- err.msg(); return }
		done <- ''
	}
	fn close_app_pool_fixture(mut app App, done chan bool) { app.db_runtime_close_pool(); done <- true }
	fn probe_app_pool_lock(mut app App, done chan bool) { app.mu.@lock(); app.mu.unlock(); done <- true }

	fn test_db_pool_build_stop_and_close_wait_outside_app_mutex() {
		mut app := &App{}
		app.transport.db.driver = 'mysql'
		mut fixture := &AppPoolFixture{gate_open: true}
		built := chan string{cap: 1}
		spawn ensure_app_pool_fixture(mut app, fixture.factory(), built)
		select { _ := <-fixture.opened {} 3 * time.second { panic('pool did not start opening') } }
		app.mu.@lock(); app.transport.db.request_stop(); app.mu.unlock()
		closed := chan bool{cap: 1}
		spawn close_app_pool_fixture(mut app, closed)
		probe := chan bool{cap: 1}
		spawn probe_app_pool_lock(mut app, probe)
		select { _ := <-probe {} 3 * time.second { panic('pool wait held App.mu') } }
		select { _ := <-closed { panic('close overtook builder') } 30 * time.millisecond {} }
		fixture.continue_open <- true
		select { result := <-built { assert result == 'db_stopping' } 3 * time.second { panic('build did not exit') } }
		select { _ := <-closed {} 3 * time.second { panic('close did not exit') } }
		assert fixture.closes == 1
		assert !app.transport.db.pool_is_ready()
	}

	fn test_db_transaction_cleanup_preserves_pool_factory_and_snapshot_shape() {
		mut app := &App{}
		app.transport.db.driver = 'mysql'
		mut fixture := &AppPoolFixture{}
		app.db_runtime_ensure_pool_with(fixture.factory()) or { panic(err) }
		assert app.db_runtime_snapshot().contains('"pool_ready":true')
		mut lease := app.db_runtime_acquire_conn('', false) or { panic(err) }
		app.db_runtime_track_transaction('tx', mut lease) or { panic(err) }
		app.db_runtime_release_conn(mut lease)
		assert fixture.returns == 0
		app.db_runtime_cleanup_sessions()
		assert fixture.connection_closes == 1
		app.db_runtime_close_pool()
		assert fixture.closes == 1
		assert app.db_runtime_snapshot().contains('"pool_ready":false')
	}

	fn test_db_stopping_discard_closes_connection_without_refill() {
		mut app := &App{}
		app.transport.db.driver = 'mysql'
		mut fixture := &AppPoolFixture{driver: 'mysql'}
		app.db_runtime_ensure_pool_with(fixture.factory()) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('', false) or { panic(err) }
		mut conn := lease.retire() or { panic('missing handle') }
		app.mu.@lock(); app.transport.db.request_stop(); app.mu.unlock()
		app.db_runtime_discard_conn(mut conn, lease)
		assert fixture.connection_closes == 1
		assert fixture.connects == 0
		app.db_runtime_close_pool()
		assert fixture.closes == 1
	}

	fn test_db_app_return_uses_origin_after_pool_restart() {
		mut app := &App{}
		app.transport.db.driver = 'mysql'
		mut first := &AppPoolFixture{}
		mut second := &AppPoolFixture{}
		app.db_runtime_ensure_pool_with(first.factory()) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('', false) or { panic(err) }
		app.db_runtime_close_pool()
		assert app.transport.db.pool_owner.reopen()
		app.db_runtime_ensure_pool_with(second.factory()) or { panic(err) }
		app.db_runtime_release_conn(mut lease)
		assert first.connection_closes == 1
		assert second.returns == 0
		app.db_runtime_close_pool()
	}

	fn test_db_discard_refills_origin_configuration_after_handle_is_cleared() {
		mut app := &App{}
		app.transport.db.driver = 'mysql'
		app.transport.db.host = 'original-host'
		app.transport.db.pool_size = 4
		mut fixture := &AppPoolFixture{driver: 'mysql'}
		app.db_runtime_ensure_pool_with(fixture.factory()) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('', false) or { panic(err) }
		mut conn := lease.retire() or { panic('missing connection') }
		app.transport.db.host = 'changed-host'
		app.db_runtime_discard_conn(mut conn, lease)
		assert conn.driver == ''
		assert fixture.connection_closes == 1
		assert fixture.connects == 1
		assert fixture.returns == 1
		assert fixture.refill_host == 'original-host'
		assert fixture.refill_size == 1
		app.db_runtime_close_pool()
	}

	fn test_db_full_pool_request_exits_before_idle_transaction_cleanup() {
		mut app := &App{}
		app.transport.db.enabled = true
		app.transport.db.driver = 'mysql'
		app.transport.db.pool_size = 1
		path := '/tmp/vhttpd-db-capacity-${os.getpid()}-${time.now().unix_micro()}.sock'
		app.transport.db.socket = path
		ctx := app.build_provider_context('db')
		ctx.start() or { panic(err) }
		wait_leased_db_started(mut app)
		mut fixture := &AppPoolFixture{}
		app.db_runtime_ensure_pool_with(fixture.factory()) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('', false) or { panic(err) }
		app.db_runtime_track_transaction('tx', mut lease) or { panic(err) }
		mut held := app.db_runtime_acquire_conn('tx', false) or { panic(err) }
		mut peer := unix.connect_stream(path) or { panic(err) }
		defer { peer.close() or {} }
		payload := '{"mode":"db","op":"query","sql":"select 1"}'
		length := payload.len
		peer.write([u8(length >> 24), u8(length >> 16), u8(length >> 8), u8(length)]) or { panic(err) }
		peer.write_string(payload) or { panic(err) }
		deadline := time.now().add(3 * time.second)
		for app.transport.db.listener_owner.active_requests(1) == 0 {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		done := chan bool{cap: 1}
		spawn stop_leased_db_fixture(ctx, done)
		for {
			app.mu.@lock(); cleared := app.transport.db.active_transactions == 0; app.mu.unlock()
			if cleared { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		assert app.transport.db.listener_owner.active_requests(1) == 0
		select { _ := <-done { panic('pool stop overtook transaction borrower') } 30 * time.millisecond {} }
		app.db_runtime_release_conn(mut held)
		select { _ := <-done {} 3 * time.second { panic('full-pool stop deadlocked') } }
		assert fixture.connection_closes == 1
		assert fixture.closes == 1
		assert !os.exists(path)
	}

}
