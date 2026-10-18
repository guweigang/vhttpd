module dbx

import listener_runtime
import net.unix
import os
import sync
import time

$if enable_db ? {
	@[heap]
	struct ListenerFixture {
	mut:
		mu                sync.Mutex
		rt                Runtime
		bound             chan u64  = chan u64{cap: 1}
		continue_start    chan bool = chan bool{cap: 1}
		cleaning          chan bool = chan bool{cap: 1}
		continue_cleanup  chan bool = chan bool{cap: 1}
		finished          chan bool = chan bool{cap: 1}
		gate_dispatch     bool
		executing         chan bool = chan bool{cap: 1}
		continue_dispatch chan bool = chan bool{cap: 1}
		started_events    int
		cleaned           int
		pool_closed       chan bool = chan bool{cap: 1}
	}

	fn (mut fixture ListenerFixture) context() RuntimeContext {
		return RuntimeContext{
			lifecycle:            &fixture.rt.listener_owner
			mark_listen_error_fn: fn [mut fixture] (generation u64, message string) {
				fixture.mu.@lock()
				fixture.rt.mark_listen_error(generation, message)
				fixture.mu.unlock()
			}
			mark_started_fn:      fn [mut fixture] (generation u64, at i64) ?string {
				fixture.bound <- generation
				_ := <-fixture.continue_start
				fixture.mu.@lock()
				defer { fixture.mu.unlock() }
				return fixture.rt.mark_started(generation, at)
			}
			mark_stopped_fn:      fn [mut fixture] (generation u64) {
				fixture.mu.@lock()
				fixture.rt.mark_stopped(generation)
				fixture.mu.unlock()
				fixture.finished <- true
			}
			note_error_fn:        fn (_ string) {}
			cleanup_sessions_fn:  fn [mut fixture] () {
				fixture.cleaning <- true
				_ := <-fixture.continue_cleanup
				fixture.cleaned++
			}
			close_pool_fn:        fn [mut fixture] () { fixture.pool_closed <- true }
			build_server_ctx_fn:  fn [mut fixture] () ServerContext {
				return ServerContext{
					driver_fn:   fn () string { return 'sqlite' }
					dispatch_fn: fn [mut fixture] (_ Request) Response {
						if fixture.gate_dispatch {
							fixture.executing <- true
							_ := <-fixture.continue_dispatch
						}
						return Response.ok('sqlite')
					}
				}
			}
			emit_started_fn:      fn [mut fixture] (_ string, _ string) { fixture.started_events++ }
			emit_error_fn:        fn (_ string, _ string) {}
		}
	}

	fn db_listener_path() string {
		return '/tmp/vhttpd-db-owner-${os.getpid()}-${time.now().unix_micro()}.sock'
	}

	fn await_db_signal(ch chan bool) {
		select {
			_ := <-ch {
			}
			3 * time.second {
				panic('DB listener fixture timed out')
			}
		}
	}

	fn test_db_stop_during_publication_retains_reservation_through_cleanup() {
		mut fixture := &ListenerFixture{}
		ctx := fixture.context()
		path := db_listener_path()
		assert Server.start(ctx, path)
		mut generation := u64(0)
		select {
			token := <-fixture.bound {
				generation = token
			}
			3 * time.second {
				panic('DB did not bind')
			}
		}
		assert os.exists(path)
		fixture.mu.@lock()
		stopped := fixture.rt.request_stop() or { panic('no stopped generation') }
		fixture.mu.unlock()
		assert stopped == generation
		fixture.continue_start <- true
		await_db_signal(fixture.cleaning)
		assert !Server.start(ctx, path)
		assert os.exists(path)
		fixture.continue_cleanup <- true
		await_db_signal(fixture.finished)
		await_db_signal(fixture.pool_closed)
		fixture.rt.listener_owner.wait_stopped(generation)
		assert !os.exists(path)
		assert !fixture.rt.started
		assert fixture.started_events == 0
		assert fixture.cleaned == 1
		// A restarted generation must survive all late updates from the old run.
		next := fixture.rt.listener_owner.reserve() or { panic('cannot restart after cleanup') }
		listener := listener_runtime.listen(path) or { panic(err) }
		assert fixture.rt.listener_owner.publish(next, listener)
		assert fixture.rt.mark_started(next, 42) or { panic('restart not published') } == ''
		fixture.rt.mark_stopped(generation)
		fixture.rt.mark_listen_error(generation, 'late error')
		fixture.rt.listener_owner.wait_stopped(generation)
		assert fixture.rt.started
		assert fixture.rt.last_error == ''
		assert os.exists(path)
		assert fixture.rt.listener_owner.finish(next)
	}

	fn test_db_reserved_start_cancelled_before_bind_preserves_existing_path() {
		mut fixture := &ListenerFixture{}
		ctx := fixture.context()
		path := db_listener_path()
		os.write_file(path, 'keep') or { panic(err) }
		defer { os.rm(path) or {} }
		generation := fixture.rt.listener_owner.reserve() or { panic('no reservation') }
		fixture.rt.request_stop()
		Server.run_reserved(ctx, path, generation)
		assert os.read_file(path) or { panic(err) } == 'keep'
		assert fixture.cleaned == 0
		assert !fixture.rt.started
	}

	fn test_db_listen_failure_releases_reservation_without_cleaning_shared_pool() {
		mut fixture := &ListenerFixture{}
		ctx := fixture.context()
		path := db_listener_path()
		os.write_file(path, 'not a directory') or { panic(err) }
		defer { os.rm(path) or {} }
		Server.run(ctx, '${path}/child.sock')
		assert fixture.rt.last_error != ''
		assert fixture.cleaned == 0
		assert !fixture.rt.started
		generation := fixture.rt.listener_owner.reserve() or { panic('failed start kept reservation') }
		assert fixture.rt.listener_owner.finish(generation)
	}
	fn test_db_stop_waits_for_dispatch_before_session_and_pool_cleanup() {
		mut fixture := &ListenerFixture{ gate_dispatch: true }
		ctx := fixture.context()
		path := db_listener_path()
		assert Server.start(ctx, path)
		mut generation := u64(0)
		select {
			token := <-fixture.bound {
				generation = token
			}
			3 * time.second {
				panic('DB did not bind')
			}
		}
		fixture.continue_start <- true
		mut peer := unix.connect_stream(path) or { panic(err) }
		defer { peer.close() or {} }
		FrameCodec.write(mut peer, '{"op":"ping"}') or { panic(err) }
		await_db_signal(fixture.executing)
		fixture.rt.listener_owner.request_stop()
		assert !Server.start(ctx, path)
		// Dispatch is gated; cleanup must remain unreachable until it returns.
		select {
			_ := <-fixture.cleaning {
				panic('cleanup raced active dispatch')
			}
			150 * time.millisecond {
			}
		}
		assert fixture.rt.listener_owner.active_requests(generation) == 1
		assert fixture.pool_closed.len == 0
		fixture.continue_dispatch <- true
		await_db_signal(fixture.cleaning)
		assert fixture.rt.listener_owner.active_requests(generation) == 0
		assert fixture.pool_closed.len == 0
		assert !Server.start(ctx, path)
		fixture.continue_cleanup <- true
		await_db_signal(fixture.finished)
		await_db_signal(fixture.pool_closed)
		fixture.rt.listener_owner.wait_stopped(generation)
		assert !os.exists(path)
	}

	fn test_db_stop_drains_partial_frame_without_entering_dispatch() {
		mut fixture := &ListenerFixture{ gate_dispatch: true }
		ctx := fixture.context()
		path := db_listener_path()
		assert Server.start(ctx, path)
		mut generation := u64(0)
		select {
			token := <-fixture.bound {
				generation = token
			}
			3 * time.second {
				panic('DB did not bind')
			}
		}
		fixture.continue_start <- true
		mut peer := unix.connect_stream(path) or { panic(err) }
		defer { peer.close() or {} }
		peer.write([u8(0), 0, 0, 20, `{`]) or { panic(err) }
		deadline := time.now().add(3 * time.second)
		for fixture.rt.listener_owner.active_requests(generation) == 0 {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		fixture.rt.listener_owner.request_stop()
		await_db_signal(fixture.cleaning)
		assert fixture.rt.listener_owner.active_requests(generation) == 0
		assert fixture.executing.len == 0
		fixture.continue_cleanup <- true
		await_db_signal(fixture.finished)
		await_db_signal(fixture.pool_closed)
		fixture.rt.listener_owner.wait_stopped(generation)
		assert !os.exists(path)
	}
}

$if enable_db ? {
	fn test_db_bind_conflict_preserves_existing_listener_and_shared_pool() {
		path := db_listener_path()
		mut existing := unix.listen_stream(path) or { panic(err) }
		defer { existing.close() or {} }
		mut fixture := &ListenerFixture{}
		Server.run(fixture.context(), path)
		assert !fixture.rt.started
		assert fixture.rt.last_error != ''
		assert fixture.cleaned == 0
		mut peer := unix.connect_stream(path) or { panic(err) }
		peer.close() or { panic(err) }
		generation := fixture.rt.listener_owner.reserve() or { panic('reservation leaked') }
		assert fixture.rt.listener_owner.finish(generation)
	}
}
