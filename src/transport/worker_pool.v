module transport

import config

import log
import net.unix
import os
import time

pub struct ManagedWorker {
	id          int
	socket_path string
	worker_cmd  string
	worker_env  map[string]string
mut:
	proc              &os.Process = unsafe { nil }
	restart_count     int
	last_exit_ts      i64
	next_retry_ts     i64
	served_requests   i64
	inflight_requests i64
	draining          bool
}

struct WorkerSelectionDiagnostic {
	socket_path       string
	proc_alive        bool
	draining          bool
	inflight_requests i64
	probe_error       string
}

pub fn wait_for_worker(socket_path string, timeout_ms int) ! {
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

pub fn cmd_with_socket(worker_cmd string, worker_socket string, pool_size int) !string {
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

pub fn merge_worker_env(base map[string]string, extra map[string]string) map[string]string {
	mut merged := base.clone()
	for k, v in extra {
		merged[k] = v
	}
	return merged
}

pub fn start_managed_worker(id int, worker_cmd string, worker_env map[string]string, worker_socket string, workdir string, pool_size int) !ManagedWorker {
	cmd := cmd_with_socket(worker_cmd, worker_socket, pool_size)!
	mut merged_env := merge_worker_env(os.environ(), worker_env)
	merged_env['VHTTPD_PARENT_PID'] = '${os.getpid()}'
	mut proc := os.new_process('/bin/sh')
	proc.set_args(['-lc', cmd])
	proc.set_environment(merged_env)
	proc.set_work_folder(workdir)
	proc.use_pgroup = true
	proc.run()
	wait_for_worker(worker_socket, 5000)!
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

pub fn build_managed_worker_slot(id int, worker_cmd string, worker_env map[string]string, worker_socket string, pool_size int) !ManagedWorker {
	cmd := cmd_with_socket(worker_cmd, worker_socket, pool_size)!
	mut merged_env := merge_worker_env(os.environ(), worker_env)
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

fn (mut w ManagedWorker) stop() {
	if isnil(w.proc) {
		return
	}
	if w.proc.is_alive() {
		w.proc.signal_term()
		time.sleep(200 * time.millisecond)
		if w.proc.is_alive() {
			w.proc.signal_pgkill()
			time.sleep(100 * time.millisecond)
		}
		if w.proc.is_alive() {
			w.proc.signal_kill()
		}
		w.proc.wait()
	}
	w.proc.close()
}

pub fn stop_worker_pool(mut workers []ManagedWorker) {
	for i in 0 .. workers.len {
		mut w := workers[i]
		w.stop()
	}
}

pub fn socket_prefix(worker_socket string) string {
	if worker_socket.len >= 5 && worker_socket.ends_with('.sock') {
		return worker_socket[..worker_socket.len - 5]
	}
	if worker_socket != '' {
		return worker_socket
	}
	return '/tmp/vslim_worker'
}

pub fn resolve_worker_sockets_with_defaults(args []string, default_worker_socket string, default_pool_size int, default_socket_prefix string, default_worker_sockets string) []string {
	worker_sockets_arg := config.arg_string_or(args, '--worker-sockets', default_worker_sockets)
	if worker_sockets_arg != '' {
		mut sockets := []string{}
		for raw in worker_sockets_arg.split(',') {
			s := raw.trim_space()
			if s != '' {
				sockets << s
			}
		}
		return sockets
	}
	worker_socket := config.arg_string_or(args, '--worker-socket', default_worker_socket)
	pool_size := config.arg_int_or(args, '--worker-pool-size', default_pool_size)
	if pool_size <= 1 {
		return if worker_socket == '' { []string{} } else { [worker_socket] }
	}
	mut prefix := config.arg_string_or(args, '--worker-socket-prefix', default_socket_prefix)
	if prefix == '' {
		prefix = socket_prefix(worker_socket)
	}
	mut sockets := []string{cap: pool_size}
	for i in 0 .. pool_size {
		sockets << '${prefix}_${i}.sock'
	}
	return sockets
}

pub fn start_worker_pool(worker_cmd string, worker_env map[string]string, worker_sockets []string, workdir string) []ManagedWorker {
	if worker_sockets.len == 0 {
		return []ManagedWorker{}
	}
	mut workers := []ManagedWorker{}
	for i, socket_path in worker_sockets {
		mut slot := build_managed_worker_slot(i, worker_cmd, worker_env, socket_path,
			worker_sockets.len) or {
			log.error('worker slot init failed [${i}] ${socket_path}: ${err.msg()}')
			continue
		}
		worker := start_managed_worker(i, worker_cmd, worker_env, socket_path, workdir,
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

pub fn restart_backoff_ms(restart_count int, base_ms int, max_ms int) int {
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
