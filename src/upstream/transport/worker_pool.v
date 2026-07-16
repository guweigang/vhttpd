module transport

import log
import net.unix
import os
import time

#include <signal.h>

fn C.kill(pid int, sig int) int

__global (
	g_managed_worker_processes ManagedWorkerProcessRegistry
)

struct ManagedWorkerProcessRegistry {
mut:
	child_pids []int
}

fn (mut r ManagedWorkerProcessRegistry) register_child_pid(pid int) {
	if pid > 0 {
		r.child_pids << pid
	}
}

fn (r ManagedWorkerProcessRegistry) child_pid_snapshot() []int {
	return r.child_pids.clone()
}

pub fn get_child_pids() []int {
	unsafe {
		return g_managed_worker_processes.child_pid_snapshot()
	}
}

pub struct ManagedWorker {
pub mut:
	id                int
	socket_path       string
	worker_cmd        string
	worker_env        map[string]string
	proc              &os.Process = unsafe { nil }
	restart_count     int
	last_exit_ts      i64
	next_retry_ts     i64
	served_requests   i64
	inflight_requests i64
	draining          bool
}

pub struct WorkerSelectionDiagnostic {
pub:
	socket_path       string
	proc_alive        bool
	draining          bool
	inflight_requests i64
	probe_error       string
}

pub struct ManagedWorkerPool {}

pub fn ManagedWorker.wait_for_socket(socket_path string, timeout_ms int) ! {
	deadline := time.now().add(time.millisecond * timeout_ms)
	for time.now() < deadline {
		mut conn := unix.connect_stream(socket_path) or {
			time.sleep(100 * time.millisecond)
			continue
		}
		conn.close() or {}
		return
	}
	return error('worker socket not ready: ${socket_path}')
}

pub fn ManagedWorker.command_with_socket(worker_cmd string, worker_socket string, pool_size int) !string {
	if worker_cmd == '' {
		return error('empty worker command')
	}
	if worker_socket == '' {
		return error('worker socket is required when autostart is enabled')
	}
	if worker_cmd.contains('{socket}') {
		return worker_cmd.replace('{socket}', worker_socket)
	}
	if pool_size > 1 && worker_cmd.contains('--socket') {
		return error('worker-cmd for pool mode should omit --socket (auto-injected) or use {socket} placeholder')
	}
	if !worker_cmd.contains('--socket') {
		return '${worker_cmd} --socket ${worker_socket}'
	}
	return worker_cmd
}

pub fn ManagedWorker.merge_env(base map[string]string, extra map[string]string) map[string]string {
	mut merged := base.clone()
	for k, v in extra {
		merged[k] = v
	}
	return merged
}

pub fn ManagedWorker.start(id int, worker_cmd string, worker_env map[string]string, worker_socket string, workdir string, pool_size int) !ManagedWorker {
	cmd := ManagedWorker.command_with_socket(worker_cmd, worker_socket, pool_size)!
	mut merged_env := ManagedWorker.merge_env(os.environ(), worker_env)
	merged_env['VHTTPD_PARENT_PID'] = '${os.getpid()}'
	mut proc := os.new_process('/bin/sh')
	redirect_cmd := if cmd.contains('vphp-worker') {
		'exec ${cmd} >> /tmp/vhttpd_php_worker_${id}.log 2>&1'
	} else if cmd.contains('php-cgi') {
		'exec ${cmd} >> /tmp/vhttpd_php_cgi_${id}.log 2>&1'
	} else {
		cmd
	}
	proc.set_args(['-lc', redirect_cmd])
	proc.set_environment(merged_env)
	proc.set_work_folder(workdir)
	proc.use_pgroup = true
	proc.run()
	unsafe {
		g_managed_worker_processes.register_child_pid(proc.pid)
	}
	ManagedWorker.wait_for_socket(worker_socket, 5000)!
	return ManagedWorker{
		id:                id
		socket_path:       worker_socket
		worker_cmd:        cmd
		worker_env:        merged_env
		proc:              proc
		last_exit_ts:      0
		next_retry_ts:     0
		served_requests:   0
		inflight_requests: 0
		draining:          false
	}
}

pub fn ManagedWorker.build_slot(id int, worker_cmd string, worker_env map[string]string, worker_socket string, pool_size int) !ManagedWorker {
	cmd := ManagedWorker.command_with_socket(worker_cmd, worker_socket, pool_size)!
	mut merged_env := ManagedWorker.merge_env(os.environ(), worker_env)
	merged_env['VHTTPD_PARENT_PID'] = '${os.getpid()}'
	return ManagedWorker{
		id:                id
		socket_path:       worker_socket
		worker_cmd:        cmd
		worker_env:        merged_env
		last_exit_ts:      0
		next_retry_ts:     0
		served_requests:   0
		inflight_requests: 0
		draining:          false
	}
}

pub fn (mut w ManagedWorker) stop() {
	if isnil(w.proc) {
		return
	}
	// 向整个子进程组发送 SIGTERM，允许后代进程优雅退出
	C.kill(-w.proc.pid, 15)

	time.sleep(200 * time.millisecond)

	// 无论 /bin/sh 是否已经退出，向整个进程组发送 SIGKILL 以防顽固残留
	w.proc.signal_pgkill()

	w.proc.wait()
	w.proc.close()
}

pub fn ManagedWorkerPool.stop(mut workers []ManagedWorker) {
	for i in 0 .. workers.len {
		mut w := workers[i]
		w.stop()
	}
}

pub fn ManagedWorkerPool.start(worker_cmd string, worker_env map[string]string, worker_sockets []string, workdir string) []ManagedWorker {
	if worker_sockets.len == 0 {
		return []ManagedWorker{}
	}
	mut workers := []ManagedWorker{}
	for i, socket_path in worker_sockets {
		mut slot := ManagedWorker.build_slot(i, worker_cmd, worker_env, socket_path,
			worker_sockets.len) or {
			log.error('worker slot init failed [${i}] ${socket_path}: ${err.msg()}')
			continue
		}
		worker := ManagedWorker.start(i, worker_cmd, worker_env, socket_path, workdir,
			worker_sockets.len) or {
			now := time.now().unix_milli()
			slot.restart_count = 1
			slot.last_exit_ts = now
			slot.next_retry_ts = now + 500
			workers << slot
			log.error('worker start failed [${i}] ${socket_path}: ${err.msg()}')
			continue
		}
		workers << worker
	}
	return workers
}

pub fn ManagedWorkerPool.restart_backoff_ms(restart_count int, base_ms int, max_ms int) int {
	mut delay := if base_ms > 0 { base_ms } else { 500 }
	mut step := if restart_count > 0 { restart_count - 1 } else { 0 }
	for step > 0 {
		delay *= 2
		if delay >= max_ms {
			return max_ms
		}
		step--
	}
	if delay > max_ms {
		return max_ms
	}
	return delay
}
