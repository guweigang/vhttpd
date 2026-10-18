module main

import worker
import admin

fn worker_admin_status(status worker.ProcessStatus) admin.WorkerAdminStatus {
	return admin.WorkerAdminStatus{
		id:                status.id
		socket:            status.socket
		alive:             status.alive
		pid:               status.pid
		rss_kb:            status.rss_kb
		draining:          status.draining
		inflight_requests: status.inflight_requests
		served_requests:   status.served_requests
		restart_count:     status.restart_count
		next_retry_ts:     status.next_retry_ts
	}
}

fn (mut runtime EngineRuntime) restart_worker_by_id(port worker.LifecyclePort, worker_id int) !admin.WorkerAdminStatus {
	status := runtime.primary.restart_by_id(port, worker_id)!
	return worker_admin_status(status)
}

fn (mut runtime EngineRuntime) restart_all_workers(port worker.LifecyclePort) int {
	return runtime.primary.restart_all(port)
}

fn (mut runtime EngineRuntime) admin_snapshot() admin.WorkerPoolAdminStatus {
	status := runtime.primary.admin_snapshot()
	return admin.WorkerPoolAdminStatus{
		worker_autostart:    status.worker_autostart
		worker_pool_size:    status.worker_pool_size
		worker_rr_index:     status.worker_rr_index
		worker_max_requests: status.worker_max_requests
		worker_sockets:      status.worker_sockets
		workers:             status.workers.map(worker_admin_status(it))
	}
}
