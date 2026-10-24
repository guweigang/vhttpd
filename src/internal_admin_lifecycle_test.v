module main

import admin
import executor
import json2 as json
import net
import net.unix
import os
import server_lifecycle
import time
import worker

fn internal_owner_path() string {
	return '/tmp/vhttpd-ia-${os.getpid()}-${time.now().unix_micro()}.sock'
}

fn internal_owner_connect(path string) &unix.StreamConn {
	deadline := time.now().add(5 * time.second)
	for {
		mut conn := unix.connect_stream(path) or {
			assert time.now() < deadline, 'internal admin did not start: ${err}'
			time.sleep(time.millisecond)
			continue
		}
		conn.set_read_timeout(2 * time.second)
		return conn
	}
	panic('unreachable')
}

fn internal_owner_accepted(mut runtime InternalAdminRuntime) {
	deadline := time.now().add(3 * time.second)
	for runtime.owner.active_requests(1) != 1 {
		assert time.now() < deadline, 'internal admin did not register connection'
		time.sleep(time.millisecond)
	}
}

fn internal_owner_stop(mut runtime InternalAdminRuntime) {
	generation := runtime.request_stop() or { return }
	done := chan bool{cap: 1}
	spawn fn [mut runtime, done, generation] () {
		runtime.wait_stopped(generation)
		done <- true
	}()
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('internal admin stop did not join')
		}
	}
	assert !runtime.owner.is_current(generation)
	assert runtime.owner.active_requests(generation) == 0
}

fn internal_owner_eof(mut peer unix.StreamConn) {
	mut bytes := []u8{len: 4}
	n := peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}
	assert n == 0
}

fn internal_owner_exchange(path string, payload string) admin.InternalAdminResponse {
	mut conn := internal_owner_connect(path)
	defer { conn.close() or {} }
	worker.WorkerBackendFrameCodec.write(mut conn, payload) or { panic(err) }
	raw := worker.WorkerBackendFrameCodec.read(mut conn) or { panic(err) }
	return json.decode[admin.InternalAdminResponse](raw) or { panic(err) }
}

fn test_internal_admin_stop_interrupts_partial_header_and_rejects_late_start() {
	mut app := &App{}
	mut runtime := app.lifecycle.internal_admin
	path := internal_owner_path()
	runtime.start(mut app, path) or { panic(err) }
	mut peer := internal_owner_connect(path)
	defer { peer.close() or {} }
	peer.write([u8(0), 0]) or { panic(err) }
	internal_owner_accepted(mut runtime)
	// Waiting must not require the App mutex or leave a handler borrowing App.
	app.mu.@lock()
	internal_owner_stop(mut runtime)
	app.mu.unlock()
	internal_owner_eof(mut peer)
	assert !os.exists(path)
	mut rejected := false
	runtime.start(mut app, path) or {
		assert err.msg() == 'internal_admin_stopped'
		rejected = true
	}
	assert rejected
}

fn test_internal_admin_stop_interrupts_partial_binary_upload() {
	mut app := &App{}
	mut runtime := app.lifecycle.internal_admin
	path := internal_owner_path()
	runtime.start(mut app, path) or { panic(err) }
	mut peer := internal_owner_connect(path)
	defer { peer.close() or {} }
	worker.WorkerBackendFrameCodec.write(mut peer, json.encode(admin.InternalAdminRequest{
		mode:   'vhttpd_gateway'
		method: 'POST'
		path:   '/feishu/images'
		body:   '{"content_length":128}'
	})) or { panic(err) }
	peer.write([u8(0), 0, 0, 128, 1]) or { panic(err) }
	internal_owner_accepted(mut runtime)
	internal_owner_stop(mut runtime)
	assert !os.exists(path)
}

fn test_internal_admin_stop_before_delayed_serve_cannot_publish() {
	mut app := &App{}
	mut runtime := app.lifecycle.internal_admin
	path := internal_owner_path()
	generation := runtime.owner.reserve() or { panic('no reservation') }
	assert (runtime.request_stop() or { panic('missing stop generation') }) == generation
	spawn runtime.serve(mut app, path, generation)
	internal_owner_stop(mut runtime)
	assert !os.exists(path)
}

fn test_internal_admin_immediate_stop_and_concurrent_closers_join() {
	for _ in 0 .. 5 {
		mut app := &App{}
		mut runtime := app.lifecycle.internal_admin
		path := internal_owner_path()
		runtime.start(mut app, path) or { panic(err) }
		done := chan bool{cap: 8}
		for _ in 0 .. 8 {
			spawn fn [mut runtime, done] () {
				internal_owner_stop(mut runtime)
				done <- true
			}()
		}
		for _ in 0 .. 8 {
			select {
				_ := <-done {
				}
				4 * time.second {
					panic('concurrent admin stop deadlocked')
				}
			}
		}
		assert !os.exists(path)
	}
}

fn test_internal_admin_start_failure_releases_reservation_and_allows_retry() {
	mut app := &App{}
	mut runtime := app.lifecycle.internal_admin
	path := internal_owner_path()
	mut existing := unix.listen_stream(path) or { panic(err) }
	runtime.start(mut app, '/tmp/' + 'a'.repeat(120)) or { panic(err) }
	runtime.wait_stopped(1)
	assert os.exists(path)
	existing.close() or { panic(err) }
	runtime.start(mut app, path) or { panic(err) }
	mut peer := internal_owner_connect(path)
	peer.close() or {}
	internal_owner_stop(mut runtime)
	assert !os.exists(path)
}

fn test_internal_admin_protocol_errors_cleanup_and_next_request_succeeds() {
	mut app := &App{}
	mut runtime := app.lifecycle.internal_admin
	path := internal_owner_path()
	runtime.start(mut app, path) or { panic(err) }
	assert internal_owner_exchange(path, '{').status == 400
	assert internal_owner_exchange(path, json.encode(admin.InternalAdminRequest{
		mode:   'vhttpd_gateway'
		method: 'POST'
		path:   '/feishu/images'
		body:   '{'
	})).status == 400
	assert internal_owner_exchange(path, json.encode(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/missing'
	})).status == 404
	internal_owner_stop(mut runtime)
	assert !os.exists(path)
}

fn test_internal_admin_process_shutdown_joins_blocked_connection() {
	mut app := &App{}
	app.engines.primary.logic_executor = executor.DisabledLogicExecutor{}
	path := internal_owner_path()
	app.lifecycle.internal_admin.start(mut app, path) or { panic(err) }
	mut peer := internal_owner_connect(path)
	defer { peer.close() or {} }
	internal_owner_accepted(mut app.lifecycle.internal_admin)
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		shutdown_app_runtime(mut app, server_lifecycle.ServerRuntimeConfig{
			executor_plan: executor.LogicExecutorRuntimePlan{
				executor:  executor.DisabledLogicExecutor{}
				lifecycle: executor.disabled_executor_lifecycle()
			}
		})
		done <- true
	}()
	select {
		_ := <-done {
		}
		4 * time.second {
			panic('process shutdown did not join internal admin')
		}
	}
	internal_owner_eof(mut peer)
	assert !os.exists(path)
}

fn test_internal_admin_signal_registry_stops_all_owners_and_prevents_delayed_start() {
	mut one := &App{}
	mut two := &App{}
	mut delayed := &App{}
	mut registry := ActiveRuntimeRegistry{}
	path_one := internal_owner_path()
	path_two := internal_owner_path()
	one.lifecycle.internal_admin.start(mut one, path_one) or { panic(err) }
	two.lifecycle.internal_admin.start(mut two, path_two) or { panic(err) }
	mut first := internal_owner_connect(path_one)
	mut second := internal_owner_connect(path_two)
	defer {
		first.close() or {}
		second.close() or {}
	}
	internal_owner_accepted(mut one.lifecycle.internal_admin)
	internal_owner_accepted(mut two.lifecycle.internal_admin)
	cfg := server_lifecycle.ServerRuntimeConfig{
		executor_plan: executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
	registry.register(one, cfg)
	registry.register(two, cfg)
	registry.register(delayed, cfg)
	done := chan bool{cap: 1}
	spawn fn [mut registry, done] () {
		registry.stop_runtime_transports()
		done <- true
	}()
	select {
		_ := <-done {
		}
		4 * time.second {
			panic('signal registry did not join admin owners')
		}
	}
	registry.stop_runtime_transports()
	assert !os.exists(path_one) && !os.exists(path_two)
	internal_owner_eof(mut first)
	internal_owner_eof(mut second)
	mut rejected := false
	delayed.lifecycle.internal_admin.start(mut delayed, internal_owner_path()) or {
		assert err.msg() == 'internal_admin_stopped'
		rejected = true
	}
	assert rejected
}

fn test_internal_admin_bind_conflict_preserves_existing_listener() {
	mut app := &App{}
	mut runtime := app.lifecycle.internal_admin
	path := internal_owner_path()
	mut existing := unix.listen_stream(path) or { panic(err) }
	defer { existing.close() or {} }
	runtime.start(mut app, path) or { panic(err) }
	runtime.wait_stopped(1)
	mut peer := unix.connect_stream(path) or { panic(err) }
	peer.close() or { panic(err) }
	generation := runtime.owner.reserve() or { panic('reservation leaked') }
	assert runtime.owner.finish(generation)
}
