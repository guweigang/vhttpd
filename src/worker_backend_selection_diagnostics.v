module main

import upstream.transport
import net.unix
import worker

fn (mut app App) worker_selection_diagnostics() []transport.WorkerSelectionDiagnostic {
	return worker_selection_diagnostics_for_state(app.executors.worker)
}

fn worker_selection_diagnostics_for_state(ws &worker.WorkerState) []transport.WorkerSelectionDiagnostic {
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
				socket_path:  socket_path
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
