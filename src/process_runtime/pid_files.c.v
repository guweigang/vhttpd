module process_runtime

import os
import sync

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

fn C.open(&char, int, ...int) int
fn C.write(int, voidptr, usize) isize
fn C.close(int) int
fn C.fstat(int, &C.stat) int

__global (
	g_pid_files PidFiles
)

struct PidFile {
	path     string
	fd       int
	identity os.Stat
}

// PID files describe the process, not an App or a listener configuration.
// Keep the descriptor open until cleanup so the original inode cannot recycle.
@[heap]
pub struct PidFiles {
mut:
	mu     sync.Mutex
	closed bool
	files  map[string]PidFile
}

fn (file PidFile) matches() bool {
	current := os.lstat(file.path) or { return false }
	return current.get_filetype() == .regular && current.dev == file.identity.dev && current.inode == file.identity.inode
}

fn (file PidFile) dispose(check_contents bool) {
	if file.matches() {
		if !check_contents || (os.read_file(file.path) or { '' }) == '${os.getpid()}' {
			os.rm(file.path) or {}
		}
	}
	C.close(file.fd)
}

fn create_pid_file(path string) !PidFile {
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC, 0o644)
	if fd < 0 { return error('cannot acquire PID file ${path}: ${os.last_error()}') }
	mut native := C.stat{}
	if C.fstat(fd, &native) != 0 {
		C.close(fd)
		return error('cannot stat PID file ${path}')
	}
	identity := os.Stat{ dev: u64(native.st_dev), inode: u64(native.st_ino) }
	file := PidFile{ path: path, fd: fd, identity: identity }
	if !file.matches() {
		C.close(fd)
		return error('PID file replaced during creation: ${path}')
	}
	text := '${os.getpid()}'
	if C.write(fd, text.str, usize(text.len)) != text.len {
		file.dispose(false)
		return error('cannot write PID file ${path}')
	}
	return file
}

// Acquire all distinct listener paths as one batch. Failure rolls back only
// files created by this attempt; existing files (including stale PIDs) survive.
pub fn (mut owner PidFiles) acquire(paths []string) ! {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed { return error('pid_files_closed') }
	mut pending := map[string]PidFile{}
	mut committed := false
	defer {
		if !committed {
			for _, file in pending { file.dispose(true) }
		}
	}
	for path in paths {
		if path.trim_space() == '' || path.contains('\x00') {
			return error('invalid PID file path')
		}
		absolute := os.abs_path(path)
		if file := owner.files[absolute] {
			if !file.matches() || (os.read_file(absolute) or { '' }) != '${os.getpid()}' {
				return error('PID file ownership changed: ${absolute}')
			}
			continue
		}
		if absolute in pending { continue }
		pending[absolute] = create_pid_file(absolute)!
	}
	for path, file in pending { owner.files[path] = file }
	committed = true
}

// Terminal and idempotent. Stop admission before removing paths, and never
// infer ownership from a matching PID number or a configuration's filename.
pub fn (mut owner PidFiles) close() {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed { return }
	owner.closed = true
	for _, file in owner.files { file.dispose(true) }
	owner.files.clear()
}

pub fn acquire_pid_files(paths []string) ! {
	unsafe { g_pid_files.acquire(paths)! }
}

pub fn close_pid_files() {
	unsafe { g_pid_files.close() }
}
