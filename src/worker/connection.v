module worker

import json
import net.unix
import time
import transport

pub struct WorkerBackendConnection {
pub:
	socket_path string
mut:
	conn unix.StreamConn
}

pub fn (mut c WorkerBackendConnection) apply_read_timeout(read_timeout_ms int) {
	if read_timeout_ms > 0 {
		c.conn.set_read_timeout(time.millisecond * read_timeout_ms)
	}
}

pub fn (mut c WorkerBackendConnection) close() {
	c.conn.close() or {}
}

pub fn (mut c WorkerBackendConnection) write_payload(payload string) ! {
	WorkerBackendFrameCodec.write(mut c.conn, payload)!
}

pub fn (mut c WorkerBackendConnection) write_json[T](value T) ! {
	c.write_payload(json.encode(value))!
}

pub fn (mut c WorkerBackendConnection) read_stream_response() !transport.StreamDispatchResponse {
	return WorkerBackendFrameCodec.read_stream_response(mut c.conn)!
}

pub fn (mut c WorkerBackendConnection) read_mcp_response() !transport.WorkerMcpDispatchResponse {
	return WorkerBackendFrameCodec.read_mcp_response(mut c.conn)!
}

pub fn (mut c WorkerBackendConnection) read_websocket_upstream_response() !transport.WorkerWebSocketUpstreamDispatchResponse {
	return WorkerBackendFrameCodec.read_websocket_upstream_response(mut c.conn)!
}

pub fn (mut c WorkerBackendConnection) write_websocket_frame(frame transport.WorkerWebSocketFrame) ! {
	WorkerBackendFrameCodec.write_websocket_frame(mut c.conn, frame)!
}

pub fn (mut c WorkerBackendConnection) read_websocket_dispatch_response() !transport.WorkerWebSocketDispatchResponse {
	return WorkerBackendFrameCodec.read_websocket_dispatch_response(mut c.conn)!
}

pub fn WorkerBackendConnection.from_selected(socket_path string, conn unix.StreamConn) WorkerBackendConnection {
	return WorkerBackendConnection{
		socket_path: socket_path
		conn:        conn
	}
}
