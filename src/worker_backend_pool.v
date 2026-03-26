module main

import json
import log
import net.unix
import os
import time

struct ManagedWorker {
	id          int
	socket_path string
	worker_cmd  string
	worker_env  map[string]string
mut:
	proc          &os.Process = unsafe { nil }
	restart_count int
	last_exit_ts  i64
	next_retry_ts i64
	served_requests i64
	inflight_requests i64
	draining bool
}

struct WorkerSelectionDiagnostic {
	socket_path       string
	proc_alive        bool
	draining          bool
	inflight_requests i64
	probe_error       string
}

fn get_arg(args []string, key string, default_val string) string {
	for i, a in args {
		if a == key && i + 1 < args.len {
			return args[i + 1]
		}
		prefix := '${key}='
		if a.starts_with(prefix) {
			return a.all_after(prefix)
		}
	}
	return default_val
}

fn wait_for_worker(socket_path string, timeout_ms int) ! {
	deadline := time.now().add(time.millisecond * timeout_ms)
	for time.now() < deadline {
		mut conn := unix.connect_stream(socket_path) or {
			time.sleep(100 * time.millisecond)
			continue
		}
		conn.close() or {}
		return
	}
	return error('worker socket not ready: ${socket_path}')
}

fn cmd_with_socket(worker_cmd string, worker_socket string, pool_size int) !string {
	if worker_cmd == '' {
		return error('empty worker command')
	}
	if worker_socket == '' {
		return error('worker socket is required when autostart is enabled')
	}
	if worker_cmd.contains('{socket}') {
		return worker_cmd.replace('{socket}', worker_socket)
	}
	if pool_size > 1 && worker_cmd.contains('--socket') {
		return error('worker-cmd for pool mode should omit --socket (auto-injected) or use {socket} placeholder')
	}
	if !worker_cmd.contains('--socket') {
		return '${worker_cmd} --socket ${worker_socket}'
	}
	return worker_cmd
}

fn merge_worker_env(base map[string]string, extra map[string]string) map[string]string {
	mut merged := base.clone()
	for k, v in extra {
		merged[k] = v
	}
	return merged
}

fn start_managed_worker(id int, worker_cmd string, worker_env map[string]string, worker_socket string, workdir string, pool_size int) !ManagedWorker {
	cmd := cmd_with_socket(worker_cmd, worker_socket, pool_size)!
	mut merged_env := merge_worker_env(os.environ(), worker_env)
	merged_env['VHTTPD_PARENT_PID'] = '${os.getpid()}'
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', cmd])
	proc.set_environment(merged_env)
	proc.set_work_folder(workdir)
	proc.use_pgroup = true
	proc.run()
	wait_for_worker(worker_socket, 5000)!
	return ManagedWorker{
		id: id
		socket_path: worker_socket
		worker_cmd: cmd
		worker_env: merged_env
		proc: proc
		last_exit_ts: 0
		next_retry_ts: 0
		served_requests: 0
		inflight_requests: 0
		draining: false
	}
}

fn build_managed_worker_slot(id int, worker_cmd string, worker_env map[string]string, worker_socket string, pool_size int) !ManagedWorker {
	cmd := cmd_with_socket(worker_cmd, worker_socket, pool_size)!
	mut merged_env := merge_worker_env(os.environ(), worker_env)
	merged_env['VHTTPD_PARENT_PID'] = '${os.getpid()}'
	return ManagedWorker{
		id: id
		socket_path: worker_socket
		worker_cmd: cmd
		worker_env: merged_env
		last_exit_ts: 0
		next_retry_ts: 0
		served_requests: 0
		inflight_requests: 0
		draining: false
	}
}

fn (mut w ManagedWorker) stop() {
	if isnil(w.proc) {
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_term()
		time.sleep(200 * time.millisecond)
		if w.proc.is_alive() {
			w.proc.signal_pgkill()
			time.sleep(100 * time.millisecond)
		}
		if w.proc.is_alive() {
			w.proc.signal_kill()
		}
		w.proc.wait()
	}
	w.proc.close()
}

fn stop_worker_pool(mut workers []ManagedWorker) {
	for i in 0 .. workers.len {
		mut w := workers[i]
		w.stop()
	}
}

fn socket_prefix(worker_socket string) string {
	if worker_socket.len >= 5 && worker_socket.ends_with('.sock') {
		return worker_socket[..worker_socket.len - 5]
	}
	if worker_socket != '' {
		return worker_socket
	}
	return '/tmp/vslim_worker'
}

fn resolve_worker_sockets(args []string) []string {
	return resolve_worker_sockets_with_defaults(args, '', 1, '', '')
}

fn resolve_worker_sockets_with_defaults(args []string, default_worker_socket string, default_pool_size int, default_socket_prefix string, default_worker_sockets string) []string {
	worker_sockets_arg := arg_string_or(args, '--worker-sockets', default_worker_sockets)
	if worker_sockets_arg != '' {
		mut sockets := []string{}
		for raw in worker_sockets_arg.split(',') {
			s := raw.trim_space()
			if s != '' {
				sockets << s
			}
		}
		return sockets
	}
	worker_socket := arg_string_or(args, '--worker-socket', default_worker_socket)
	pool_size := arg_int_or(args, '--worker-pool-size', default_pool_size)
	if pool_size <= 1 {
		return if worker_socket == '' { []string{} } else { [worker_socket] }
	}
	mut prefix := arg_string_or(args, '--worker-socket-prefix', default_socket_prefix)
	if prefix == '' {
		prefix = socket_prefix(worker_socket)
	}
	mut sockets := []string{cap: pool_size}
	for i in 0 .. pool_size {
		sockets << '${prefix}_${i}.sock'
	}
	return sockets
}

fn start_worker_pool(worker_cmd string, worker_env map[string]string, worker_sockets []string, workdir string) []ManagedWorker {
	if worker_sockets.len == 0 {
		return []ManagedWorker{}
	}
	mut workers := []ManagedWorker{}
	for i, socket_path in worker_sockets {
		mut slot := build_managed_worker_slot(i, worker_cmd, worker_env, socket_path, worker_sockets.len) or {
			log.error('worker slot init failed [${i}] ${socket_path}: ${err.msg()}')
			continue
		}
		worker := start_managed_worker(i, worker_cmd, worker_env, socket_path, workdir, worker_sockets.len) or {
			now := time.now().unix_milli()
			slot.restart_count = 1
			slot.last_exit_ts = now
			slot.next_retry_ts = now + 500
			workers << slot
			log.error('worker start failed [${i}] ${socket_path}: ${err.msg()}')
			continue
		}
		workers << worker
	}
	return workers
}

fn restart_backoff_ms(restart_count int, base_ms int, max_ms int) int {
	mut delay := if base_ms > 0 { base_ms } else { 500 }
	mut step := if restart_count > 0 { restart_count - 1 } else { 0 }
	for step > 0 {
		delay *= 2
		if delay >= max_ms {
			return max_ms
		}
		step--
	}
	if delay > max_ms {
		return max_ms
	}
	return delay
}

fn (app &App) worker_index_by_socket_unlocked(socket_path string) int {
	for i, w in app.worker_backend.managed_workers {
		if w.socket_path == socket_path {
			return i
		}
	}
	return -1
}

fn (mut app App) ensure_worker_slot(idx int) {
	app.pool_mu.@lock()
	if !app.worker_backend.autostart || idx < 0 || idx >= app.worker_backend.managed_workers.len {
		app.pool_mu.unlock()
		return
	}
	now := time.now().unix_milli()
	mut w := app.worker_backend.managed_workers[idx]
	if !isnil(w.proc) && w.proc.is_alive() {
		app.pool_mu.unlock()
		return
	}
	if w.next_retry_ts > now {
		app.pool_mu.unlock()
		return
	}
	delay_ms := restart_backoff_ms(w.restart_count, app.worker_backend.restart_backoff_ms, app.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(app.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	wait_for_worker(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		app.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id': '${w.id}'
			'socket': w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason': err.msg()
		})
		app.pool_mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	app.worker_backend.managed_workers[idx] = w
	app.emit('worker.started', {
		'worker_id': '${w.id}'
		'socket': w.socket_path
		'restart_count': '${w.restart_count}'
	})
	app.pool_mu.unlock()
}

fn (mut app App) worker_index_by_socket(socket_path string) int {
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	return app.worker_index_by_socket_unlocked(socket_path)
}

fn (mut app App) restart_worker_slot_now(idx int, reason string) {
	app.pool_mu.@lock()
	if idx < 0 || idx >= app.worker_backend.managed_workers.len {
		app.pool_mu.unlock()
		return
	}
	mut w := app.worker_backend.managed_workers[idx]
	if isnil(w.proc) {
		app.pool_mu.unlock()
		app.ensure_worker_slot(idx)
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_pgkill()
		w.proc.wait()
	}
	w.proc.close()
	now := time.now().unix_milli()
	delay_ms := restart_backoff_ms(w.restart_count, app.worker_backend.restart_backoff_ms, app.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', w.worker_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(app.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	wait_for_worker(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		app.worker_backend.managed_workers[idx] = w
		app.emit('worker.restart_scheduled', {
			'worker_id': '${w.id}'
			'socket': w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason': '${reason}; ${err.msg()}'
		})
		app.pool_mu.unlock()
		return
	}
	w.proc = proc
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	app.worker_backend.managed_workers[idx] = w
	app.emit('worker.restarted', {
		'worker_id': '${w.id}'
		'socket': w.socket_path
		'restart_count': '${w.restart_count}'
		'reason': reason
	})
	app.pool_mu.unlock()
}

fn (mut app App) on_worker_request_started(socket_path string) {
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	if !app.worker_backend.autostart || app.worker_backend.managed_workers.len == 0 {
		return
	}
	idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx < 0 {
		return
	}
	mut w := app.worker_backend.managed_workers[idx]
	w.inflight_requests++
	app.worker_backend.managed_workers[idx] = w
}

fn (mut app App) on_worker_request_finished(socket_path string) {
	mut should_restart := false
	app.pool_mu.@lock()
	if !app.worker_backend.autostart || app.worker_backend.managed_workers.len == 0 {
		app.pool_mu.unlock()
		return
	}
	idx := app.worker_index_by_socket_unlocked(socket_path)
	if idx < 0 {
		app.pool_mu.unlock()
		return
	}
	mut w := app.worker_backend.managed_workers[idx]
	if w.inflight_requests > 0 {
		w.inflight_requests--
	}
	w.served_requests++
	if app.worker_backend.max_requests > 0 && !w.draining && w.served_requests >= app.worker_backend.max_requests {
		w.draining = true
		app.emit('worker.max_requests_reached', {
			'worker_id': '${w.id}'
			'socket': w.socket_path
			'served_requests': '${w.served_requests}'
			'max_requests': '${app.worker_backend.max_requests}'
		})
	}
	app.worker_backend.managed_workers[idx] = w
	should_restart = w.draining && w.inflight_requests == 0
	app.pool_mu.unlock()
	if should_restart {
		app.restart_worker_slot_now(idx, 'max_requests_reached')
	}
}

fn (mut app App) ensure_workers_alive() {
	if !app.worker_backend.autostart || app.worker_backend.managed_workers.len == 0 {
		return
	}
	for i in 0 .. app.worker_backend.managed_workers.len {
		app.ensure_worker_slot(i)
	}
}

fn (mut app App) next_worker_socket() ?string {
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	if app.worker_backend.sockets.len == 0 {
		return none
	}
	idx := app.worker_backend.rr_index % app.worker_backend.sockets.len
	socket_path := app.worker_backend.sockets[idx]
	app.worker_backend.rr_index = (idx + 1) % app.worker_backend.sockets.len
	return socket_path
}

fn (mut app App) next_idle_worker_socket() ?string {
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	if app.worker_backend.sockets.len == 0 {
		return none
	}
	for offset in 0 .. app.worker_backend.sockets.len {
		idx := (app.worker_backend.rr_index + offset) % app.worker_backend.sockets.len
		socket_path := app.worker_backend.sockets[idx]
		worker_idx := app.worker_index_by_socket_unlocked(socket_path)
		if worker_idx < 0 || worker_idx >= app.worker_backend.managed_workers.len {
			continue
		}
		mut w := app.worker_backend.managed_workers[worker_idx]
		if w.draining || w.inflight_requests > 0 {
			continue
		}
		if !isnil(w.proc) && !w.proc.is_alive() {
			continue
		}
		app.worker_backend.rr_index = (idx + 1) % app.worker_backend.sockets.len
		return socket_path
	}
	return none
}

fn (mut app App) worker_selection_diagnostics() []WorkerSelectionDiagnostic {
	mut diagnostics := []WorkerSelectionDiagnostic{}
	app.pool_mu.@lock()
	if app.worker_backend.sockets.len == 0 {
		app.pool_mu.unlock()
		return diagnostics
	}
	sockets := app.worker_backend.sockets.clone()
	workers := app.worker_backend.managed_workers.clone()
	app.pool_mu.unlock()
	for socket_path in sockets {
		mut worker_idx := -1
		for i, w in workers {
			if w.socket_path == socket_path {
				worker_idx = i
				break
			}
		}
		if worker_idx < 0 || worker_idx >= workers.len {
			diagnostics << WorkerSelectionDiagnostic{
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
				diagnostics << WorkerSelectionDiagnostic{
					socket_path: socket_path
					proc_alive: !isnil(w.proc) && w.proc.is_alive()
					draining: w.draining
					inflight_requests: w.inflight_requests
					probe_error: probe_error
				}
				continue
			}
			probe_conn.close() or {}
		}
		diagnostics << WorkerSelectionDiagnostic{
			socket_path: socket_path
			proc_alive: !isnil(w.proc) && w.proc.is_alive()
			draining: w.draining
			inflight_requests: w.inflight_requests
			probe_error: probe_error
		}
	}
	return diagnostics
}

fn (mut app App) worker_backend_select_socket() !string {
	app.ensure_workers_alive()
	app.pool_mu.@lock()
	socket_len := app.worker_backend.sockets.len
	autostart := app.worker_backend.autostart
	managed_worker_len := app.worker_backend.managed_workers.len
	app.pool_mu.unlock()
	if socket_len == 0 {
		return error('worker not configured')
	}
	mut last_err := 'worker unavailable'
	mut draining_ready := []int{}
	if autostart && managed_worker_len > 0 {
		for _ in 0 .. socket_len {
			socket_path := app.next_idle_worker_socket() or {
				break
			}
			mut probe_conn := unix.connect_stream(socket_path) or {
				last_err = err.msg()
				continue
			}
			probe_conn.close() or {}
			return socket_path
		}
		app.pool_mu.@lock()
		for idx, w in app.worker_backend.managed_workers {
			if w.draining && w.inflight_requests == 0 {
				draining_ready << idx
			}
		}
		app.pool_mu.unlock()
		for idx in draining_ready {
			app.restart_worker_slot_now(idx, 'drain_complete')
		}
		if last_err == 'worker unavailable' {
			last_err = 'all workers busy'
		}
		app.emit('worker.select.failed', {
			'error': last_err
			'diagnostics_json': json.encode(app.worker_selection_diagnostics())
		})
		return error(last_err)
	}
	for _ in 0 .. socket_len {
		socket_path := app.next_worker_socket() or { break }
		if autostart {
			app.pool_mu.@lock()
			idx := app.worker_index_by_socket_unlocked(socket_path)
			if idx >= 0 && idx < app.worker_backend.managed_workers.len {
				w := app.worker_backend.managed_workers[idx]
				app.pool_mu.unlock()
				if w.draining {
					if w.inflight_requests == 0 {
						draining_ready << idx
					}
					last_err = 'all workers draining'
					continue
				}
				return socket_path
			}
			app.pool_mu.unlock()
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
		'error': last_err
		'diagnostics_json': json.encode(app.worker_selection_diagnostics())
	})
	return error(last_err)
}

fn worker_admin_status_from(mut w ManagedWorker) WorkerAdminStatus {
	pid := if isnil(w.proc) { 0 } else { w.proc.pid }
	return WorkerAdminStatus{
		id: w.id
		socket: w.socket_path
		alive: if isnil(w.proc) { false } else { w.proc.is_alive() }
		pid: pid
		rss_kb: worker_rss_kb(pid)
		draining: w.draining
		inflight_requests: w.inflight_requests
		served_requests: w.served_requests
		restart_count: w.restart_count
		next_retry_ts: w.next_retry_ts
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
	app.pool_mu.@lock()
	if !app.worker_backend.autostart || app.worker_backend.managed_workers.len == 0 {
		app.pool_mu.unlock()
		return error('worker pool is not enabled')
	}
	mut idx := -1
	for i, w in app.worker_backend.managed_workers {
		if w.id == worker_id {
			idx = i
			break
		}
	}
	app.pool_mu.unlock()
	if idx < 0 {
		return error('worker id not found: ${worker_id}')
	}
	app.restart_worker_slot_now(idx, 'admin_restart')
	app.pool_mu.@lock()
	mut w := app.worker_backend.managed_workers[idx]
	app.pool_mu.unlock()
	return worker_admin_status_from(mut w)
}

fn (mut app App) restart_all_workers() int {
	app.pool_mu.@lock()
	if !app.worker_backend.autostart || app.worker_backend.managed_workers.len == 0 {
		app.pool_mu.unlock()
		return 0
	}
	worker_count := app.worker_backend.managed_workers.len
	app.pool_mu.unlock()
	mut restarted := 0
	for i in 0 .. worker_count {
		app.restart_worker_slot_now(i, 'admin_restart_all')
		restarted++
	}
	return restarted
}

fn (mut app App) worker_admin_snapshot() WorkerPoolAdminStatus {
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	mut workers := []WorkerAdminStatus{cap: app.worker_backend.managed_workers.len}
	for worker in app.worker_backend.managed_workers {
		mut w := worker
		workers << worker_admin_status_from(mut w)
	}
	return WorkerPoolAdminStatus{
		worker_autostart: app.worker_backend.autostart
		worker_pool_size: app.worker_backend.sockets.len
		worker_rr_index: app.worker_backend.rr_index
		worker_max_requests: app.worker_backend.max_requests
		worker_sockets: app.worker_backend.sockets.clone()
		workers: workers
	}
}
