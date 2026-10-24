module main

import cachex
import dbx
import net
import net.unix
import os
import provider
import sync
import time

fn auxiliary_path(label string) string {
	return '/tmp/vhttpd-aux-${os.getpid()}-${time.now().unix_micro()}-${label}.sock'
}

fn auxiliary_connect(path string) &unix.StreamConn {
	deadline := time.now().add(3 * time.second)
	for {
		conn := unix.connect_stream(path) or {
			assert time.now() < deadline
			time.sleep(time.millisecond)
			continue
		}
		return conn
	}
	panic('unreachable connection')
}

fn auxiliary_eof(mut peer unix.StreamConn) {
	peer.set_read_timeout(time.second)
	mut bytes := []u8{len: 1}
	assert (peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}) == 0
}

fn test_auxiliary_shutdown_before_start_is_terminal_in_all_builds() {
	mut app := &App{}
	cache_path := auxiliary_path('cache')
	db_path := auxiliary_path('db')
	stop := app.request_auxiliary_shutdown()
	app.finish_auxiliary_shutdown(stop)
	assert !app.transport.cache.start(cache_path)
	assert !app.db_runtime_server_start(db_path)
	assert !os.exists(cache_path) && !os.exists(db_path)
	app.finish_auxiliary_shutdown(app.request_auxiliary_shutdown())
}

$if enable_db ? {
	@[heap]
	struct AuxiliaryPoolFixture {
	mut:
		mu     sync.Mutex
		closes int
		closed chan bool = chan bool{cap: 2}
	}

	fn (mut fixture AuxiliaryPoolFixture) factory() dbx.PoolFactory {
		return dbx.PoolFactory{
			open_fn:             fn (_ provider.DbRuntimeSettings) !dbx.PoolHandle {
				return dbx.PoolHandle{}
			}
			close_fn:            fn [mut fixture] (mut _ dbx.PoolHandle) {
				fixture.mu.@lock()
				fixture.closes++
				fixture.mu.unlock()
				fixture.closed <- true
			}
			acquire_fn:          fn (_ dbx.PoolHandle, _ fn () bool) !dbx.SessionHandle {
				return dbx.SessionHandle{ driver: 'pgsql' }
			}
			release_fn:          fn (_ dbx.PoolHandle, _ dbx.SessionHandle) {}
			connect_fn:          fn (_ provider.DbRuntimeSettings) !dbx.SessionHandle {
				return dbx.SessionHandle{ driver: 'pgsql' }
			}
			close_connection_fn: fn (mut _ dbx.SessionHandle) {}
		}
	}

	fn test_auxiliary_shutdown_drains_cache_and_db_partial_frames_and_blocks_restart() {
		mut app := &App{}
		cache_path := auxiliary_path('cache')
		db_path := auxiliary_path('db')
		app.transport.cache = cachex.Runtime.new(true, cache_path)
		app.transport.db.enabled = true
		app.transport.db.driver = 'pgsql'
		assert app.transport.cache.start(cache_path)
		assert app.db_runtime_server_start(db_path)
		mut cache_peer := auxiliary_connect(cache_path)
		mut db_peer := auxiliary_connect(db_path)
		defer {
			cache_peer.close() or {}
			db_peer.close() or {}
		}
		cache_peer.write([u8(0), 0]) or { panic(err) }
		db_peer.write([u8(0), 0]) or { panic(err) }
		deadline := time.now().add(3 * time.second)
		for app.transport.cache.listener_owner.active_requests(1) != 1 || app.transport.db.listener_owner.active_requests(1) != 1 {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		// Configuration can change after handles were opened; owners still drain.
		app.mu.@lock()
		app.transport.cache.enabled = false
		app.transport.db.enabled = false
		app.mu.unlock()
		stop := app.request_auxiliary_shutdown()
		app.finish_auxiliary_shutdown(stop)
		auxiliary_eof(mut cache_peer)
		auxiliary_eof(mut db_peer)
		assert app.transport.cache.listener_owner.active_requests(1) == 0
		assert app.transport.db.listener_owner.active_requests(1) == 0
		assert !os.exists(cache_path) && !os.exists(db_path)
		assert !app.transport.cache.start(cache_path)
		assert !app.db_runtime_server_start(db_path)
		app.finish_auxiliary_shutdown(stop)
	}

	fn test_auxiliary_shutdown_without_listener_waits_for_transaction_before_pool_close() {
		mut app := &App{}
		app.transport.db.driver = 'pgsql'
		mut fixture := &AuxiliaryPoolFixture{}
		app.db_runtime_ensure_pool_with(fixture.factory()) or { panic(err) }
		app.transport.db.track_transaction('tx', dbx.SessionHandle{ driver: 'pgsql' }) or { panic(err) }
		mut lease := app.db_runtime_acquire_conn('tx', false) or { panic(err) }
		stop := app.request_auxiliary_shutdown()
		assert stop.db_generation == none
		done := chan bool{cap: 1}
		spawn fn [mut app, stop, done] () {
			app.finish_auxiliary_shutdown(stop)
			done <- true
		}()
		deadline := time.now().add(3 * time.second)
		for {
			app.mu.@lock()
			count := app.transport.db.active_transactions
			app.mu.unlock()
			if count == 0 { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		select {
			_ := <-fixture.closed {
				panic('pool closed before active transaction finished')
			}
			20 * time.millisecond {
			}
		}
		app.db_runtime_release_conn(mut lease)
		select {
			_ := <-done {
			}
			3 * time.second {
				panic('transaction shutdown did not finish')
			}
		}
		assert fixture.closes == 1
		assert !app.transport.db.pool_is_ready()
		assert app.transport.db.transaction_session('tx') == none
		app.finish_auxiliary_shutdown(stop)
		assert fixture.closes == 1
		mut rejected := false
		app.db_runtime_ensure_pool_with(fixture.factory()) or {
			assert err.msg() == 'db_stopping'
			rejected = true
		}
		assert rejected
	}

	fn test_auxiliary_shutdown_cleans_pool_when_listener_start_is_cancelled() {
		for _ in 0 .. 3 {
			mut app := &App{}
			app.transport.db.enabled = true
			app.transport.db.driver = 'pgsql'
			mut fixture := &AuxiliaryPoolFixture{}
			app.db_runtime_ensure_pool_with(fixture.factory()) or { panic(err) }
			path := auxiliary_path('cancelled')
			assert app.db_runtime_server_start(path)
			stop := app.request_auxiliary_shutdown()
			app.finish_auxiliary_shutdown(stop)
			assert fixture.closes == 1
			assert !app.transport.db.pool_is_ready()
			assert !os.exists(path)
			assert !app.db_runtime_server_start(path)
		}
	}
}
