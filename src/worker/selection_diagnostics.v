module worker

import connection_runtime
import upstream.transport

pub fn (ws &WorkerState) selection_diagnostics() []transport.WorkerSelectionDiagnostic {
	mut diagnostics := []transport.WorkerSelectionDiagnostic{}
	ws.mu.@lock()
	if ws.worker_backend.sockets.len == 0 {
		ws.mu.unlock()
		return diagnostics
	}
	sockets := ws.worker_backend.sockets.clone()
	workers := ws.worker_backend.managed_workers.clone()
	ws.mu.unlock()
	for socket_path in sockets {
		mut worker_idx := -1
		for i, w in workers {
			if w.socket_path == socket_path {
				worker_idx = i
				break
			}
		}
		if worker_idx < 0 || worker_idx >= workers.len {
			diagnostics << transport.WorkerSelectionDiagnostic{
				socket_path: socket_path
				probe_error: 'worker_slot_missing'
			}
			continue
		}
		mut w := workers[worker_idx]
		mut probe_error := ''
		if w.draining {
			probe_error = 'worker_draining'
		} else if w.inflight_requests > 0 {
			probe_error = 'worker_busy'
		} else if w.process_exited() {
			probe_error = 'process_not_alive'
		} else {
			mut probe_conn := connection_runtime.dial_unix(socket_path) or {
				probe_error = err.msg()
				diagnostics << transport.WorkerSelectionDiagnostic{
					socket_path:       socket_path
					proc_alive:        w.process_alive()
					draining:          w.draining
					inflight_requests: w.inflight_requests
					probe_error:       probe_error
				}
				continue
			}
			probe_conn.close() or {}
		}
		diagnostics << transport.WorkerSelectionDiagnostic{
			socket_path:       socket_path
			proc_alive:        w.process_alive()
			draining:          w.draining
			inflight_requests: w.inflight_requests
			probe_error:       probe_error
		}
	}
	return diagnostics
}
