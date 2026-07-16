module main

import time
import worker
import json

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

fn (mut runtime EngineRuntime) select_socket_queued_for_state(port EngineLifecyclePort, kind string, mut ws worker.WorkerState) !string {
	socket_path := runtime.select_socket_for_state_core(port, kind, mut ws) or {
		if err.msg() != 'all workers busy' {
			port.emit_fn('worker.select.failed', {
				'kind':             kind
				'error':            err.msg()
				'diagnostics_json': json.encode(worker_selection_diagnostics_for_state(ws))
			})
			return error(err.msg())
		}
		if !WorkerBackendQueue.try_enter_state(mut ws) {
			WorkerBackendQueueMetrics.note_rejected_state(mut ws)
			port.emit_fn('worker.select.failed', {
				'kind':             kind
				'error':            'worker queue full'
				'diagnostics_json': json.encode(worker_selection_diagnostics_for_state(ws))
			})
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
		mut success := false
		mut last_socket := ''
		mut select_err := err
		for time.now() < deadline {
			time.sleep(time.millisecond * poll_ms)
			socket := runtime.select_socket_for_state_core(port, kind, mut ws) or {
				select_err = err
				continue
			}
			last_socket = socket
			success = true
			break
		}
		if success {
			return last_socket
		}
		WorkerBackendQueueMetrics.note_timeout_state(mut ws)
		port.emit_fn('worker.select.failed', {
			'kind':             kind
			'error':            'worker queue timeout: ' + select_err.msg()
			'diagnostics_json': json.encode(worker_selection_diagnostics_for_state(ws))
		})
		return error('worker queue timeout')
	}
	return socket_path
}

fn (mut app App) worker_backend_select_socket_queued() !string {
	port := app.build_engine_lifecycle_port()
	return app.engines.select_socket_for_kind(port, '')
}

fn (mut app App) worker_backend_select_socket_queued_for_state(kind string, mut state worker.WorkerState) !string {
	port := app.build_engine_lifecycle_port()
	return app.engines.select_socket_queued_for_state(port, kind, mut state)
}
