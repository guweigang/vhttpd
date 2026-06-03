module main

import transport

import config

import json
import log
import net.unix
import os
import time
fn (app &App) worker_index_by_socket_unlocked(socket_path string) int {
	for i, w in app.worker.worker_backend.managed_workers {
		if w.socket_path == socket_path {
			return i
		}
	}
	return -1
}

fn (mut app App) ensure_worker_slot(idx int) {
	app.worker.mu.@lock()
	if !app.worker.worker_backend.autostart || idx < 0 || idx >= app.worker.worker_backend.managed_workers.len {
		app.worker.mu.unlock()
		return
	}
	now := time.now().unix_milli()
	mut w := app.worker.worker_backend.managed_workers[idx]
	if !isnil(w.proc) && w.proc.is_alive() {
		app.worker.mu.unlock()
		return
	}
	if w.next_retry_ts > now {
		app.worker.mu.unlock()
		return
	}
	delay_ms := transport.restart_backoff_ms(w.restart_count, app.worker.worker_backend.restart_backoff_ms,
		app.worker.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(app.worker.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.wait_for_worker(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		app.worker.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        err.msg()
		})
		app.worker.mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	app.worker.worker_backend.managed_workers[idx] = w
	app.emit('worker.started', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
	})
	app.worker.mu.unlock()
}

fn (mut app App) worker_index_by_socket(socket_path string) int {
	app.worker.mu.@lock()
	defer {
		app.worker.mu.unlock()
	}
	return app.worker_index_by_socket_unlocked(socket_path)
}

fn (mut app App) restart_worker_slot_now(idx int, reason string) {
	app.worker.mu.@lock()
	if idx < 0 || idx >= app.worker.worker_backend.managed_workers.len {
		app.worker.mu.unlock()
		return
	}
	mut w := app.worker.worker_backend.managed_workers[idx]
	if isnil(w.proc) {
		app.worker.mu.unlock()
		app.ensure_worker_slot(idx)
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_pgkill()
		w.proc.wait()
	}
	w.proc.close()
	now := time.now().unix_milli()
	delay_ms := transport.restart_backoff_ms(w.restart_count, app.worker.worker_backend.restart_backoff_ms,
		app.worker.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(app.worker.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.wait_for_worker(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		app.worker.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        '${reason}; ${err.msg()}'
		})
		app.worker.mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	app.worker.worker_backend.managed_workers[idx] = w
	app.emit('worker.restarted', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
		'reason':        reason
	})
	app.worker.mu.unlock()
}

fn (mut app App) on_worker_request_started(socket_path string) {
	app.worker.mu.@lock()
	defer {
		app.worker.mu.unlock()
	}
	if !app.worker.worker_backend.autostart || app.worker.worker_backend.managed_workers.len == 0 {
		return
	}
	idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx < 0 {
		return
	}
	mut w := app.worker.worker_backend.managed_workers[idx]
	w.inflight_requests++
	app.worker.worker_backend.managed_workers[idx] = w
}

fn (mut app App) on_worker_request_finished(socket_path string) {
	mut should_restart := false
	app.worker.mu.@lock()
	if !app.worker.worker_backend.autostart || app.worker.worker_backend.managed_workers.len == 0 {
		app.worker.mu.unlock()
		return
	}
	idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx < 0 {
		app.worker.mu.unlock()
		return
	}
	mut w := app.worker.worker_backend.managed_workers[idx]
	if w.inflight_requests > 0 {
		w.inflight_requests--
	}
	w.served_requests++
	if app.worker.worker_backend.max_requests > 0 && !w.draining
		&& w.served_requests >= app.worker.worker_backend.max_requests {
		w.draining = true
		app.emit('worker.max_requests_reached', {
			'worker_id':       '${w.id}'
			'socket':          w.socket_path
			'served_requests': '${w.served_requests}'
			'max_requests':    '${app.worker.worker_backend.max_requests}'
		})
	}
	app.worker.worker_backend.managed_workers[idx] = w
	should_restart = w.draining && w.inflight_requests == 0
	app.worker.mu.unlock()
	if should_restart {
		app.restart_worker_slot_now(idx, 'max_requests_reached')
	}
}

fn (mut app App) ensure_workers_alive() {
	if !app.worker.worker_backend.autostart || app.worker.worker_backend.managed_workers.len == 0 {
		return
	}
	for i in 0 .. app.worker.worker_backend.managed_workers.len {
		app.ensure_worker_slot(i)
	}
}

fn (mut app App) next_worker_socket() ?string {
	app.worker.mu.@lock()
	defer {
		app.worker.mu.unlock()
	}
	if app.worker.worker_backend.sockets.len == 0 {
		return none
	}
	idx := app.worker.worker_backend.rr_index % app.worker.worker_backend.sockets.len
	socket_path := app.worker.worker_backend.sockets[idx]
	app.worker.worker_backend.rr_index = (idx + 1) % app.worker.worker_backend.sockets.len
	return socket_path
}

fn (mut app App) next_idle_worker_socket() ?string {
	app.worker.mu.@lock()
	defer {
		app.worker.mu.unlock()
	}
	if app.worker.worker_backend.sockets.len == 0 {
		return none
	}
	for offset in 0 .. app.worker.worker_backend.sockets.len {
		idx := (app.worker.worker_backend.rr_index + offset) % app.worker.worker_backend.sockets.len
		socket_path := app.worker.worker_backend.sockets[idx]
		worker_idx := app.worker_index_by_socket_unlocked(socket_path)
		if worker_idx < 0 || worker_idx >= app.worker.worker_backend.managed_workers.len {
			continue
		}
		mut w := app.worker.worker_backend.managed_workers[worker_idx]
		if w.draining || w.inflight_requests > 0 {
			continue
		}
		if !isnil(w.proc) && !w.proc.is_alive() {
			continue
		}
		app.worker.worker_backend.rr_index = (idx + 1) % app.worker.worker_backend.sockets.len
		return socket_path
	}
	return none
}

fn (mut app App) worker_selection_diagnostics() []transport.WorkerSelectionDiagnostic {
	mut diagnostics := []transport.WorkerSelectionDiagnostic{}
	app.worker.mu.@lock()
	if app.worker.worker_backend.sockets.len == 0 {
		app.worker.mu.unlock()
		return diagnostics
	}
	sockets := app.worker.worker_backend.sockets.clone()
	workers := app.worker.worker_backend.managed_workers.clone()
	app.worker.mu.unlock()
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

fn (mut app App) worker_backend_select_socket() !string {
	app.ensure_workers_alive()
	app.worker.mu.@lock()
	socket_len := app.worker.worker_backend.sockets.len
	autostart := app.worker.worker_backend.autostart
	managed_worker_len := app.worker.worker_backend.managed_workers.len
	app.worker.mu.unlock()
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
		app.worker.mu.@lock()
		for idx, w in app.worker.worker_backend.managed_workers {
			if w.draining && w.inflight_requests == 0 {
				draining_ready << idx
			}
		}
		app.worker.mu.unlock()
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
			app.worker.mu.@lock()
			idx := app.worker_index_by_socket_unlocked(socket_path)
			if idx >= 0 && idx < app.worker.worker_backend.managed_workers.len {
				w := app.worker.worker_backend.managed_workers[idx]
				app.worker.mu.unlock()
				if w.draining {
					if w.inflight_requests == 0 {
						draining_ready << idx
					}
					last_err = 'all workers draining'
					continue
				}
				return socket_path
			}
			app.worker.mu.unlock()
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

fn worker_admin_status_from(mut w transport.ManagedWorker) WorkerAdminStatus {
	pid := if isnil(w.proc) { 0 } else { w.proc.pid }
	return WorkerAdminStatus{
		id:                w.id
		socket:            w.socket_path
		alive:             if isnil(w.proc) { false } else { w.proc.is_alive() }
		pid:               pid
		rss_kb:            worker_rss_kb(pid)
		draining:          w.draining
		inflight_requests: w.inflight_requests
		served_requests:   w.served_requests
		restart_count:     w.restart_count
		next_retry_ts:     w.next_retry_ts
	}
}

fn worker_rss_kb(pid int) i64 {
	if pid <= 0 {
		return 0
	}
	// `ps -o rss=` is portable across macOS/Linux and returns RSS in KB.
	cmd := 'ps -o rss= -p ${pid}'
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return 0
	}
	rss_raw := res.output.trim_space()
	if rss_raw == '' {
		return 0
	}
	return rss_raw.i64()
}

fn (mut app App) restart_worker_by_id(worker_id int) !WorkerAdminStatus {
	app.worker.mu.@lock()
	if !app.worker.worker_backend.autostart || app.worker.worker_backend.managed_workers.len == 0 {
		app.worker.mu.unlock()
		return error('worker pool is not enabled')
	}
	mut idx := -1
	for i, w in app.worker.worker_backend.managed_workers {
		if w.id == worker_id {
			idx = i
			break
		}
	}
	app.worker.mu.unlock()
	if idx < 0 {
		return error('worker id not found: ${worker_id}')
	}
	app.restart_worker_slot_now(idx, 'admin_restart')
	app.worker.mu.@lock()
	mut w := app.worker.worker_backend.managed_workers[idx]
	app.worker.mu.unlock()
	return worker_admin_status_from(mut w)
}

fn (mut app App) restart_all_workers() int {
	app.worker.mu.@lock()
	if !app.worker.worker_backend.autostart || app.worker.worker_backend.managed_workers.len == 0 {
		app.worker.mu.unlock()
		return 0
	}
	worker_count := app.worker.worker_backend.managed_workers.len
	app.worker.mu.unlock()
	mut restarted := 0
	for i in 0 .. worker_count {
		app.restart_worker_slot_now(i, 'admin_restart_all')
		restarted++
	}
	return restarted
}

fn (mut app App) worker_admin_snapshot() WorkerPoolAdminStatus {
	app.worker.mu.@lock()
	defer {
		app.worker.mu.unlock()
	}
	mut workers := []WorkerAdminStatus{cap: app.worker.worker_backend.managed_workers.len}
	for worker in app.worker.worker_backend.managed_workers {
		mut w := worker
		workers << worker_admin_status_from(mut w)
	}
	return WorkerPoolAdminStatus{
		worker_autostart:    app.worker.worker_backend.autostart
		worker_pool_size:    app.worker.worker_backend.sockets.len
		worker_rr_index:     app.worker.worker_backend.rr_index
		worker_max_requests: app.worker.worker_backend.max_requests
		worker_sockets:      app.worker.worker_backend.sockets.clone()
		workers:             workers
	}
}
