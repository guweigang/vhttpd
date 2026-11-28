module process_runtime

import os
import sync
$if !windows {
import time
}

// glibc exposes the SO_PEERCRED payload only with GNU feature visibility.
#flag linux -D_GNU_SOURCE

$if !windows {
#include "@VMODROOT/src/process_runtime/posix_process.h"

fn C.vhttpd_child_state(int) int
fn C.vhttpd_child_owns_socket(int, int) int
fn C.kill(int, int) int
}

__global (
	g_managed_process_registry ManagedProcessRegistry
)

// The process-wide owner serializes launch, observation, retirement and shutdown.
// Callers borrow handles; only this owner may reap managed worker children.
struct ManagedProcessRegistry {
mut:
	mu        sync.Mutex
	processes map[int]&os.Process
	stopping  bool
}

pub struct LaunchConfig {
pub:
	command     string @[required]
	environment map[string]string
	workdir     string
}

fn (mut r ManagedProcessRegistry) launch(config LaunchConfig) !&os.Process {
	r.mu.@lock()
	defer { r.mu.unlock() }
	if r.stopping { return error('managed_process_registry_stopping') }
	mut proc := os.new_process($if windows { os.getenv_opt('COMSPEC') or { 'cmd.exe' } } $else { '/bin/sh' })
	$if windows {
		proc.set_args(['/d', '/s', '/c', config.command])
		proc.create_no_window = true
	} $else { proc.set_args(['-lc', config.command]) }
	proc.set_environment(config.environment)
	proc.set_work_folder(config.workdir)
	proc.use_pgroup = true
	proc.run()
	if proc.pid <= 0 {
		proc.close()
		return error('managed_process_spawn_failed:${proc.err}')
	}
	r.processes[proc.pid] = proc
	return proc
}

fn (r &ManagedProcessRegistry) owns(proc &os.Process) bool {
	owner := r.processes[proc.pid] or { return false }
	return voidptr(owner) == voidptr(proc)
}

// Must hold mu. Remove ownership before reap makes the PID reusable.
fn (mut r ManagedProcessRegistry) retire_locked(mut proc os.Process, graceful bool) {
	if !r.owns(proc) { return }
	r.processes.delete(proc.pid)
	$if windows {
		if proc.is_alive() {
			proc.signal_pgkill()
			proc.wait()
		}
	} $else {
	state := C.vhttpd_child_state(proc.pid)
	if state >= 0 {
		if graceful && state == 1 {
			if C.kill(-proc.pid, 15) != 0 { C.kill(proc.pid, 15) }
			time.sleep(200 * time.millisecond)
		}
		if C.kill(-proc.pid, 9) != 0 { C.kill(proc.pid, 9) }
		proc.wait()
	}

	}
	proc.close()
}

fn (mut r ManagedProcessRegistry) retire(mut proc os.Process, graceful bool) {
	r.mu.@lock()
	defer { r.mu.unlock() }
	r.retire_locked(mut proc, graceful)
}

fn (mut r ManagedProcessRegistry) alive(mut proc os.Process) bool {
	r.mu.@lock()
	defer { r.mu.unlock() }
	if !r.owns(proc) { return false }
	if managed_child_alive(mut proc) { return true }
	r.retire_locked(mut proc, false)
	return false
}

fn (mut r ManagedProcessRegistry) snapshot() []int {
	r.mu.@lock()
	defer { r.mu.unlock() }
	mut pids := []int{}
	for pid in r.processes.keys() {
		mut proc := r.processes[pid] or { continue }
		if managed_child_alive(mut proc) {
			pids << pid
		} else {
			r.retire_locked(mut proc, false)
		}
	}
	return pids
}

fn (mut r ManagedProcessRegistry) shutdown() {
	r.mu.@lock()
	defer { r.mu.unlock() }
	r.stopping = true
	for pid in r.processes.keys() {
		mut proc := r.processes[pid] or { continue }
		r.retire_locked(mut proc, false)
	}
}

pub fn launch_managed_process(config LaunchConfig) !&os.Process {
	unsafe {
		return g_managed_process_registry.launch(config)!
	}
}

pub fn retire_managed_process(mut proc os.Process, graceful bool) {
	unsafe { g_managed_process_registry.retire(mut proc, graceful) }
}

pub fn managed_process_alive(mut proc os.Process) bool {
	unsafe {
		return g_managed_process_registry.alive(mut proc)
	}
}

pub fn managed_process_pids() []int {
	unsafe {
		return g_managed_process_registry.snapshot()
	}
}

pub fn shutdown_managed_processes() {
	unsafe { g_managed_process_registry.shutdown() }
}

// Keep identity and the unreaped child PID stable across the native peer check.
pub fn managed_process_owns_socket(proc &os.Process, fd int) bool {
	$if windows {
		// POSIX Unix-socket peer credential admission is not a Windows capability.
		return false
	} $else {
	unsafe {
		g_managed_process_registry.mu.@lock()
		defer { g_managed_process_registry.mu.unlock() }
		if !g_managed_process_registry.owns(proc) || C.vhttpd_child_state(proc.pid) != 1 { return false }
		return C.vhttpd_child_owns_socket(proc.pid, fd) == 1
	}
}
}

fn managed_child_alive(mut proc os.Process) bool {
 $if windows { return proc.is_alive() } $else { return C.vhttpd_child_state(proc.pid) == 1 }
}
