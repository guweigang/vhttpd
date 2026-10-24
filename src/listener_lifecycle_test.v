module main

import os
import provider
import time

$if enable_db ? {
	fn test_db_provider_context_reserves_before_spawn_and_waits_for_stop() {
		mut app := &App{}
		path := '/tmp/vhttpd-app-db-${os.getpid()}-${time.now().unix_micro()}.sock'
		app.transport.db.enabled = true
		app.transport.db.socket = path
		ctx := app.build_provider_context('db')
		for _ in 0 .. 3 {
			ctx.start() or { panic(err) }
			mut busy := false
			ctx.start() or { assert err.msg() == 'db_listener_busy'; busy = true }
			assert busy
			ctx.stop() or { panic(err) }
			assert !app.transport.db.started
			assert !os.exists(path)
			assert app.transport.db.last_error == ''
		}
	}

	fn stop_db_context_fixture(ctx provider.RuntimeContext, done chan bool) {
		ctx.stop() or { panic(err) }
		done <- true
	}

	fn test_concurrent_db_provider_stops_finish_without_holding_app_lock() {
		mut app := &App{}
		path := '/tmp/vhttpd-app-db-stop-${os.getpid()}-${time.now().unix_micro()}.sock'
		app.transport.db.enabled = true
		app.transport.db.socket = path
		ctx := app.build_provider_context('db')
		ctx.start() or { panic(err) }
		deadline := time.now().add(3 * time.second)
		for {
			app.mu.@lock()
			started := app.transport.db.started
			app.mu.unlock()
			if started { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		done := chan bool{cap: 8}
		for _ in 0 .. 8 { spawn stop_db_context_fixture(ctx, done) }
		for _ in 0 .. 8 {
			select { _ := <-done {} 3 * time.second { panic('concurrent stop deadlocked') } }
		}
		assert !app.transport.db.started
		assert !os.exists(path)
		ctx.start() or { panic('restart failed: ${err}') }
		ctx.stop() or { panic(err) }
	}
}
