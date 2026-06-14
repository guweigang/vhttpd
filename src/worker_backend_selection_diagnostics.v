module main

import upstream.transport
import net.unix

fn (mut app App) worker_selection_diagnostics() []transport.WorkerSelectionDiagnostic {
	mut diagnostics := []transport.WorkerSelectionDiagnostic{}
	app.executors.worker.mu.@lock()
	if app.executors.worker.worker_backend.sockets.len == 0 {
		app.executors.worker.mu.unlock()
		return diagnostics
	}
	sockets := app.executors.worker.worker_backend.sockets.clone()
	workers := app.executors.worker.worker_backend.managed_workers.clone()
	app.executors.worker.mu.unlock()
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
		} else if !isnil(w.proc) && !w.proc.is_alive() {
			probe_error = 'process_not_alive'
		} else {
			mut probe_conn := unix.connect_stream(socket_path) or {
				probe_error = err.msg()
				diagnostics << transport.WorkerSelectionDiagnostic{
					socket_path:       socket_path
					proc_alive:        !isnil(w.proc) && w.proc.is_alive()
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
			proc_alive:        !isnil(w.proc) && w.proc.is_alive()
			draining:          w.draining
			inflight_requests: w.inflight_requests
			probe_error:       probe_error
		}
	}
	return diagnostics
}
