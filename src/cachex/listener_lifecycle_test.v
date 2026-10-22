module cachex

import net.unix
import os
import time

fn cache_listener_path() string {
	return '/tmp/vhttpd-cache-owner-${os.getpid()}-${time.now().unix_micro()}.sock'
}

fn cache_run_fixture(mut rt Runtime, path string, generation u64, done chan bool) {
	rt.run_reserved(path, generation)
	done <- true
}

fn await_cache_exit(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('cache listener did not stop')
		}
	}
}

fn test_cache_delayed_start_cannot_undo_stop_or_unlink_socket() {
	mut rt := Runtime.new(true, '')
	path := cache_listener_path()
	defer { os.rm(path) or {} }
	os.write_file(path, 'keep') or { panic(err) }
	generation := rt.reserve_start() or { panic('no reservation') }
	assert !rt.start(path)
	rt.request_stop()
	rt.run_reserved(path, generation)
	assert os.read_file(path) or { panic(err) } == 'keep'
	assert !rt.started
	assert rt.last_error == ''
}

fn test_cache_duplicate_start_stop_and_restart_preserve_socket_ownership() {
	mut value := Runtime.new(true, '')
	mut rt := &value
	path := cache_listener_path()
	for _ in 0 .. 3 {
		generation := rt.reserve_start() or { panic('no reservation') }
		done := chan bool{cap: 1}
		spawn cache_run_fixture(mut rt, path, generation, done)
		deadline := time.now().add(3 * time.second)
		for {
			rt.mu.@lock()
			started := rt.started
			rt.mu.unlock()
			if started { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		assert !rt.start(path)
		mut peer := unix.connect_stream(path) or { panic(err) }
		FrameCodec.write(mut peer, '{"op":"ping","namespace":"test"}') or { panic(err) }
		assert (FrameCodec.read(mut peer) or { panic(err) }).contains('"pong":true')
		peer.close() or { panic(err) }
		time.sleep(150 * time.millisecond)
		rt.request_stop()
		rt.request_stop()
		await_cache_exit(done)
		assert !os.exists(path)
		assert !rt.started
		assert rt.last_error == '' // Idle accept polling must not record errors.
	}
}

fn test_cache_listen_failure_releases_start_reservation() {
	mut rt := Runtime.new(true, '')
	path := cache_listener_path()
	os.write_file(path, 'not a directory') or { panic(err) }
	defer { os.rm(path) or {} }
	rt.run('${path}/child.sock')
	assert rt.last_error != ''
	assert !rt.started
	generation := rt.reserve_start() or { panic('failed start kept reservation') }
	assert rt.listener_owner.finish(generation)
}

fn test_cache_start_then_immediate_stop_cannot_resurrect_listener() {
	mut value := Runtime.new(true, '')
	mut rt := &value
	path := cache_listener_path()
	for _ in 0 .. 10 {
		assert rt.start(path)
		generation := rt.request_stop() or { panic('startup reservation missing') }
		deadline := time.now().add(3 * time.second)
		for rt.listener_owner.is_current(generation) {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		assert !rt.started
		assert !os.exists(path)
	}
}

fn test_cache_partial_frames_are_drained_before_restart() {
	mut value := Runtime.new(true, '')
	mut rt := &value
	path := cache_listener_path()
	for _ in 0 .. 3 {
		generation := rt.reserve_start() or { panic('no generation') }
		done := chan bool{cap: 1}
		spawn cache_run_fixture(mut rt, path, generation, done)
		deadline := time.now().add(3 * time.second)
		for {
			rt.mu.@lock()
			started := rt.started
			rt.mu.unlock()
			if started { break }
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		mut peer := unix.connect_stream(path) or { panic(err) }
		// A partial length header must not outlive its listener generation.
		peer.write([u8(0), 0]) or { panic(err) }
		for rt.listener_owner.active_requests(generation) == 0 {
			assert time.now() < deadline
			time.sleep(time.millisecond)
		}
		assert rt.request_stop() or { panic('no generation') } == generation
		await_cache_exit(done)
		rt.listener_owner.wait_stopped(generation)
		assert rt.listener_owner.active_requests(generation) == 0
		assert !os.exists(path)
		peer.close() or { panic(err) }
	}
}

fn test_cache_terminal_shutdown_before_start_prevents_late_publication() {
	mut rt := Runtime.new(true, '')
	path := cache_listener_path()
	assert rt.request_shutdown() == none
	assert !rt.start(path)
	assert !os.exists(path)
}

fn test_cache_terminal_shutdown_drains_partial_frame_and_rejects_restart() {
	mut rt := &Runtime{}
	path := cache_listener_path()
	assert rt.start(path)
	deadline := time.now().add(3 * time.second)
	for {
		rt.mu.@lock()
		started := rt.started
		rt.mu.unlock()
		if started { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	peer.write([u8(0), 0]) or { panic(err) }
	for rt.listener_owner.active_requests(1) == 0 {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	generation := rt.request_shutdown() or { panic('stop') }
	rt.listener_owner.wait_stopped(generation)
	assert rt.listener_owner.active_requests(generation) == 0
	assert !os.exists(path)
	assert !rt.start(path)
}

fn test_cache_start_preserves_other_listener_and_allows_retry_after_release() {
	path := cache_listener_path()
	mut existing := unix.listen_stream(path) or { panic(err) }
	mut rt := Runtime.new(true, '')
	rt.run(path)
	assert !rt.started
	assert rt.last_error != ''
	mut peer := unix.connect_stream(path) or { panic(err) }
	peer.close() or { panic(err) }
	existing.close() or { panic(err) }
	assert rt.start(path)
	generation := rt.request_stop() or { panic('reservation missing') }
	rt.listener_owner.wait_stopped(generation)
	assert !os.exists(path)
}
