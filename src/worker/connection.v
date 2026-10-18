module worker

import json2 as json
import net.unix
import net
import sync
import time
import upstream.transport

// Value copies retain one transport owner. Only that owner closes the socket;
// an absent handle represents both unconnected and terminally closed wrappers.
pub struct WorkerBackendConnection {
	owner &WorkerConnectionOwner = &WorkerConnectionOwner{}
pub:
	socket_path string
}

@[heap]
struct WorkerConnectionOwner {
mut:
	mu      sync.Mutex
	io_mu   sync.Mutex
	closing bool
	conn    ?&unix.StreamConn
}

pub fn (mut c WorkerBackendConnection) apply_read_timeout(read_timeout_ms int) {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection() or { return }
	if read_timeout_ms > 0 { conn.set_read_timeout(time.millisecond * read_timeout_ms) }
}

pub fn (mut c WorkerBackendConnection) close() {
	mut owner := c.owner
	owner.mu.@lock()
	if !owner.closing {
		owner.closing = true
		// The original fd remains owned until the in-flight frame exits. Closing
		// callers cannot shutdown a descriptor already retired by another closer.
		if conn := owner.conn { net.shutdown(conn.sock.handle) }
	}
	owner.mu.unlock()
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	owner.mu.@lock()
	owned := owner.conn
	owner.conn = none
	owner.mu.unlock()
	if mut conn := owned { conn.close() or {} }
}

// Caller holds io_mu through the complete frame operation. Close first marks
// terminal admission, interrupts I/O, then takes io_mu before native close.
fn (mut owner WorkerConnectionOwner) open_connection() !&unix.StreamConn {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closing { return error('worker_connection_closed') }
	return owner.conn or { return error('worker_connection_closed') }
}

pub fn (mut c WorkerBackendConnection) write_payload(payload string) ! {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection()!
	WorkerBackendFrameCodec.write(mut conn, payload)!
}

pub fn (mut c WorkerBackendConnection) write_json[T](value T) ! {
	c.write_payload(json.encode(value, escape_unicode: true, time_as_unix: true))!
}

pub fn (mut c WorkerBackendConnection) read_stream_response() !transport.StreamDispatchResponse {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection()!
	return WorkerBackendFrameCodec.read_stream_response(mut conn)!
}

pub fn (mut c WorkerBackendConnection) read_mcp_response() !transport.WorkerMcpDispatchResponse {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection()!
	return WorkerBackendFrameCodec.read_mcp_response(mut conn)!
}

pub fn (mut c WorkerBackendConnection) read_websocket_upstream_response() !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection()!
	return WorkerBackendFrameCodec.read_websocket_upstream_response(mut conn)!
}

pub fn (mut c WorkerBackendConnection) read_websocket_dispatch_response() !transport.WorkerWebSocketDispatchResponse {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection()!
	return WorkerBackendFrameCodec.read_websocket_dispatch_response(mut conn)!
}

pub fn (mut c WorkerBackendConnection) write_websocket_frame(frame transport.WorkerWebSocketFrame) ! {
	mut owner := c.owner
	owner.io_mu.@lock()
	defer { owner.io_mu.unlock() }
	mut conn := owner.open_connection()!
	WorkerBackendFrameCodec.write_websocket_frame(mut conn, frame)!
}

// Ownership of conn transfers here; callers must not close the original alias.
pub fn WorkerBackendConnection.from_selected(socket_path string, conn unix.StreamConn) WorkerBackendConnection {
	mut owned := conn
	return WorkerBackendConnection{
		socket_path: socket_path
		owner:       &WorkerConnectionOwner{ conn: &owned }
	}
}
