module worker

import json
import net.unix
import upstream.transport

pub struct WorkerBackendFrameCodec {}

pub fn WorkerBackendFrameCodec.write(mut conn unix.StreamConn, payload string) ! {
	size := payload.len
	header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff),
		u8(size & 0xff)]
	conn.write_ptr(&header[0], 4)!
	conn.write_string(payload)!
}

pub fn WorkerBackendFrameCodec.read_exact(mut conn unix.StreamConn, size int) ![]u8 {
	mut out := []u8{len: size}
	mut read := 0
	for read < size {
		n := conn.read(mut out[read..])!
		if n <= 0 {
			return error('unexpected EOF')
		}
		read += n
	}
	return out
}

pub fn WorkerBackendFrameCodec.read(mut conn unix.StreamConn) !string {
	body := WorkerBackendFrameCodec.read_bytes(mut conn)!
	return body.bytestr()
}

pub fn WorkerBackendFrameCodec.read_bytes(mut conn unix.StreamConn) ![]u8 {
	header := WorkerBackendFrameCodec.read_exact(mut conn, 4)!
	size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
	size := int(size_u32)
	if size <= 0 || size > 16 * 1024 * 1024 {
		return error('invalid frame size ${size}')
	}
	return WorkerBackendFrameCodec.read_exact(mut conn, size)!
}

pub fn WorkerBackendFrameCodec.read_stream_response(mut conn unix.StreamConn) !transport.StreamDispatchResponse {
	raw := WorkerBackendFrameCodec.read(mut conn)!
	return json.decode(transport.StreamDispatchResponse, raw)!
}

pub fn WorkerBackendFrameCodec.read_mcp_response(mut conn unix.StreamConn) !transport.WorkerMcpDispatchResponse {
	raw := WorkerBackendFrameCodec.read(mut conn)!
	return json.decode(transport.WorkerMcpDispatchResponse, raw)!
}

pub fn WorkerBackendFrameCodec.read_websocket_upstream_response(mut conn unix.StreamConn) !transport.WorkerWebSocketUpstreamDispatchResponse {
	raw := WorkerBackendFrameCodec.read(mut conn)!
	return json.decode(transport.WorkerWebSocketUpstreamDispatchResponse, raw)!
}

pub fn WorkerBackendFrameCodec.read_websocket_frame(mut conn unix.StreamConn) !transport.WorkerWebSocketFrame {
	raw := WorkerBackendFrameCodec.read(mut conn)!
	return json.decode(transport.WorkerWebSocketFrame, raw)!
}

pub fn WorkerBackendFrameCodec.write_websocket_frame(mut conn unix.StreamConn, frame transport.WorkerWebSocketFrame) ! {
	WorkerBackendFrameCodec.write(mut conn, json.encode(frame))!
}

pub fn WorkerBackendFrameCodec.read_websocket_dispatch_response(mut conn unix.StreamConn) !transport.WorkerWebSocketDispatchResponse {
	raw := WorkerBackendFrameCodec.read(mut conn)!
	return json.decode(transport.WorkerWebSocketDispatchResponse, raw)!
}
