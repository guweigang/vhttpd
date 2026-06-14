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

fn (mut app App) restart_worker_by_id(worker_id int) !admin.WorkerAdminStatus {
	app.executors.worker.mu.@lock()
	if !app.executors.worker.worker_backend.autostart || app.executors.worker.worker_backend.managed_workers.len == 0 {
		app.executors.worker.mu.unlock()
		return error('worker pool is not enabled')
	}
	mut idx := -1
	for i, w in app.executors.worker.worker_backend.managed_workers {
		if w.id == worker_id {
			idx = i
			break
		}
	}
	app.executors.worker.mu.unlock()
	if idx < 0 {
		return error('worker id not found: ${worker_id}')
	}
	app.restart_worker_slot_now(idx, 'admin_restart')
	app.executors.worker.mu.@lock()
	mut w := app.executors.worker.worker_backend.managed_workers[idx]
	app.executors.worker.mu.unlock()
	return WorkerProcessMetrics.admin_status(mut w)
}

fn (mut app App) restart_all_workers() int {
	app.executors.worker.mu.@lock()
	if !app.executors.worker.worker_backend.autostart || app.executors.worker.worker_backend.managed_workers.len == 0 {
		app.executors.worker.mu.unlock()
		return 0
	}
	worker_count := app.executors.worker.worker_backend.managed_workers.len
	app.executors.worker.mu.unlock()
	mut restarted := 0
	for i in 0 .. worker_count {
		app.restart_worker_slot_now(i, 'admin_restart_all')
		restarted++
	}
	return restarted
}

fn (mut app App) worker_admin_snapshot() admin.WorkerPoolAdminStatus {
	app.executors.worker.mu.@lock()
	defer {
		app.executors.worker.mu.unlock()
	}
	mut workers := []admin.WorkerAdminStatus{cap: app.executors.worker.worker_backend.managed_workers.len}
	for mut worker in app.executors.worker.worker_backend.managed_workers {
		workers << WorkerProcessMetrics.admin_status(mut worker)
	}
	return admin.WorkerPoolAdminStatus{
		worker_autostart:    app.executors.worker.worker_backend.autostart
		worker_pool_size:    app.executors.worker.worker_backend.sockets.len
		worker_rr_index:     app.executors.worker.worker_backend.rr_index
		worker_max_requests: app.executors.worker.worker_backend.max_requests
		worker_sockets:      app.executors.worker.worker_backend.sockets.clone()
		workers:             workers
	}
}
