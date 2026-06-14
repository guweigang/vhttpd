module main

import json
import net.unix

fn (mut app App) next_worker_socket() ?string {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	if app.executors.worker.worker_backend.sockets.len == 0 {
		return none
	}
	idx := app.executors.worker.worker_backend.rr_index % app.executors.worker.worker_backend.sockets.len
	socket_path := app.executors.worker.worker_backend.sockets[idx]
	app.executors.worker.worker_backend.rr_index = (idx + 1) % app.executors.worker.worker_backend.sockets.len
	return socket_path
}

fn (mut app App) next_idle_worker_socket() ?string {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	if app.executors.worker.worker_backend.sockets.len == 0 {
		return none
	}
	for offset in 0 .. app.executors.worker.worker_backend.sockets.len {
		idx := (app.executors.worker.worker_backend.rr_index + offset) % app.executors.worker.worker_backend.sockets.len
		socket_path := app.executors.worker.worker_backend.sockets[idx]
		worker_idx := app.worker_index_by_socket_unlocked(socket_path)
		if worker_idx < 0 || worker_idx >= app.executors.worker.worker_backend.managed_workers.len {
			continue
		}
		mut w := app.executors.worker.worker_backend.managed_workers[worker_idx]
		if w.draining || w.inflight_requests > 0 {
			continue
		}
		if !isnil(w.proc) && !w.proc.is_alive() {
			continue
		}
		app.executors.worker.worker_backend.rr_index = (idx + 1) % app.executors.worker.worker_backend.sockets.len
		return socket_path
	}
	return none
}

fn (mut app App) worker_backend_select_socket() !string {
	app.ensure_workers_alive()
	app.executors.worker.mu.@lock()
	socket_len := app.executors.worker.worker_backend.sockets.len
	autostart := app.executors.worker.worker_backend.autostart
	managed_worker_len := app.executors.worker.worker_backend.managed_workers.len
	app.executors.worker.mu.unlock()
	if socket_len == 0 {
		return error('worker not configured')
	}
	mut last_err := 'worker unavailable'
	mut draining_ready := []int{}
	if autostart && managed_worker_len > 0 {
		for _ in 0 .. socket_len {
			socket_path := app.next_idle_worker_socket() or { break }
			mut probe_conn := unix.connect_stream(socket_path) or {
				last_err = err.msg()
				continue
			}
			probe_conn.close() or {}
			return socket_path
		}
		app.executors.worker.mu.@lock()
		for idx, w in app.executors.worker.worker_backend.managed_workers {
			if w.draining && w.inflight_requests == 0 {
				draining_ready << idx
			}
		}
		app.executors.worker.mu.unlock()
		for idx in draining_ready {
			app.restart_worker_slot_now(idx, 'drain_complete')
		}
		if last_err == 'worker unavailable' {
			last_err = 'all workers busy'
		}
		app.emit('worker.select.failed', {
			'error':            last_err
			'diagnostics_json': json.encode(app.worker_selection_diagnostics())
		})
		return error(last_err)
	}
	for _ in 0 .. socket_len {
		socket_path := app.next_worker_socket() or { break }
		if autostart {
			app.executors.worker.mu.@lock()
			idx := app.worker_index_by_socket_unlocked(socket_path)
			if idx >= 0 && idx < app.executors.worker.worker_backend.managed_workers.len {
				w := app.executors.worker.worker_backend.managed_workers[idx]
				app.executors.worker.mu.unlock()
				if w.draining {
					if w.inflight_requests == 0 {
						draining_ready << idx
					}
					last_err = 'all workers draining'
					continue
				}
				return socket_path
			}
			app.executors.worker.mu.unlock()
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
			app.restart_worker_slot_now(idx, 'drain_complete')
		}
	}
	app.emit('worker.select.failed', {
		'error':            last_err
		'diagnostics_json': json.encode(app.worker_selection_diagnostics())
	})
	return error(last_err)
}
