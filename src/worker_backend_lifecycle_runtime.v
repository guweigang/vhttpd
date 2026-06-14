module main

import os
import time
import upstream.transport

fn (app &App) worker_index_by_socket_unlocked(socket_path string) int {
	for i, w in app.executors.worker.worker_backend.managed_workers {
		if w.socket_path == socket_path {
			return i
		}
	}
	return -1
}

fn (mut app App) ensure_worker_slot(idx int) {
	app.executors.worker.mu.@lock()
	if !app.executors.worker.worker_backend.autostart || idx < 0
		|| idx >= app.executors.worker.worker_backend.managed_workers.len {
		app.executors.worker.mu.unlock()
		return
	}
	now := time.now().unix_milli()
	mut w := app.executors.worker.worker_backend.managed_workers[idx]
	if !isnil(w.proc) && w.proc.is_alive() {
		app.executors.worker.mu.unlock()
		return
	}
	if w.next_retry_ts > now {
		app.executors.worker.mu.unlock()
		return
	}
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		app.executors.worker.worker_backend.restart_backoff_ms,
		app.executors.worker.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(app.executors.worker.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.ManagedWorker.wait_for_socket(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		app.executors.worker.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        err.msg()
		})
		app.executors.worker.mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	app.executors.worker.worker_backend.managed_workers[idx] = w
	app.emit('worker.started', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
	})
	app.executors.worker.mu.unlock()
}

fn (mut app App) worker_index_by_socket(socket_path string) int {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	return app.worker_index_by_socket_unlocked(socket_path)
}

fn (mut app App) restart_worker_slot_now(idx int, reason string) {
	app.executors.worker.mu.@lock()
	if idx < 0 || idx >= app.executors.worker.worker_backend.managed_workers.len {
		app.executors.worker.mu.unlock()
		return
	}
	mut w := app.executors.worker.worker_backend.managed_workers[idx]
	if isnil(w.proc) {
		app.executors.worker.mu.unlock()
		app.ensure_worker_slot(idx)
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_pgkill()
		w.proc.wait()
	}
	w.proc.close()
	now := time.now().unix_milli()
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		app.executors.worker.worker_backend.restart_backoff_ms,
		app.executors.worker.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(app.executors.worker.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.ManagedWorker.wait_for_socket(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		app.executors.worker.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        '${reason}; ${err.msg()}'
		})
		app.executors.worker.mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	app.executors.worker.worker_backend.managed_workers[idx] = w
	app.emit('worker.restarted', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
		'reason':        reason
	})
	app.executors.worker.mu.unlock()
}

fn (mut app App) on_worker_request_started(socket_path string) {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	if !app.executors.worker.worker_backend.autostart || app.executors.worker.worker_backend.managed_workers.len == 0 {
		return
	}
	idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx < 0 {
		return
	}
	mut w := app.executors.worker.worker_backend.managed_workers[idx]
	w.inflight_requests++
	app.executors.worker.worker_backend.managed_workers[idx] = w
}

fn (mut app App) on_worker_request_finished(socket_path string) {
	mut should_restart := false
	app.executors.worker.mu.@lock()
	if !app.executors.worker.worker_backend.autostart || app.executors.worker.worker_backend.managed_workers.len == 0 {
		app.executors.worker.mu.unlock()
		return
	}
	idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx < 0 {
		app.executors.worker.mu.unlock()
		return
	}
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
	app.executors.worker.mu.unlock()
	if should_restart {
		app.restart_worker_slot_now(idx, 'max_requests_reached')
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
