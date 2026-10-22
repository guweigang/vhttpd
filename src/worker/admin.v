module worker

import os
import upstream.transport

pub struct ProcessStatus {
pub:
	id                int
	socket            string
	alive             bool
	pid               int
	rss_kb            i64
	draining          bool
	inflight_requests i64
	served_requests   i64
	restart_count     int
	next_retry_ts     i64
}

pub struct PoolStatus {
pub:
	worker_autostart    bool
	worker_pool_size    int
	worker_rr_index     int
	worker_max_requests int
	worker_sockets      []string
	workers             []ProcessStatus
}

struct WorkerProcessMetrics {}

fn WorkerProcessMetrics.admin_status(mut w transport.ManagedWorker) ProcessStatus {
	alive := w.process_alive()
	pid := if alive {
		if proc := w.proc { proc.pid } else { 0 }
	} else {
		0
	}
	return ProcessStatus{
		id:                w.id
		socket:            w.socket_path
		alive:             alive
		pid:               pid
		rss_kb:            WorkerProcessMetrics.rss_kb(pid)
		draining:          w.draining
		inflight_requests: w.inflight_requests
		served_requests:   w.served_requests
		restart_count:     w.restart_count
		next_retry_ts:     w.next_retry_ts
	}
}

fn WorkerProcessMetrics.rss_kb(pid int) i64 {
	if pid <= 0 {
		return 0
	}
	// `ps -o rss=` is portable across macOS/Linux and returns RSS in KB.
	res := os.exec(['ps', '-o', 'rss=', '-p', pid.str()])
	if res.exit_code != 0 {
		return 0
	}
	rss_raw := res.output.trim_space()
	if rss_raw == '' {
		return 0
	}
	return rss_raw.i64()
}

pub fn (mut state WorkerState) restart_by_id(port LifecyclePort, worker_id int) !ProcessStatus {
	state.mu.@lock()
	admission_error := state.backend_admission_error_unlocked()
	if admission_error != '' {
		state.mu.unlock()
		return error(admission_error)
	}
	if !state.worker_backend.autostart
		|| state.worker_backend.managed_workers.len == 0 {
		state.mu.unlock()
		return error('worker pool is not enabled')
	}
	mut idx := -1
	for i, w in state.worker_backend.managed_workers {
		if w.id == worker_id {
			idx = i
			break
		}
	}
	state.mu.unlock()
	if idx < 0 {
		return error('worker id not found: ${worker_id}')
	}
	state.restart_slot(port, idx, 'admin_restart')
	state.mu.@lock()
	if state.backend_admission_error_unlocked() != '' {
		state.mu.unlock()
		return error('worker_backend_stopping')
	}
	if idx >= state.worker_backend.managed_workers.len || state.worker_backend.managed_workers[idx].id != worker_id {
		state.mu.unlock()
		return error('worker id not found: ${worker_id}')
	}
	mut w := state.worker_backend.managed_workers[idx]
	state.mu.unlock()
	return WorkerProcessMetrics.admin_status(mut w)
}

pub fn (mut state WorkerState) restart_all(port LifecyclePort) int {
	state.mu.@lock()
	if state.backend_admission_error_unlocked() != '' || !state.worker_backend.autostart
		|| state.worker_backend.managed_workers.len == 0 {
		state.mu.unlock()
		return 0
	}
	worker_count := state.worker_backend.managed_workers.len
	state.mu.unlock()
	mut restarted := 0
	for i in 0 .. worker_count {
		state.restart_slot(port, i, 'admin_restart_all')
		state.mu.@lock()
		available := state.backend_admission_error_unlocked() == '' && i < state.worker_backend.managed_workers.len
		state.mu.unlock()
		if !available { break }
		restarted++
	}
	return restarted
}

pub fn (mut state WorkerState) admin_snapshot() PoolStatus {
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	mut workers := []ProcessStatus{cap: state.worker_backend.managed_workers.len}
	for mut worker in state.worker_backend.managed_workers {
		workers << WorkerProcessMetrics.admin_status(mut worker)
	}
	return PoolStatus{
		worker_autostart:    state.worker_backend.autostart
		worker_pool_size:    state.worker_backend.sockets.len
		worker_rr_index:     state.worker_backend.rr_index
		worker_max_requests: state.worker_backend.max_requests
		worker_sockets:      state.worker_backend.sockets.clone()
		workers:             workers
	}
}
