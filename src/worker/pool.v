module worker

import connection_runtime
import json2 as json

fn (ws &WorkerState) index_by_socket_unlocked(socket_path string) int {
	for i, w in ws.worker_backend.managed_workers {
		if w.socket_path == socket_path {
			return i
		}
	}
	return -1
}

pub fn (mut ws WorkerState) next_socket() ?string {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.backend_admission_error_unlocked() != '' || ws.worker_backend.sockets.len == 0 {
		return none
	}
	idx := ws.worker_backend.rr_index % ws.worker_backend.sockets.len
	socket_path := ws.worker_backend.sockets[idx]
	ws.worker_backend.rr_index = (idx + 1) % ws.worker_backend.sockets.len
	return socket_path
}

pub fn (mut ws WorkerState) lease_idle_socket() ?string {
	lease := ws.lease_idle_request() or { return none }
	return lease.socket_path
}

fn (mut ws WorkerState) lease_idle_request() ?&RequestLease {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.backend_admission_error_unlocked() != '' || ws.worker_backend.sockets.len == 0 {
		return none
	}
	for offset in 0 .. ws.worker_backend.sockets.len {
		idx := (ws.worker_backend.rr_index + offset) % ws.worker_backend.sockets.len
		socket_path := ws.worker_backend.sockets[idx]
		worker_idx := ws.index_by_socket_unlocked(socket_path)
		if worker_idx < 0 || worker_idx >= ws.worker_backend.managed_workers.len {
			continue
		}
		mut w := ws.worker_backend.managed_workers[worker_idx]
		if w.draining || w.inflight_requests > 0 || !ws.slot_available_unlocked(socket_path) {
			continue
		}
		if w.process_exited() {
			continue
		}
		w.inflight_requests++
		ws.worker_backend.managed_workers[worker_idx] = w
		ws.worker_backend.rr_index = (idx + 1) % ws.worker_backend.sockets.len
		return &RequestLease{ socket_path: socket_path, state: &ws, generation: ws.slot_generation_unlocked(socket_path) }
	}
	return none
}

fn (mut ws WorkerState) select_socket_core(port LifecyclePort, kind string) !string {
	lease := ws.select_request_core(port, kind)!
	return lease.socket_path
}

struct SlotRestartCandidate {
	idx        int
	generation &SlotGeneration @[required]
}

fn (mut ws WorkerState) select_request_core(port LifecyclePort, kind string) !&RequestLease {
	ws.ensure_alive(port)
	ws.mu.@lock()
	admission_error := ws.backend_admission_error_unlocked()
	if admission_error != '' {
		ws.mu.unlock()
		return error(admission_error)
	}
	socket_len := ws.worker_backend.sockets.len
	autostart := ws.worker_backend.autostart
	managed_worker_len := ws.worker_backend.managed_workers.len
	ws.mu.unlock()
	if socket_len == 0 {
		return error('worker not configured for kind: ${kind}')
	}
	mut last_err := 'worker unavailable'
	mut draining_ready := []SlotRestartCandidate{}
	if autostart && managed_worker_len > 0 {
		for _ in 0 .. socket_len {
			lease := ws.lease_idle_request() or { break }
			return lease
		}
		ws.mu.@lock()
		for idx, w in ws.worker_backend.managed_workers {
			if w.draining && w.inflight_requests == 0 {
				draining_ready << SlotRestartCandidate{ idx: idx, generation: ws.slot_generation_unlocked(w.socket_path) }
			}
		}
		ws.mu.unlock()
		for candidate in draining_ready {
			ws.restart_slot_generation(port, candidate.idx, candidate.generation, 'drain_complete')
		}
		if last_err == 'worker unavailable' {
			last_err = 'all workers busy'
		}
		return error(last_err)
	}
	for _ in 0 .. socket_len {
		socket_path := ws.next_socket() or { break }
		if autostart {
			ws.mu.@lock()
			idx := ws.index_by_socket_unlocked(socket_path)
			if idx >= 0 && idx < ws.worker_backend.managed_workers.len {
				w := ws.worker_backend.managed_workers[idx]
				generation := ws.slot_generation_unlocked(w.socket_path)
				ws.mu.unlock()
				if w.draining {
					if w.inflight_requests == 0 {
						draining_ready << SlotRestartCandidate{ idx: idx, generation: generation }
					}
					last_err = 'all workers draining'
					continue
				}
				return ws.unmanaged_request_lease(socket_path)
			}
			ws.mu.unlock()
		}
		mut probe_conn := connection_runtime.dial_unix(socket_path) or {
			last_err = err.msg()
			continue
		}
		probe_conn.close() or {}
		return ws.unmanaged_request_lease(socket_path)
	}
	if autostart {
		for candidate in draining_ready {
			ws.restart_slot_generation(port, candidate.idx, candidate.generation, 'drain_complete')
		}
	}
	return error(last_err)
}

pub fn (mut ws WorkerState) select_socket(port LifecyclePort, kind string) !string {
	socket_path := ws.select_socket_core(port, kind) or {
		port.emit_fn('worker.select.failed', {
			'kind':             kind
			'error':            err.msg()
			'diagnostics_json': json.encode(ws.selection_diagnostics(),
				escape_unicode: true
				time_as_unix:   true
			)
		})
		return err
	}
	return socket_path
}

fn (mut ws WorkerState) unmanaged_request_lease(path string) !&RequestLease {
	ws.mu.@lock()
	defer { ws.mu.unlock() }
	admission := ws.backend_admission_error_unlocked()
	if admission != '' { return error(admission) }
	return &RequestLease{ socket_path: path, state: &ws, generation: ws.slot_generation_unlocked(path) }
}
