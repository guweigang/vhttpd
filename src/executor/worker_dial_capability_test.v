module executor

import net.unix
import net.http

struct SlotDialHost {
	NoOpAppFacade
mut:
	dialed   int
	released int
	finished int
}

fn (mut host SlotDialHost) worker_backend_select_socket_queued() !string {
	return '/tmp/fenced-slot.sock'
}

fn (mut host SlotDialHost) worker_backend_select_socket_for_kind(kind string) !string {
	return '/tmp/fenced-slot.sock'
}

fn (mut host SlotDialHost) worker_backend_connect_selected(path string) !&unix.StreamConn {
	host.dialed++
	return error('worker_slot_restarted')
}

fn (mut host SlotDialHost) on_worker_request_released(path string) { host.released++ }

fn (mut host SlotDialHost) on_worker_request_finished(path string) { host.finished++ }

fn test_builtin_transports_use_owned_dial_capability_before_native_connect() {
	for kind in ['http', 'fastcgi', 'websocket'] {
		mut host := SlotDialHost{}
		match kind {
			'http' {
				if _ := SocketWorkerExecutor{}.dispatch_http_with_worker_ports(mut host, host, HttpLogicDispatchRequest{}) {
					assert false
				} else {
					assert err.msg() == 'worker_slot_restarted'
				}
			}
			'fastcgi' {
				if _ := PhpCgiExecutor{}.dispatch_http_with_worker_ports(mut host, host, HttpLogicDispatchRequest{}) {
					assert false
				} else {
					assert err.msg() == 'worker_slot_restarted'
				}
			}
			else {
				if _ := SocketWorkerExecutor{}.open_websocket_session_with_worker_ports(mut host, host, WebSocketSessionOpenRequest{
					register_conn_fn: fn (_ int) bool {
						return true
					}
					req:              http.Request{}
				}) {
					assert false
				} else {
					assert err.msg() == 'worker_slot_restarted'
				}
			}
		}
		assert host.dialed == 1
		assert host.released == 1
		assert host.finished == 0
	}
}
