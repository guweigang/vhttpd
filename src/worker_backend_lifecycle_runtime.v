module main

import os
import time
import upstream.transport
import worker

fn (app &App) worker_index_by_socket_unlocked(socket_path string) int {
	for i, w in app.executors.worker.worker_backend.managed_workers {
		if w.socket_path == socket_path {
			return i
		}
	}
	return -1
}

fn (mut app App) ensure_worker_slot_for_state(mut ws worker.WorkerState, idx int) {
	ws.mu.@lock()
	if !ws.worker_backend.autostart || idx < 0
		|| idx >= ws.worker_backend.managed_workers.len {
		ws.mu.unlock()
		return
	}
	now := time.now().unix_milli()
	mut w := ws.worker_backend.managed_workers[idx]
	if !isnil(w.proc) && w.proc.is_alive() {
		ws.mu.unlock()
		return
	}
	if w.next_retry_ts > now {
		ws.mu.unlock()
		return
	}
	if !isnil(w.proc) {
		w.proc.close()
	}
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		ws.worker_backend.restart_backoff_ms,
		ws.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(ws.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.ManagedWorker.wait_for_socket(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        err.msg()
		})
		ws.mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	ws.worker_backend.managed_workers[idx] = w
	app.emit('worker.started', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
	})
	ws.mu.unlock()
}

fn (mut app App) ensure_worker_slot(idx int) {
	app.ensure_worker_slot_for_state(mut app.executors.worker, idx)
}

fn (mut app App) worker_index_by_socket(socket_path string) int {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	return app.worker_index_by_socket_unlocked(socket_path)
}

fn (mut app App) restart_worker_slot_now_for_state(mut ws worker.WorkerState, idx int, reason string) {
	ws.mu.@lock()
	if idx < 0 || idx >= ws.worker_backend.managed_workers.len {
		ws.mu.unlock()
		return
	}
	mut w := ws.worker_backend.managed_workers[idx]
	if isnil(w.proc) {
		ws.mu.unlock()
		app.ensure_worker_slot_for_state(mut ws, idx)
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_pgkill()
		w.proc.wait()
	}
	w.proc.close()
	now := time.now().unix_milli()
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		ws.worker_backend.restart_backoff_ms,
		ws.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(ws.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.ManagedWorker.wait_for_socket(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        '${reason}; ${err.msg()}'
		})
		ws.mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	ws.worker_backend.managed_workers[idx] = w
	app.emit('worker.restarted', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
		'reason':        reason
	})
	ws.mu.unlock()
}

fn (mut app App) restart_worker_slot_now(idx int, reason string) {
	app.restart_worker_slot_now_for_state(mut app.executors.worker, idx, reason)
}

fn (mut app App) on_worker_request_started(socket_path string) {
	// 1. 尝试匹配并更新主进程池
	app.executors.worker.mu.@lock()
	mut idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx >= 0 && idx < app.executors.worker.worker_backend.managed_workers.len {
		mut w := app.executors.worker.worker_backend.managed_workers[idx]
		w.inflight_requests++
		app.executors.worker.worker_backend.managed_workers[idx] = w
		app.executors.worker.mu.unlock()
		return
	}
	app.executors.worker.mu.unlock()

	// 2. 尝试匹配并更新附加进程池
	for _, mut ws in app.additional_workers {
		ws.mu.@lock()
		for i in 0 .. ws.worker_backend.sockets.len {
			if ws.worker_backend.sockets[i] == socket_path {
				if i < ws.worker_backend.managed_workers.len {
					mut w := ws.worker_backend.managed_workers[i]
					w.inflight_requests++
					ws.worker_backend.managed_workers[i] = w
				}
				ws.mu.unlock()
				return
			}
		}
		ws.mu.unlock()
	}
}

fn (mut app App) on_worker_request_finished(socket_path string) {
	// 1. 尝试匹配并更新主进程池
	mut should_restart := false
	mut restart_idx := -1
	app.executors.worker.mu.@lock()
	mut idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx >= 0 && idx < app.executors.worker.worker_backend.managed_workers.len {
		mut w := app.executors.worker.worker_backend.managed_workers[idx]
		if w.inflight_requests > 0 {
			w.inflight_requests--
		}
		w.served_requests++
		if app.executors.worker.worker_backend.max_requests > 0 && !w.draining
			&& w.served_requests >= app.executors.worker.worker_backend.max_requests {
			w.draining = true
			app.emit('worker.max_requests_reached', {
				'worker_id':       '${w.id}'
				'socket':          w.socket_path
				'served_requests': '${w.served_requests}'
				'max_requests':    '${app.executors.worker.worker_backend.max_requests}'
			})
		}
		app.executors.worker.worker_backend.managed_workers[idx] = w
		should_restart = w.draining && w.inflight_requests == 0
		restart_idx = idx
		app.executors.worker.mu.unlock()
		if should_restart {
			app.restart_worker_slot_now(restart_idx, 'max_requests_reached')
		}
		return
	}
	app.executors.worker.mu.unlock()

	// 2. 尝试匹配并更新附加进程池
	for _, mut ws in app.additional_workers {
		mut add_should_restart := false
		mut add_restart_idx := -1
		ws.mu.@lock()
		for i in 0 .. ws.worker_backend.sockets.len {
			if ws.worker_backend.sockets[i] == socket_path {
				if i < ws.worker_backend.managed_workers.len {
					mut w := ws.worker_backend.managed_workers[i]
					if w.inflight_requests > 0 {
						w.inflight_requests--
					}
					w.served_requests++
					if ws.worker_backend.max_requests > 0 && !w.draining
						&& w.served_requests >= ws.worker_backend.max_requests {
						w.draining = true
						app.emit('worker.max_requests_reached', {
							'worker_id':       '${w.id}'
							'socket':          w.socket_path
							'served_requests': '${w.served_requests}'
							'max_requests':    '${ws.worker_backend.max_requests}'
						})
					}
					ws.worker_backend.managed_workers[i] = w
					add_should_restart = w.draining && w.inflight_requests == 0
					add_restart_idx = i
				}
				ws.mu.unlock()
				if add_should_restart {
					app.restart_worker_slot_now_for_state(mut *ws, add_restart_idx, 'max_requests_reached')
				}
				return
			}
		}
		ws.mu.unlock()
	}
}

fn (mut app App) ensure_workers_alive() {
	if !app.executors.worker.worker_backend.autostart || app.executors.worker.worker_backend.managed_workers.len == 0 {
		return
	}
	for i in 0 .. app.executors.worker.worker_backend.managed_workers.len {
		app.ensure_worker_slot(i)
	}
}
