module executor

import net.http
import net.unix
import os
import time

@[heap]
struct OpenOwnershipHost {
	path string
mut:
	registered bool
	opened     int
	finished   int
	released   int
}

fn (h OpenOwnershipHost) worker_backend_read_timeout_ms() int { return 1000 }

fn (h OpenOwnershipHost) worker_backend_sockets_len() int { return 1 }

fn (h OpenOwnershipHost) worker_env() map[string]string { return {} }

fn (h OpenOwnershipHost) worker_env_for_kind(_ string) map[string]string { return {} }

fn (h OpenOwnershipHost) worker_backend_read_timeout_ms_for_kind(_ string) int { return 1000 }

fn (mut h OpenOwnershipHost) worker_backend_select_socket_queued() !string { return h.path }

fn (mut h OpenOwnershipHost) worker_backend_select_socket_for_kind(_ string) !string {
	return h.path
}

fn (mut h OpenOwnershipHost) on_worker_request_started(_ string) {}

fn (mut h OpenOwnershipHost) on_worker_request_finished(_ string) { h.finished++ }

fn (mut h OpenOwnershipHost) on_worker_request_released(_ string) { h.released++ }

fn (mut h OpenOwnershipHost) worker_websocket_open(mut _ unix.StreamConn, _ http.Request, _ string, _ string, _ string, _ string) !(bool, int, string) {
	assert h.registered
	h.opened++
	return false, 403, 'denied'
}

fn test_worker_websocket_registers_connected_socket_before_open_and_releases_rejection() {
	for allowed in [false, true] {
		root := os.join_path(os.temp_dir(), 'ws-open-${os.getpid()}-${time.now().unix_micro()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		mut listener := unix.listen_stream(root + '/worker.sock') or { panic(err) }
		defer { listener.close() or {} }
		mut host := &OpenOwnershipHost{ path: root + '/worker.sock' }
		result := SocketWorkerExecutor{}.open_websocket_session_with_worker_ports(mut host, host, WebSocketSessionOpenRequest{
			register_conn_fn: fn [mut host, allowed] (fd int) bool {
				assert fd >= 0
				host.registered = true
				return allowed
			}
		}) or {
			assert !allowed
			assert err.msg() == 'websocket_session_stopping'
			WebSocketSessionOpenOutcome{}
		}
		assert !result.accepted
		assert host.registered
		assert host.opened == if allowed { 1 } else { 0 }
		assert host.finished == if allowed { 1 } else { 0 }
		assert host.released == if allowed { 0 } else { 1 }
		mut accepted := listener.accept() or { panic(err) }
		defer { accepted.close() or {} }
		accepted.set_read_timeout(time.second)
		mut bytes := []u8{len: 1}
		assert (accepted.read(mut bytes) or { 0 }) == 0
	}
}
