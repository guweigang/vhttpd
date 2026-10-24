module worker

import time
import json2 as json

struct WorkerBackendQueue {}

struct WorkerBackendQueueMetrics {}

fn WorkerBackendQueue.try_enter_state(mut ws WorkerState) bool {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.backend_admission_error_unlocked() != '' || ws.worker_backend.queue_capacity <= 0 || ws.worker_backend.queue_timeout_ms <= 0 {
		return false
	}
	if ws.worker_backend.queue_waiting_requests >= ws.worker_backend.queue_capacity {
		return false
	}
	ws.worker_backend.queue_waiting_requests++
	return true
}

fn WorkerBackendQueue.leave_state(mut ws WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	if ws.worker_backend.queue_waiting_requests > 0 {
		ws.worker_backend.queue_waiting_requests--
	}
}

fn WorkerBackendQueueMetrics.note_wait_state(mut ws WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	ws.stat_queue_waits_total++
}

fn WorkerBackendQueueMetrics.note_rejected_state(mut ws WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	ws.stat_queue_rejected_total++
}

fn WorkerBackendQueueMetrics.note_timeout_state(mut ws WorkerState) {
	ws.mu.@lock()
	defer {
		ws.mu.unlock()
	}
	ws.stat_queue_timeouts_total++
}

pub fn (mut ws WorkerState) select_socket_queued(port LifecyclePort, kind string) !string {
	lease := ws.select_request_queued(port, kind)!
	return lease.socket_path
}

pub fn (mut ws WorkerState) select_request_queued(port LifecyclePort, kind string) !&RequestLease {
	socket_path := ws.select_request_core(port, kind) or {
		if err.msg() != 'all workers busy' {
			port.emit_fn('worker.select.failed', {
				'kind':             kind
				'error':            err.msg()
				'diagnostics_json': json.encode(ws.selection_diagnostics(),
					escape_unicode: true
					time_as_unix:   true
				)
			})
			return error(err.msg())
		}
		if !WorkerBackendQueue.try_enter_state(mut ws) {
			WorkerBackendQueueMetrics.note_rejected_state(mut ws)
			port.emit_fn('worker.select.failed', {
				'kind':             kind
				'error':            'worker queue full'
				'diagnostics_json': json.encode(ws.selection_diagnostics(),
					escape_unicode: true
					time_as_unix:   true
				)
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
		mut last_lease := ?&RequestLease(none)
		mut select_err := err
		for {
			remaining := deadline - time.now()
			if remaining <= 0 { break }
			poll := time.millisecond * poll_ms
			time.sleep(if poll < remaining { poll } else { remaining })
			if time.now() >= deadline { break }
			mut socket := ws.select_request_core(port, kind) or {
				select_err = err
				if err.msg() != 'all workers busy' {
					port.emit_fn('worker.select.failed', {
						'kind':             kind
						'error':            err.msg()
						'diagnostics_json': json.encode(ws.selection_diagnostics(),
							escape_unicode: true
							time_as_unix:   true
						)
					})
					return err
				}
				continue
			}
			// Readiness/probing can outlast the queue deadline. Return any late
			// lease to this same worker owner without counting it as served.
			if time.now() >= deadline {
				socket.release(port)
				break
			}
			last_lease = socket
			success = true
			break
		}
		if success {
			return last_lease or { return error('worker unavailable') }
		}
		WorkerBackendQueueMetrics.note_timeout_state(mut ws)
		port.emit_fn('worker.select.failed', {
			'kind':             kind
			'error':            'worker queue timeout: ' + select_err.msg()
			'diagnostics_json': json.encode(ws.selection_diagnostics(),
				escape_unicode: true
				time_as_unix:   true
			)
		})
		return error('worker queue timeout')
	}
	return socket_path
}
