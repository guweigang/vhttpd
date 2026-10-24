module worker

import upstream.transport
import json2 as json
import log

pub struct DispatchRuntime {}

pub struct DispatchContext {
pub:
	open_fn    fn () !WorkerBackendConnection @[required]
	finish_fn  fn (string)                    @[required]
	timeout_ms int
}

pub fn (ctx DispatchContext) open() !WorkerBackendConnection {
	return ctx.open_fn()
}

pub fn (ctx DispatchContext) finished(socket_path string) {
	ctx.finish_fn(socket_path)
}

pub fn DispatchRuntime.stream(ctx DispatchContext, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	mut worker_conn := ctx.open()!
	defer {
		worker_conn.close()
		ctx.finished(worker_conn.socket_path)
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	worker_conn.write_json(req)!
	return worker_conn.read_stream_response()!
}

pub fn DispatchRuntime.mcp(ctx DispatchContext, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut worker_conn := ctx.open()!
	defer {
		worker_conn.close()
		ctx.finished(worker_conn.socket_path)
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	worker_conn.write_json(req)!
	return worker_conn.read_mcp_response()!
}

pub fn DispatchRuntime.websocket_upstream(ctx DispatchContext, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut worker_conn := ctx.open()!
	defer {
		worker_conn.close()
		ctx.finished(worker_conn.socket_path)
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	raw_req := json.encode(req, escape_unicode: true, time_as_unix: true)
	log.info('[worker-transport] 📤 dispatching websocket_upstream: ${raw_req}')
	worker_conn.write_payload(raw_req)!
	return worker_conn.read_websocket_upstream_response()!
}

pub fn DispatchRuntime.websocket_event(ctx DispatchContext, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut worker_conn := ctx.open()!
	defer {
		worker_conn.close()
		ctx.finished(worker_conn.socket_path)
	}
	worker_conn.apply_read_timeout(ctx.timeout_ms)
	worker_conn.write_websocket_frame(frame)!
	return worker_conn.read_websocket_dispatch_response()!
}
