module executor

import net.http
import net.unix
import transport

// ExecutorHost provides the application runtime services that LogicExecutor
// implementations need. App in module main implements this interface.
pub interface ExecutorHost {
	// ── Worker backend dispatch ──
	worker_backend_select_socket_queued() !string
	worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
	worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
	worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse

	// ── Request tracking ──
	on_worker_request_started(socket_path string)
	on_worker_request_finished(socket_path string)

	// ── Worker backend config ──
	worker_read_timeout_ms() int

	// ── WebSocket open (wraps hub + frame processing) ──
	worker_websocket_open(mut conn &unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string)
}
