module protocol

import net
import time

struct StreamPair {
	server &net.TcpConn @[required]
	peer   &net.TcpConn @[required]
}

fn stream_pair() StreamPair {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	peer.set_read_timeout(time.second)
	return StreamPair{ server: server, peer: peer }
}

fn no_headers(mut conn net.TcpConn) ! { _ = conn }

fn read_stream_text(mut peer net.TcpConn, marker string) string {
	mut text := ''
	mut bytes := []u8{len: 4096}
	for !text.contains(marker) {
		n := peer.read(mut bytes) or { panic(err) }
		assert n > 0
		text += bytes[..n].bytestr()
	}
	return text
}

fn wait_stream_done(done chan bool) {
	select {
		ok := <-done {
			assert ok
		}
		3 * time.second {
			panic('stream task did not finish')
		}
	}
}

fn stream_runner(mut state McpState, id string, mut stream SessionStream, done chan bool) {
	state.run_stream(id, mut stream)
	done <- true
}

fn test_replaced_stream_cannot_drain_or_unbind_new_connection() {
	mut state := McpState{}
	state.ensure_session('same', '', '', '', '')
	first := stream_pair()
	second := stream_pair()
	defer {
		mut p := first.peer
		p.close() or {}
		mut q := second.peer
		q.close() or {}
	}
	mut old := state.attach_stream('same', first.server) or { panic(err) }
	old.start(no_headers) or { panic(err) }
	mut next := state.attach_stream('same', second.server) or { panic(err) }
	defer { state.finish_stream('same', mut next) }
	next.start(no_headers) or { panic(err) }
	assert old.stopped()
	assert state.active_streams() == 2
	assert state.do_queue('same', '{"new":true}').queued
	assert !state.flush_stream('same', mut old)
	assert state.sessions['same'].pending == ['{"new":true}']
	state.finish_stream('same', mut old)
	state.finish_stream('same', mut old)
	assert state.active_streams() == 1
	assert state.sessions['same'].stream or { panic('replacement detached') } == next
	assert state.flush_stream('same', mut next)
	mut peer := second.peer
	assert read_stream_text(mut peer, 'data: {"new":true}\n\n') == ': connected\n\nevent: message\ndata: {"new":true}\n\n'
}

fn test_deleted_and_recreated_id_keeps_new_stream_owned() {
	mut state := McpState{}
	state.ensure_session('same', '', '', '', '')
	first := stream_pair()
	second := stream_pair()
	defer {
		mut p := first.peer
		p.close() or {}
		mut q := second.peer
		q.close() or {}
	}
	mut old := state.attach_stream('same', first.server) or { panic(err) }
	assert state.delete_session('same')
	assert old.stopped()
	state.ensure_session('same', '', '', '', '')
	mut next := state.attach_stream('same', second.server) or { panic(err) }
	defer { state.finish_stream('same', mut next) }
	state.finish_stream('same', mut old)
	assert !next.stopped()
	assert state.sessions['same'].stream or { panic('replacement detached') } == next
	assert state.active_streams() == 1
}

fn test_expiration_and_eviction_cancel_owned_streams_until_finished() {
	mut state := McpState{ session_ttl_seconds: 1, max_sessions: 1 }
	first := stream_pair()
	second := stream_pair()
	defer {
		mut p := first.peer
		p.close() or {}
		mut q := second.peer
		q.close() or {}
	}
	state.ensure_session('expired', '', '', '', '')
	mut expired := state.attach_stream('expired', first.server) or { panic(err) }
	state.mu.@lock()
	state.prune_sessions_locked(time.now().unix() + 2)
	state.mu.unlock()
	assert expired.stopped()
	assert state.stat_sessions_expired_total == 1
	assert state.active_streams() == 1
	state.ensure_session('evicted', '', '', '', '')
	mut evicted := state.attach_stream('evicted', second.server) or { panic(err) }
	state.ensure_session('new', '', '', '', '')
	assert evicted.stopped()
	assert state.stat_sessions_evicted_total == 1
	assert state.active_streams() == 2
	state.finish_stream('expired', mut expired)
	state.finish_stream('evicted', mut evicted)
	assert state.active_streams() == 0
}

fn test_failed_headers_remain_registered_until_physical_cleanup() {
	mut state := McpState{}
	state.ensure_session('failed', '', '', '', '')
	pair := stream_pair()
	defer {
		mut p := pair.peer
		p.close() or {}
	}
	mut stream := state.attach_stream('failed', pair.server) or { panic(err) }
	mut failed := false
	stream.start(fn (mut conn net.TcpConn) ! {
		_ = conn
		return error('headers_failed')
	}) or {
		assert err.msg() == 'headers_failed'
		failed = true
	}
	assert failed
	assert state.active_streams() == 1
	state.do_queue('failed', 'retained')
	assert !state.flush_session('failed')
	assert state.sessions['failed'].pending == ['retained']
	state.finish_stream('failed', mut stream)
	assert stream.finished()
	assert state.active_streams() == 0
	mut peer := pair.peer
	mut bytes := []u8{len: 1}
	n := peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}
	assert n == 0
}

fn test_stop_covers_pre_spawn_handoff_and_rejects_new_streams() {
	mut state := &McpState{}
	state.ensure_session('delayed', '', '', '', '')
	pair := stream_pair()
	other := stream_pair()
	defer {
		mut p := pair.peer
		p.close() or {}
		mut q := other.peer
		q.close() or {}
		mut c := other.server
		c.close() or {}
	}
	mut stream := state.attach_stream('delayed', pair.server) or { panic(err) }
	state.request_stop()
	assert stream.stopped()
	assert !stream.finished()
	if mut unexpected := state.attach_stream('delayed', other.server) {
		state.finish_stream('delayed', mut unexpected)
		panic('shutdown admitted another stream')
	} else {
		assert err.msg() == 'mcp_stopping'
	}
	done := chan bool{cap: 1}
	spawn fn [mut state, done] () {
		state.wait_stopped()
		done <- true
	}()
	select {
		_ := <-done {
			panic('shutdown forgot pending handoff')
		}
		20 * time.millisecond {
		}
	}
	state.finish_stream('delayed', mut stream)
	wait_stream_done(done)
	assert state.active_streams() == 0
}

fn test_running_streams_exit_after_broadcast_shutdown() {
	mut state := &McpState{}
	done := chan bool{cap: 4}
	mut peers := []&net.TcpConn{}
	for i in 0 .. 4 {
		id := 'session-${i}'
		state.ensure_session(id, '', '', '', '')
		pair := stream_pair()
		peers << pair.peer
		mut stream := state.attach_stream(id, pair.server) or { panic(err) }
		stream.start(no_headers) or { panic(err) }
		spawn stream_runner(mut state, id, mut stream, done)
	}
	state.request_stop()
	state.request_stop()
	for _ in 0 .. 4 { wait_stream_done(done) }
	state.wait_stopped()
	assert state.active_streams() == 0
	for mut peer in peers { peer.close() or {} }
	for _, session in state.sessions {
		assert session.stream == none
	}
}

fn test_shutdown_interrupts_infinite_socket_write_before_joining_close() {
	mut state := &McpState{}
	state.ensure_session('blocked', '', '', '', '')
	pair := stream_pair()
	defer {
		mut p := pair.peer
		p.close() or {}
	}
	mut stream := state.attach_stream('blocked', pair.server) or { panic(err) }
	started := chan bool{cap: 1}
	done := chan bool{cap: 1}
	payload := 'x'.repeat(16 * 1024 * 1024)
	spawn fn [mut state, mut stream, started, done, payload] () {
		stream.start(fn [started, payload] (mut conn net.TcpConn) ! {
			started <- true
			conn.write_string(payload)!
		}) or {}
		state.finish_stream('blocked', mut stream)
		done <- true
	}()
	wait_stream_done(started)
	state.request_stop()
	wait_stream_done(done)
	state.wait_stopped()
	assert stream.finished()
}

fn flush_fixture(mut state McpState, mut stream SessionStream, done chan bool) {
	assert state.flush_stream('serialized', mut stream)
	assert stream.keepalive()
	done <- true
}

fn test_concurrent_flush_and_keepalive_preserve_complete_sse_frames() {
	mut state := &McpState{}
	state.ensure_session('serialized', '', '', '', '')
	pair := stream_pair()
	defer {
		mut p := pair.peer
		p.close() or {}
	}
	mut stream := state.attach_stream('serialized', pair.server) or { panic(err) }
	defer { state.finish_stream('serialized', mut stream) }
	stream.start(no_headers) or { panic(err) }
	for i in 0 .. 100 { state.do_queue('serialized', '{"id":${i}}') }
	done := chan bool{cap: 8}
	for _ in 0 .. 8 { spawn flush_fixture(mut state, mut stream, done) }
	for _ in 0 .. 8 { wait_stream_done(done) }
	mut peer := pair.peer
	mut text := ''
	mut bytes := []u8{len: 4096}
	for text.count(': keepalive\n\n') < 8 {
		n := peer.read(mut bytes) or { panic(err) }
		assert n > 0
		text += bytes[..n].bytestr()
	}
	frames := text.split('\n\n').filter(it != '')
	assert frames.len == 109
	for i in 0 .. 100 {
		assert frames[i + 1] == 'event: message\ndata: {"id":${i}}'
	}
	assert state.sessions['serialized'].pending.len == 0
}

fn test_finished_stream_late_stop_does_not_interrupt_recycled_socket() {
	mut state := McpState{}
	state.ensure_session('old', '', '', '', '')
	first := stream_pair()
	defer {
		mut p := first.peer
		p.close() or {}
	}
	mut stream := state.attach_stream('old', first.server) or { panic(err) }
	state.finish_stream('old', mut stream)
	second := stream_pair()
	defer {
		mut p := second.peer
		p.close() or {}
		mut c := second.server
		c.close() or {}
	}
	stream.request_stop()
	state.finish_stream('old', mut stream)
	mut server := second.server
	server.write_string('still alive') or { panic(err) }
	mut peer := second.peer
	assert read_stream_text(mut peer, 'still alive') == 'still alive'
}
