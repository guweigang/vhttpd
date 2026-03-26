module main

import time

fn (mut app App) try_enter_worker_queue() bool {
	if app.worker_backend.queue_capacity <= 0 || app.worker_backend.queue_timeout_ms <= 0 {
		return false
	}
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	if app.worker_backend.queue_waiting_requests >= app.worker_backend.queue_capacity {
		return false
	}
	app.worker_backend.queue_waiting_requests++
	return true
}

fn (mut app App) leave_worker_queue() {
	app.pool_mu.@lock()
	defer {
		app.pool_mu.unlock()
	}
	if app.worker_backend.queue_waiting_requests > 0 {
		app.worker_backend.queue_waiting_requests--
	}
}

fn (mut app App) note_worker_queue_wait() {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.stat_worker_queue_waits_total++
}

fn (mut app App) note_worker_queue_rejected() {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.stat_worker_queue_rejected_total++
}

fn (mut app App) note_worker_queue_timeout() {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.stat_worker_queue_timeouts_total++
}

fn (mut app App) worker_backend_select_socket_queued() !string {
	socket_path := app.worker_backend_select_socket() or {
		if err.msg() != 'all workers busy' {
			return error(err.msg())
		}
		if !app.try_enter_worker_queue() {
			app.note_worker_queue_rejected()
			return error('worker queue full')
		}
		app.note_worker_queue_wait()
		defer {
			app.leave_worker_queue()
		}
		timeout_ms := if app.worker_backend.queue_timeout_ms > 0 { app.worker_backend.queue_timeout_ms } else { 0 }
		poll_ms := if app.worker_backend.queue_poll_ms > 0 { app.worker_backend.queue_poll_ms } else { 10 }
		deadline := time.now().add(time.millisecond * timeout_ms)
		for time.now() < deadline {
			time.sleep(time.millisecond * poll_ms)
			socket := app.worker_backend_select_socket() or {
				continue
			}
			return socket
		}
		app.note_worker_queue_timeout()
		return error('worker queue timeout')
	}
	return socket_path
}
