module main

import time

struct WorkerBackendQueue {}

struct WorkerBackendQueueMetrics {}

fn WorkerBackendQueue.try_enter(mut app App) bool {
	if app.executors.worker.worker_backend.queue_capacity <= 0
		|| app.executors.worker.worker_backend.queue_timeout_ms <= 0 {
		return false
	}
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	if app.executors.worker.worker_backend.queue_waiting_requests >= app.executors.worker.worker_backend.queue_capacity {
		return false
	}
	app.executors.worker.worker_backend.queue_waiting_requests++
	return true
}

fn WorkerBackendQueue.leave(mut app App) {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	if app.executors.worker.worker_backend.queue_waiting_requests > 0 {
		app.executors.worker.worker_backend.queue_waiting_requests--
	}
}

fn WorkerBackendQueueMetrics.note_wait(mut app App) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.executors.worker.stat_queue_waits_total++
}

fn WorkerBackendQueueMetrics.note_rejected(mut app App) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.executors.worker.stat_queue_rejected_total++
}

fn WorkerBackendQueueMetrics.note_timeout(mut app App) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.executors.worker.stat_queue_timeouts_total++
}

fn (mut app App) worker_backend_select_socket_queued() !string {
	socket_path := app.worker_backend_select_socket() or {
		if err.msg() != 'all workers busy' {
			return error(err.msg())
		}
		if !WorkerBackendQueue.try_enter(mut app) {
			WorkerBackendQueueMetrics.note_rejected(mut app)
			return error('worker queue full')
		}
		WorkerBackendQueueMetrics.note_wait(mut app)
		defer {
			WorkerBackendQueue.leave(mut app)
		}
		timeout_ms := if app.executors.worker.worker_backend.queue_timeout_ms > 0 {
			app.executors.worker.worker_backend.queue_timeout_ms
		} else {
			0
		}
		poll_ms := if app.executors.worker.worker_backend.queue_poll_ms > 0 {
			app.executors.worker.worker_backend.queue_poll_ms
		} else {
			10
		}
		deadline := time.now().add(time.millisecond * timeout_ms)
		for time.now() < deadline {
			time.sleep(time.millisecond * poll_ms)
			socket := app.worker_backend_select_socket() or { continue }
			return socket
		}
		WorkerBackendQueueMetrics.note_timeout(mut app)
		return error('worker queue timeout')
	}
	return socket_path
}
