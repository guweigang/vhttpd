module main

import json
import net.unix
import worker

fn worker_index_by_socket_in_state_unlocked(ws &worker.WorkerState, socket_path string) int {
	for i, w in ws.worker_backend.managed_workers {
		if w.socket_path == socket_path {
			return i
		}
	}
	return -1
}

fn next_worker_socket_for_state(mut ws worker.WorkerState) ?string {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.worker_backend.sockets.len == 0 {
		return none
	}
	idx := ws.worker_backend.rr_index % ws.worker_backend.sockets.len
	socket_path := ws.worker_backend.sockets[idx]
	ws.worker_backend.rr_index = (idx + 1) % ws.worker_backend.sockets.len
	return socket_path
}

fn next_idle_worker_socket_for_state(mut ws worker.WorkerState) ?string {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.worker_backend.sockets.len == 0 {
		return none
	}
	for offset in 0 .. ws.worker_backend.sockets.len {
		idx := (ws.worker_backend.rr_index + offset) % ws.worker_backend.sockets.len
		socket_path := ws.worker_backend.sockets[idx]
		worker_idx := worker_index_by_socket_in_state_unlocked(ws, socket_path)
		if worker_idx < 0 || worker_idx >= ws.worker_backend.managed_workers.len {
			continue
		}
		mut w := ws.worker_backend.managed_workers[worker_idx]
		if w.draining || w.inflight_requests > 0 {
			continue
		}
		if !isnil(w.proc) && !w.proc.is_alive() {
			continue
		}
		ws.worker_backend.rr_index = (idx + 1) % ws.worker_backend.sockets.len
		return socket_path
	}
	return none
}

fn (mut app App) worker_backend_select_socket_for_state(kind string, mut ws worker.WorkerState) !string {
	app.ensure_workers_alive_for_state(mut ws)
	ws.mu.@lock()
	socket_len := ws.worker_backend.sockets.len
	autostart := ws.worker_backend.autostart
	managed_worker_len := ws.worker_backend.managed_workers.len
	ws.mu.unlock()
	if socket_len == 0 {
		return error('worker not configured for kind: ${kind}')
	}
	mut last_err := 'worker unavailable'
	mut draining_ready := []int{}
	if autostart && managed_worker_len > 0 {
		for _ in 0 .. socket_len {
			socket_path := next_idle_worker_socket_for_state(mut ws) or { break }
			mut probe_conn := unix.connect_stream(socket_path) or {
				last_err = err.msg()
				continue
			}
			probe_conn.close() or {}
			return socket_path
		}
		ws.mu.@lock()
		for idx, w in ws.worker_backend.managed_workers {
			if w.draining && w.inflight_requests == 0 {
				draining_ready << idx
			}
		}
		ws.mu.unlock()
		for idx in draining_ready {
			app.restart_worker_slot_now_for_state(mut ws, idx, 'drain_complete')
		}
		if last_err == 'worker unavailable' {
			last_err = 'all workers busy'
		}
		app.emit('worker.select.failed', {
			'kind':             kind
			'error':            last_err
			'diagnostics_json': json.encode(worker_selection_diagnostics_for_state(ws))
		})
		return error(last_err)
	}
	for _ in 0 .. socket_len {
		socket_path := next_worker_socket_for_state(mut ws) or { break }
		if autostart {
			ws.mu.@lock()
			idx := worker_index_by_socket_in_state_unlocked(ws, socket_path)
			if idx >= 0 && idx < ws.worker_backend.managed_workers.len {
				w := ws.worker_backend.managed_workers[idx]
				ws.mu.unlock()
				if w.draining {
					if w.inflight_requests == 0 {
						draining_ready << idx
					}
					last_err = 'all workers draining'
					continue
				}
				return socket_path
			}
			ws.mu.unlock()
		}
		mut probe_conn := unix.connect_stream(socket_path) or {
			last_err = err.msg()
			continue
		}
		probe_conn.close() or {}
		return socket_path
	}
	if autostart {
		for idx in draining_ready {
			app.restart_worker_slot_now_for_state(mut ws, idx, 'drain_complete')
		}
	}
	app.emit('worker.select.failed', {
		'kind':             kind
		'error':            last_err
		'diagnostics_json': json.encode(worker_selection_diagnostics_for_state(ws))
	})
	return error(last_err)
}

fn (mut app App) worker_backend_select_socket() !string {
	return app.worker_backend_select_socket_for_state(app.logic_executor_kind(), mut app.executors.worker)
}
