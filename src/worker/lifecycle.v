module worker

import time
import upstream.transport

pub fn (mut ws WorkerState) ensure_slot(port LifecyclePort, idx int) {
	ws.mu.@lock()
	if ws.backend_admission_error_unlocked() != '' || !ws.worker_backend.autostart || idx < 0 || idx >= ws.worker_backend.managed_workers.len {
		ws.mu.unlock()
		return
	}
	now := time.now().unix_milli()
	mut w := ws.worker_backend.managed_workers[idx]
	if w.process_alive() {
		ws.mu.unlock()
		return
	}
	if w.next_retry_ts > now {
		ws.mu.unlock()
		return
	}
	ws.retire_slot_generation_unlocked(w.socket_path)
	w.inflight_requests = 0
	w.served_requests = 0
	w.retire_process()
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		ws.worker_backend.restart_backoff_ms, ws.worker_backend.restart_backoff_max_ms)
	cmd_str := if w.worker_cmd.starts_with('exec ') { w.worker_cmd } else { 'exec ' + w.worker_cmd }
	redirect_cmd := if w.worker_cmd.contains('vphp-worker') {
		'${cmd_str} >> /tmp/vhttpd_php_worker_${w.id}.log 2>&1'
	} else {
		cmd_str
	}
	mut proc := transport.ManagedWorker.launch_process(redirect_cmd, w.worker_env, ws.worker_backend.workdir) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		ws.mu.unlock()
		port.emit_fn('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        err.msg()
		})
		return
	}
	w.proc = proc
	transport.ManagedWorker.wait_for_process_socket(mut proc, w.socket_path, 1500) or {
		w.retire_process()
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		ws.mu.unlock()
		port.emit_fn('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        err.msg()
		})
		return
	}
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	ws.publish_slot_generation_unlocked(w.socket_path)
	ws.worker_backend.managed_workers[idx] = w
	ws.mu.unlock()
	port.emit_fn('worker.started', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
	})
}

pub fn (mut ws WorkerState) restart_slot(port LifecyclePort, idx int, reason string) {
	ws.restart_slot_generation(port, idx, none, reason)
}

fn (mut ws WorkerState) restart_slot_generation(port LifecyclePort, idx int, expected ?&SlotGeneration, reason string) {
	ws.mu.@lock()
	if ws.backend_admission_error_unlocked() != '' || !ws.worker_backend.autostart || idx < 0 || idx >= ws.worker_backend.managed_workers.len {
		ws.mu.unlock()
		return
	}
	mut w := ws.worker_backend.managed_workers[idx]
	if token := expected {
		current := ws.slot_generation_unlocked(w.socket_path)
		if voidptr(token) != voidptr(current) {
			ws.mu.unlock()
			return
		}
	}
	ws.retire_slot_generation_unlocked(w.socket_path)
	w.inflight_requests = 0
	w.served_requests = 0
	if !w.retire_process() {
		ws.worker_backend.managed_workers[idx] = w
		ws.mu.unlock()
		ws.ensure_slot(port, idx)
		return
	}
	now := time.now().unix_milli()
	delay_ms := transport.ManagedWorkerPool.restart_backoff_ms(w.restart_count,
		ws.worker_backend.restart_backoff_ms, ws.worker_backend.restart_backoff_max_ms)
	cmd_str := if w.worker_cmd.starts_with('exec ') { w.worker_cmd } else { 'exec ' + w.worker_cmd }
	redirect_cmd := if w.worker_cmd.contains('vphp-worker') {
		'${cmd_str} >> /tmp/vhttpd_php_worker_${w.id}.log 2>&1'
	} else {
		cmd_str
	}
	mut proc := transport.ManagedWorker.launch_process(redirect_cmd, w.worker_env, ws.worker_backend.workdir) or {
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		ws.mu.unlock()
		port.emit_fn('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        err.msg()
		})
		return
	}
	w.proc = proc
	transport.ManagedWorker.wait_for_process_socket(mut proc, w.socket_path, 1500) or {
		w.retire_process()
		w.restart_count++
		w.last_exit_ts = now
		w.next_retry_ts = now + delay_ms
		ws.worker_backend.managed_workers[idx] = w
		ws.mu.unlock()
		port.emit_fn('worker.restart_scheduled', {
			'worker_id':     '${w.id}'
			'socket':        w.socket_path
			'restart_count': '${w.restart_count}'
			'next_retry_ts': '${w.next_retry_ts}'
			'reason':        '${reason}; ${err.msg()}'
		})
		return
	}
	w.restart_count++
	w.last_exit_ts = now
	w.next_retry_ts = 0
	w.served_requests = 0
	w.inflight_requests = 0
	w.draining = false
	ws.publish_slot_generation_unlocked(w.socket_path)
	ws.worker_backend.managed_workers[idx] = w
	ws.mu.unlock()
	port.emit_fn('worker.restarted', {
		'worker_id':     '${w.id}'
		'socket':        w.socket_path
		'restart_count': '${w.restart_count}'
		'reason':        reason
	})
}

pub fn (mut ws WorkerState) ensure_alive(port LifecyclePort) {
	ws.mu.@lock()
	count := if ws.backend_admission_error_unlocked() == '' && ws.worker_backend.autostart {
		ws.worker_backend.managed_workers.len
	} else {
		0
	}
	ws.mu.unlock()
	for i in 0 .. count { ws.ensure_slot(port, i) }
}
