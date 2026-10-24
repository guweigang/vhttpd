module executor

import net.http
import net.unix
import upstream.transport

// These hosts deliberately implement one capability each.
struct ConfigOnlyHost {}

fn (_ ConfigOnlyHost) worker_backend_read_timeout_ms() int { return 123 }

fn (_ ConfigOnlyHost) worker_backend_read_timeout_ms_for_kind(_kind string) int { return 123 }

fn (_ ConfigOnlyHost) worker_backend_sockets_len() int { return 1 }

fn (_ ConfigOnlyHost) worker_env() map[string]string {
	return {
		'pool': 'primary'
	}
}

fn (_ ConfigOnlyHost) worker_env_for_kind(kind string) map[string]string {
	return {
		'pool': kind
	}
}

struct SocketOnlyHost {
mut:
	started  int
	finished int
	released int
}

fn (mut _ SocketOnlyHost) worker_backend_select_socket_queued() !string {
	return error('no_socket')
}

fn (mut _ SocketOnlyHost) worker_backend_select_socket_for_kind(kind string) !string {
	return error('no_socket:' + kind)
}

fn (mut h SocketOnlyHost) on_worker_request_started(_socket string) { h.started++ }

fn (mut h SocketOnlyHost) on_worker_request_finished(_socket string) { h.finished++ }

fn (mut h SocketOnlyHost) on_worker_request_released(_socket string) { h.released++ }

fn (mut _ SocketOnlyHost) worker_websocket_open(mut _conn unix.StreamConn, _req http.Request, _remote string, _path string, _id string, _trace string) !(bool, int, string) {
	return false, 403, 'denied'
}

fn test_config_and_socket_ports_accept_minimal_live_hosts() {
	config := worker_backend_config_port(ConfigOnlyHost{})
	assert config.worker_backend_read_timeout_ms() == 123
	assert config.worker_env_for_kind('php-cgi')['pool'] == 'php-cgi'
	mut host := &SocketOnlyHost{}
	mut sockets := worker_socket_port(host)
	sockets.on_worker_request_started('worker.sock')
	sockets.on_worker_request_finished('worker.sock')
	sockets.on_worker_request_released('worker.sock')
	assert host.started == 1
	assert host.finished == 1
	assert host.released == 1
}

fn test_http_executor_cores_require_only_worker_capabilities() {
	config := ConfigOnlyHost{}
	mut socket := SocketOnlyHost{}
	if _ := (SocketWorkerExecutor{}).dispatch_http_with_worker_ports(mut socket, config, HttpLogicDispatchRequest{}) {
		assert false
	} else {
		assert err.msg() == 'no_socket:php'
	}
	if _ := (PhpCgiExecutor{}).dispatch_http_with_worker_ports(mut socket, config, HttpLogicDispatchRequest{}) {
		assert false
	} else {
		assert err.msg() == 'no_socket:php-cgi'
	}
}

struct StreamOnlyHost {
mut:
	calls int
}

fn (mut h StreamOnlyHost) worker_backend_dispatch_stream(_req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	h.calls++
	return transport.StreamDispatchResponse{}
}

struct McpOnlyHost {
mut:
	calls int
}

fn (mut h McpOnlyHost) worker_backend_dispatch_mcp(_req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	h.calls++
	return transport.WorkerMcpDispatchResponse{}
}

struct WebSocketOnlyHost {
mut:
	calls int
}

fn (mut h WebSocketOnlyHost) worker_backend_dispatch_websocket_upstream(_req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	h.calls++
	return transport.WorkerWebSocketUpstreamDispatchResponse{}
}

fn (mut h WebSocketOnlyHost) worker_backend_dispatch_websocket_event(_frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	h.calls++
	return transport.WorkerWebSocketDispatchResponse{}
}

fn (mut h WebSocketOnlyHost) execute_websocket_dispatch_commands_result(_frames []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	h.calls++
	return transport.WorkerWebSocketDispatchCommandsResult{}
}

fn test_dispatch_ports_accept_hosts_without_other_app_capabilities() {
	mut stream := &StreamOnlyHost{}
	mut stream_port := worker_stream_dispatch_port(stream)
	stream_port.worker_backend_dispatch_stream(transport.StreamDispatchRequest{}) or { panic(err) }
	assert stream.calls == 1
	mut mcp := &McpOnlyHost{}
	mut mcp_port := worker_mcp_dispatch_port(mcp)
	mcp_port.worker_backend_dispatch_mcp(transport.WorkerMcpDispatchRequest{}) or { panic(err) }
	assert mcp.calls == 1
	mut websocket := &WebSocketOnlyHost{}
	mut websocket_port := worker_websocket_dispatch_port(websocket)
	websocket_port.worker_backend_dispatch_websocket_upstream(transport.WorkerWebSocketUpstreamDispatchRequest{}) or { panic(err) }
	websocket_port.worker_backend_dispatch_websocket_event(transport.WorkerWebSocketFrame{}) or { panic(err) }
	_ = websocket_port.execute_websocket_dispatch_commands_result([])
	assert websocket.calls == 3
}
