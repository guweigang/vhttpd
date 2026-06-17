module main

import time
import worker

struct WorkerBackendQueue {}

struct WorkerBackendQueueMetrics {}

fn WorkerBackendQueue.try_enter_state(mut ws worker.WorkerState) bool {
	if ws.worker_backend.queue_capacity <= 0 || ws.worker_backend.queue_timeout_ms <= 0 {
		return false
	}
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.worker_backend.queue_waiting_requests >= ws.worker_backend.queue_capacity {
		return false
	}
	ws.worker_backend.queue_waiting_requests++
	return true
}

fn WorkerBackendQueue.leave_state(mut ws worker.WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.worker_backend.queue_waiting_requests > 0 {
		ws.worker_backend.queue_waiting_requests--
	}
}

fn WorkerBackendQueueMetrics.note_wait_state(mut ws worker.WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	ws.stat_queue_waits_total++
}

fn WorkerBackendQueueMetrics.note_rejected_state(mut ws worker.WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	ws.stat_queue_rejected_total++
}

fn WorkerBackendQueueMetrics.note_timeout_state(mut ws worker.WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	ws.stat_queue_timeouts_total++
}

fn (mut app App) worker_backend_select_socket_queued_for_state(kind string, mut ws worker.WorkerState) !string {
	socket_path := app.worker_backend_select_socket_for_state(kind, mut ws) or {
		if err.msg() != 'all workers busy' {
			return error(err.msg())
		}
		if !WorkerBackendQueue.try_enter_state(mut ws) {
			WorkerBackendQueueMetrics.note_rejected_state(mut ws)
			return error('worker queue full')
		}
		WorkerBackendQueueMetrics.note_wait_state(mut ws)
		defer {
			WorkerBackendQueue.leave_state(mut ws)
		}
		timeout_ms := if ws.worker_backend.queue_timeout_ms > 0 {
			ws.worker_backend.queue_timeout_ms
		} else {
			0
		}
		poll_ms := if ws.worker_backend.queue_poll_ms > 0 {
			ws.worker_backend.queue_poll_ms
		} else {
			10
		}
		deadline := time.now().add(time.millisecond * timeout_ms)
		for time.now() < deadline {
			time.sleep(time.millisecond * poll_ms)
			socket := app.worker_backend_select_socket_for_state(kind, mut ws) or { continue }
			return socket
		}
		WorkerBackendQueueMetrics.note_timeout_state(mut ws)
		return error('worker queue timeout')
	}
	return socket_path
}

fn (mut app App) worker_backend_select_socket_queued() !string {
	return app.worker_backend_select_socket_queued_for_state(app.logic_executor_kind(), mut app.executors.worker)
}
