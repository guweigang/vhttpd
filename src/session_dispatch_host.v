module main

import worker
import upstream.transport

// Each logical session supplies worker RPCs from its retained generation.
struct SessionDispatchHost {
	snapshot WorkerBackendRequestSnapshot
}

fn (mut host SessionDispatchHost) worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return worker.DispatchRuntime.mcp(host.snapshot.dispatch_context(), req)
}

fn (mut host SessionDispatchHost) worker_backend_dispatch_websocket_event(req transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return worker.DispatchRuntime.websocket_event(host.snapshot.dispatch_context(), req)
}

fn (mut host SessionDispatchHost) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return worker.DispatchRuntime.stream(host.snapshot.dispatch_context(), req)
}

fn (mut host SessionDispatchHost) worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return worker.DispatchRuntime.websocket_upstream(host.snapshot.dispatch_context(), req)
}
