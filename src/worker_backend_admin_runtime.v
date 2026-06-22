module main

import admin
import os
import upstream.transport

struct WorkerProcessMetrics {}

fn WorkerProcessMetrics.admin_status(mut w transport.ManagedWorker) admin.WorkerAdminStatus {
	pid := if isnil(w.proc) { 0 } else { w.proc.pid }
	return admin.WorkerAdminStatus{
		id:                w.id
		socket:            w.socket_path
		alive:             if isnil(w.proc) { false } else { w.proc.is_alive() }
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

fn (mut runtime EngineRuntime) restart_worker_by_id(port EngineLifecyclePort, worker_id int) !admin.WorkerAdminStatus {
	runtime.primary.mu.@lock()
	if !runtime.primary.worker_backend.autostart
		|| runtime.primary.worker_backend.managed_workers.len == 0 {
		runtime.primary.mu.unlock()
		return error('worker pool is not enabled')
	}
	mut idx := -1
	for i, w in runtime.primary.worker_backend.managed_workers {
		if w.id == worker_id {
			idx = i
			break
		}
	}
	runtime.primary.mu.unlock()
	if idx < 0 {
		return error('worker id not found: ${worker_id}')
	}
	runtime.restart_worker_slot_now_for_state(port, mut runtime.primary, idx, 'admin_restart')
	runtime.primary.mu.@lock()
	mut w := runtime.primary.worker_backend.managed_workers[idx]
	runtime.primary.mu.unlock()
	return WorkerProcessMetrics.admin_status(mut w)
}

fn (mut runtime EngineRuntime) restart_all_workers(port EngineLifecyclePort) int {
	runtime.primary.mu.@lock()
	if !runtime.primary.worker_backend.autostart
		|| runtime.primary.worker_backend.managed_workers.len == 0 {
		runtime.primary.mu.unlock()
		return 0
	}
	worker_count := runtime.primary.worker_backend.managed_workers.len
	runtime.primary.mu.unlock()
	mut restarted := 0
	for i in 0 .. worker_count {
		runtime.restart_worker_slot_now_for_state(port, mut runtime.primary, i, 'admin_restart_all')
		restarted++
	}
	return restarted
}

fn (mut runtime EngineRuntime) admin_snapshot() admin.WorkerPoolAdminStatus {
	runtime.primary.mu.@lock()
	defer {
		runtime.primary.mu.unlock()
	}
	mut workers := []admin.WorkerAdminStatus{cap: runtime.primary.worker_backend.managed_workers.len}
	for mut worker in runtime.primary.worker_backend.managed_workers {
		workers << WorkerProcessMetrics.admin_status(mut worker)
	}
	return admin.WorkerPoolAdminStatus{
		worker_autostart:    runtime.primary.worker_backend.autostart
		worker_pool_size:    runtime.primary.worker_backend.sockets.len
		worker_rr_index:     runtime.primary.worker_backend.rr_index
		worker_max_requests: runtime.primary.worker_backend.max_requests
		worker_sockets:      runtime.primary.worker_backend.sockets.clone()
		workers:             workers
	}
}

fn (mut app App) restart_worker_by_id(worker_id int) !admin.WorkerAdminStatus {
	port := app.build_engine_lifecycle_port()
	return app.engines.restart_worker_by_id(port, worker_id)
}

fn (mut app App) restart_all_workers() int {
	port := app.build_engine_lifecycle_port()
	return app.engines.restart_all_workers(port)
}

fn (mut app App) worker_admin_snapshot() admin.WorkerPoolAdminStatus {
	return app.engines.admin_snapshot()
}
