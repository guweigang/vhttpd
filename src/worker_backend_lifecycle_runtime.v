module main

import os
import time
import upstream.transport
import worker

fn (mut runtime EngineRuntime) ensure_worker_slot_for_state(port EngineLifecyclePort, mut ws worker.WorkerState, idx int) {
	ws.mu.@lock()
	if !ws.worker_backend.autostart || idx < 0 || idx >= ws.worker_backend.managed_workers.len {
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
		ws.worker_backend.restart_backoff_ms, ws.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	cmd_str := if w.worker_cmd.starts_with('exec ') { w.worker_cmd } else { 'exec ' + w.worker_cmd }
	redirect_cmd := if w.worker_cmd.contains('vphp-worker') {
		'${cmd_str} >> /tmp/vhttpd_php_worker_${w.id}.log 2>&1'
	} else {
		cmd_str
	}
	proc.set_args(['-lc', redirect_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(ws.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.ManagedWorker.wait_for_socket(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		port.emit_fn('worker.restart_scheduled', {
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
	port.emit_fn('worker.started', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
	})
	ws.mu.unlock()
}

fn (mut runtime EngineRuntime) restart_worker_slot_now_for_state(port EngineLifecyclePort, mut ws worker.WorkerState, idx int, reason string) {
	ws.mu.@lock()
	if idx < 0 || idx >= ws.worker_backend.managed_workers.len {
		ws.mu.unlock()
		return
	}
	mut w := ws.worker_backend.managed_workers[idx]
	if isnil(w.proc) {
		ws.mu.unlock()
		runtime.ensure_worker_slot_for_state(port, mut ws, idx)
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_pgkill()
		w.proc.wait()
	}
	w.proc.close()
	now := time.now().unix_milli()
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		ws.worker_backend.restart_backoff_ms, ws.worker_backend.restart_backoff_max_ms)
	mut proc := os.new_process('/bin/sh')
	cmd_str := if w.worker_cmd.starts_with('exec ') { w.worker_cmd } else { 'exec ' + w.worker_cmd }
	redirect_cmd := if w.worker_cmd.contains('vphp-worker') {
		'${cmd_str} >> /tmp/vhttpd_php_worker_${w.id}.log 2>&1'
	} else {
		cmd_str
	}
	proc.set_args(['-lc', redirect_cmd])
	proc.set_environment(w.worker_env)
	proc.set_work_folder(ws.worker_backend.workdir)
	proc.use_pgroup = true
	proc.run()
	transport.ManagedWorker.wait_for_socket(w.socket_path, 1500) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		port.emit_fn('worker.restart_scheduled', {
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
	port.emit_fn('worker.restarted', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
		'reason':        reason
	})
	ws.mu.unlock()
}

fn (mut app App) on_worker_request_started(socket_path string) {
	app.engines.request_started(socket_path)
}

fn (mut app App) on_worker_request_finished(socket_path string) {
	port := app.build_engine_lifecycle_port()
	app.engines.request_finished(port, socket_path)
}

fn (mut app App) on_worker_request_released(socket_path string) {
	app.engines.request_released(socket_path)
}

fn (mut runtime EngineRuntime) ensure_workers_alive_for_state(port EngineLifecyclePort, mut ws worker.WorkerState) {
	if !ws.worker_backend.autostart || ws.worker_backend.managed_workers.len == 0 {
		return
	}
	for i in 0 .. ws.worker_backend.managed_workers.len {
		runtime.ensure_worker_slot_for_state(port, mut ws, i)
	}
}
