module protocol

import net
import sync
import time

#include <fcntl.h>

fn C.fcntl(fd i32, cmd i32, arg ...voidptr) i32

// One transferred TCP connection, independent of the session ID that routes to it.
// Only finish_stream closes it; cancellation uses an owned duplicate so a late
// stop cannot touch a recycled descriptor. Lock order: write_mu -> state.mu -> mu.
@[heap]
pub struct SessionStream {
	conn  &net.TcpConn @[required]
	token u64
mut:
	mu        sync.Mutex
	write_mu  sync.Mutex
	interrupt ?int
	stopping  bool
	closed    bool
	ready     bool
}

pub fn (mut stream SessionStream) request_stop() {
	stream.mu.@lock()
	defer { stream.mu.unlock() }
	stream.stopping = true
	if fd := stream.interrupt { net.shutdown(fd) }
}

pub fn (mut stream SessionStream) stopped() bool {
	stream.mu.@lock()
	defer { stream.mu.unlock() }
	return stream.stopping
}

pub fn (mut stream SessionStream) finished() bool {
	stream.mu.@lock()
	defer { stream.mu.unlock() }
	return stream.closed
}

pub fn (mut stream SessionStream) wait(delay time.Duration) bool {
	deadline := time.now().add(delay)
	for !stream.stopped() {
		remaining := deadline - time.now()
		if remaining <= 0 { return true }
		time.sleep(if remaining < 10 * time.millisecond { remaining } else { 10 * time.millisecond })
	}
	return false
}

// Header failure and cancellation leave cleanup with the caller until it hands
// the accepted stream to run_stream. No message can precede these headers.
pub fn (mut stream SessionStream) start(write_headers fn (mut net.TcpConn) !) ! {
	stream.write_mu.@lock()
	defer { stream.write_mu.unlock() }
	if stream.stopped() { return error('mcp_stream_stopped') }
	if stream.ready { return error('mcp_stream_already_started') }
	write_headers(mut stream.conn)!
	stream.conn.write_string(': connected\n\n')!
	stream.ready = true
}

pub fn (mut stream SessionStream) keepalive() bool {
	stream.write_mu.@lock()
	defer { stream.write_mu.unlock() }
	if stream.stopped() || !stream.ready { return false }
	stream.conn.write_string(': keepalive\n\n') or { return false }
	return true
}

fn (mut stream SessionStream) close() {
	stream.request_stop()
	stream.write_mu.@lock()
	defer { stream.write_mu.unlock() }
	stream.mu.@lock()
	defer { stream.mu.unlock() }
	if stream.closed { return }
	stream.conn.close() or {}
	if fd := stream.interrupt { net.close(fd) or {} }
	stream.interrupt = none
	stream.closed = true
}

// Ownership transfers only on success. Registration precedes header writing and
// spawn, so shutdown also waits for a delayed or failed HTTP handoff.
pub fn (mut s McpState) attach_stream(session_id string, conn &net.TcpConn) !&SessionStream {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if s.stopping { return error('mcp_stopping') }
	mut session := s.sessions[session_id] or { return error('mcp_session_missing') }
	fd := C.fcntl(conn.sock.handle, C.F_DUPFD_CLOEXEC, 0)
	if fd < 0 { return error('mcp_stream_interrupt_failed') }
	// The accepted socket also stays live until the stream owner finishes it.
	flags := C.fcntl(conn.sock.handle, C.F_GETFD, 0)
	if flags < 0 || C.fcntl(conn.sock.handle, C.F_SETFD, flags | C.FD_CLOEXEC) < 0 {
		net.close(fd) or {}
		return error('mcp_stream_native_cloexec_failed')
	}
	s.stream_counter++
	mut stream := &SessionStream{ conn: conn, token: s.stream_counter, interrupt: fd }
	if mut old := session.stream { old.request_stop() }
	session.stream = stream
	session.last_activity_unix = time.now().unix()
	s.sessions[session_id] = session
	s.streams[stream.token] = stream
	return stream
}

// Physical cleanup completes before identity-checked registry removal. A stale
// worker cannot unbind a replacement, including a deleted/recreated session ID.
pub fn (mut s McpState) finish_stream(session_id string, mut stream SessionStream) {
	stream.close()
	s.mu.@lock()
	defer { s.mu.unlock() }
	if mut session := s.sessions[session_id] {
		if current := session.stream {
			if current == &stream {
				session.stream = none
				session.last_activity_unix = time.now().unix()
				s.sessions[session_id] = session
			}
		}
	}
	if current := s.streams[stream.token] {
		if current == &stream { s.streams.delete(stream.token) }
	}
}

pub fn (mut s McpState) flush_session(session_id string) bool {
	s.mu.@lock()
	session := s.sessions[session_id] or {
		s.mu.unlock()
		return false
	}
	mut stream := session.stream or {
		s.mu.unlock()
		return false
	}
	s.mu.unlock()
	return s.flush_stream(session_id, mut stream)
}

// Serialize dequeue and complete SSE frames with headers, keepalive and close.
// A replaced worker must never drain the new connection's pending queue.
pub fn (mut s McpState) flush_stream(session_id string, mut stream SessionStream) bool {
	stream.write_mu.@lock()
	defer { stream.write_mu.unlock() }
	if stream.stopped() || !stream.ready { return false }
	s.mu.@lock()
	mut session := s.sessions[session_id] or {
		s.mu.unlock()
		return false
	}
	current := session.stream or {
		s.mu.unlock()
		return false
	}
	if current != &stream || s.stopping {
		s.mu.unlock()
		return false
	}
	pending := session.pending.clone()
	session.pending = []string{}
	session.last_activity_unix = time.now().unix()
	s.sessions[session_id] = session
	s.mu.unlock()
	for raw in pending {
		if !Session.write_sse_json(mut stream.conn, raw) { return false }
	}
	return true
}

pub fn (mut s McpState) run_stream(session_id string, mut stream SessionStream) {
	defer { s.finish_stream(session_id, mut stream) }
	mut last_keepalive_ms := time.now().unix_milli()
	for stream.wait(200 * time.millisecond) {
		if !s.flush_stream(session_id, mut stream) { return }
		now_ms := time.now().unix_milli()
		if now_ms - last_keepalive_ms >= 15_000 {
			if !stream.keepalive() { return }
			last_keepalive_ms = now_ms
		}
	}
}

// Notify first; process shutdown waits outside application/protocol locks.
pub fn (mut s McpState) request_stop() {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.stopping = true
	for id, mut session in s.sessions {
		session.dispatch = none
		s.sessions[id] = session
	}
	for _, mut stream in s.streams { stream.request_stop() }
}

pub fn (mut s McpState) active_streams() int {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.streams.len
}

pub fn (mut s McpState) wait_stopped() {
	for s.active_streams() > 0 { time.sleep(time.millisecond) }
}
