module main

import executor
import worker
import net.http
import net.unix

// A transport request holds its selected state and config even after publication.
@[heap]
struct WorkerRequestHost {
	request           &WorkerRequestLeaseHost @[required]
	websocket_open_fn fn (mut unix.StreamConn, http.Request, string, string, string, string) !(bool, int, string) @[required]
}

fn worker_request_host(state &worker.WorkerState, mut facade executor.AppFacade) &WorkerRequestHost {
	mut retained := facade
	port := worker.LifecyclePort{
		emit_fn: fn [mut retained] (kind string, fields map[string]string) {
			retained.emit(kind, fields)
		}
	}
	return &WorkerRequestHost{
		request:           &WorkerRequestLeaseHost{ snapshot: new_worker_backend_request_snapshot(state, port) }
		websocket_open_fn: fn [mut retained] (mut conn unix.StreamConn, req http.Request, remote string, path string, id string, trace string) !(bool, int, string) {
			return retained.worker_websocket_open(mut conn, req, remote, path, id, trace)
		}
	}
}

fn (host &WorkerRequestHost) worker_backend_read_timeout_ms() int {
	return host.request.snapshot.timeout_ms
}

fn (host &WorkerRequestHost) worker_backend_read_timeout_ms_for_kind(_kind string) int {
	return host.request.snapshot.timeout_ms
}

fn (host &WorkerRequestHost) worker_backend_sockets_len() int {
	return host.request.snapshot.socket_count
}

fn (host &WorkerRequestHost) worker_env() map[string]string {
	return host.request.snapshot.env.clone()
}

fn (host &WorkerRequestHost) worker_env_for_kind(_kind string) map[string]string {
	return host.request.snapshot.env.clone()
}

fn (mut host WorkerRequestHost) worker_backend_select_socket_queued() !string {
	return host.request.select_socket()
}

fn (mut host WorkerRequestHost) worker_backend_select_socket_for_kind(_kind string) !string {
	return host.request.select_socket()
}

fn (mut host WorkerRequestHost) on_worker_request_started(socket string) {
	mut state := host.request.snapshot.state
	state.request_started(socket)
}

fn (mut host WorkerRequestHost) on_worker_request_finished(socket string) {
	host.request.finish(socket)
}

fn (mut host WorkerRequestHost) on_worker_request_released(socket string) {
	host.request.release(socket)
}

fn (mut host WorkerRequestHost) worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote string, path string, id string, trace string) !(bool, int, string) {
	return host.websocket_open_fn(mut conn, req, remote, path, id, trace)
}

fn (mut host WorkerRequestHost) worker_backend_connect_selected(path string) !&unix.StreamConn {
	return host.request.connect(path)
}
