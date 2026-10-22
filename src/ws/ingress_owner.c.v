module ws

import net
import net.websocket
import sync
import time

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int

// Sessions and asynchronous writes reserve before spawn. Only the serving
// scope closes original sockets; cancellation owns separate CLOEXEC handles.
@[heap]
pub struct IngressOwner {
mut:
	mu     sync.Mutex
	closed bool
	next   u64
	runs   map[u64]&IngressRun
}

@[heap]
pub struct IngressRun {
	owner &IngressOwner @[required]
	id    u64
mut:
	mu       sync.Mutex
	stopping bool
	done     bool
	handles  []int
}

pub fn (mut owner IngressOwner) reserve() ?&IngressRun {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed { return none }
	owner.next++
	run := &IngressRun{ owner: &owner, id: owner.next }
	owner.runs[run.id] = run
	return run
}

pub fn (mut run IngressRun) attach(fd int) bool {
	run.mu.@lock()
	defer { run.mu.unlock() }
	if run.stopping || run.done { return false }
	owned := C.fcntl(fd, C.F_DUPFD_CLOEXEC, 0)
	if owned < 0 { return false }
	// Protect the caller-owned socket too before publishing this attachment.
	flags := C.fcntl(fd, C.F_GETFD, 0)
	if flags < 0 || C.fcntl(fd, C.F_SETFD, flags | C.FD_CLOEXEC) < 0 {
		net.close(owned) or {}
		return false
	}
	run.handles << owned
	return true
}

pub fn (mut run IngressRun) child() ?&IngressRun {
	mut owner := run.owner
	mut task := owner.reserve() or { return none }
	run.mu.@lock()
	attached := !run.stopping && !run.done && run.handles.len > 0 && task.attach(run.handles[0])
	run.mu.unlock()
	if !attached {
		task.finish()
		return none
	}
	return task
}

pub fn (mut run IngressRun) stopped() bool {
	run.mu.@lock()
	defer { run.mu.unlock() }
	return run.stopping
}

pub fn (mut run IngressRun) request_stop() {
	run.mu.@lock()
	defer { run.mu.unlock() }
	run.stopping = true
	for fd in run.handles { net.shutdown(fd) }
}

// Called after native callbacks, hub cleanup and original socket release.
pub fn (mut run IngressRun) finish() {
	run.mu.@lock()
	if run.done {
		run.mu.unlock()
		return
	}
	for fd in run.handles { net.close(fd) or {} }
	run.handles.clear()
	run.stopping = true
	run.done = true
	run.mu.unlock()
	mut owner := run.owner
	owner.mu.@lock()
	owner.runs.delete(run.id)
	owner.mu.unlock()
}

pub fn (mut owner IngressOwner) request_stop() {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	owner.closed = true
	for _, mut run in owner.runs { run.request_stop() }
}

pub fn (mut owner IngressOwner) wait() {
	for {
		owner.mu.@lock()
		empty := owner.runs.len == 0
		owner.mu.unlock()
		if empty { return }
		time.sleep(time.millisecond)
	}
}

pub fn (mut owner IngressOwner) active() int {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return owner.runs.len
}

// A close task sends through its own retained descriptor, then wakes the sole
// reader. It never calls Client.close concurrently with that reader's cleanup.
fn (run &IngressRun) writer_conn() &net.TcpConn {
	fd := run.handles[0]
	return &net.TcpConn{
		sock:        net.TcpSocket{ Socket: net.Socket{ handle: fd } }
		handle:      fd
		is_blocking: true
	}
}

fn (mut run IngressRun) write_client_close(client &websocket.Client, code int, reason string) {
	if run.stopped() || client.is_ssl { return }
	// This immutable pre-listen snapshot retains the shared write lock/state and protocol role.
	// Only the writer's TCP reference changes; it never closes the native Client.
	mut writer := *client
	writer.conn = run.writer_conn()
	text := if reason.len <= 123 { reason } else { '' }
	mut payload := [u8(code >> 8), u8(code & 255)]
	payload << text.bytes()
	writer.write(payload, .close) or {}
}

// The SDK permits one accept callback. Keep capture there and application
// publication in on_attached, after the upgrade response succeeds.
pub fn managed_server() (&websocket.Server, &HandshakeClient) {
	mut server := websocket.new_server(.ip, 0, '')
	mut captured := &HandshakeClient{}
	server.on_connect(fn [mut captured] (mut sc websocket.ServerClient) !bool {
		captured.client = sc.client
		return true
	}) or { panic(err) }
	return server, captured
}

pub fn managed_handshake(mut server websocket.Server, mut conn net.TcpConn, key string, captured &HandshakeClient) ! {
	defer {
		if mut client := captured.client {
			if client.get_state() == .open { client.close(1000, 'session ended') or {} }
		} else {
			conn.close() or {}
		}
	}
	server.handle_handshake(mut conn, key)!
}

@[heap]
pub struct HandshakeClient {
mut:
	client ?&websocket.Client
}
