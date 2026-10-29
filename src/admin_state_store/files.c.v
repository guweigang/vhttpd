module admin_state_store

import os

#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>

fn C.open(&char, int, ...int) int
fn C.close(int) int
fn C.flock(int, int) int
fn C.write(int, voidptr, uint) int
fn C.rename(&char, &char) int
fn C.lseek(int, i64, int) i64
fn C.ftruncate(i32, u64) i32

// The stable lock-file inode owns synchronization across request-local store
// values, Apps and processes. Never unlink it while leases may still exist.
// No descriptor outlives an operation; close also releases the advisory lock.
struct DirectoryLease {
	fd int @[required]
}

fn lock_directory(root string, exclusive bool) !DirectoryLease {
	path := os.join_path(root, '.vhttpd.lock')
	fd := C.open(&char(path.str), C.O_RDWR | C.O_CREAT | C.O_CLOEXEC | C.O_NOFOLLOW, 0o666)
	if fd < 0 { return os.last_error() }
	mut admitted := false
	defer { if !admitted { C.close(fd) } }
	mut identity := C.stat{}
	for C.fstat(fd, &identity) != 0 {
		if C.errno == C.EINTR { continue }
		return os.last_error()
	}
	if identity.st_mode & C.S_IFMT != C.S_IFREG {
		return error('admin_state_store_lock_not_regular')
	}
	for C.flock(fd, if exclusive { C.LOCK_EX } else { C.LOCK_SH }) != 0 {
		if C.errno == C.EINTR { continue }
		return os.last_error()
	}
	// The fd may have waited on an inode retired while another request acquired
	// the replacement lock. Only publish a lease for the current regular entry.
	current := os.lstat(path) or { return error('admin_state_store_lock_ownership_changed') }
	if current.get_filetype() != .regular || current.dev != u64(identity.st_dev) || current.inode != u64(identity.st_ino) {
		return error('admin_state_store_lock_ownership_changed')
	}
	admitted = true
	return DirectoryLease{ fd: fd }
}

fn (lease DirectoryLease) release() {
	C.close(lease.fd)
}

fn write_all(fd int, data string) ! {
	mut offset := 0
	for offset < data.len {
		remaining := data[offset..]
		written := C.write(fd, remaining.str, uint(remaining.len))
		if written < 0 {
			if C.errno == C.EINTR { continue }
			return os.last_error()
		}
		if written == 0 { return error('admin_state_store_short_write') }
		offset += int(written)
	}
}

fn atomic_write(path string, value string) ! {
	atomic_write_with(path, value, write_all)!
}

// Own the exclusive temporary fd and inode through exact-path publication.
// Do not use os.mv/rename: they can copy on failure or move into a directory.
fn atomic_write_with(path string, value string, writer fn (int, string) !) ! {
	os.mkdir_all(os.dir(path))!
	temporary := new_temporary_file(path, 'tmp', 0o666)!
	defer { temporary.release() }
	writer(temporary.fd, value)!
	if !temporary.matches() {
		return error('admin_state_store_temporary_ownership_changed:' + path)
	}
	if C.rename(&char(temporary.path.str), &char(path.str)) != 0 { return os.last_error() }
}

fn append_line(path string, line string) ! {
	append_line_with(path, line, write_all)!
}

// Called under an exclusive directory lease. An interrupted/failed append
// rolls back its own tail so later readers never inherit a partial JSON line.
fn append_line_with(path string, line string, writer fn (int, string) !) ! {
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_APPEND | C.O_CLOEXEC | C.O_NOFOLLOW, 0o666)
	if fd < 0 { return os.last_error() }
	defer { C.close(fd) }
	start := C.lseek(fd, 0, C.SEEK_END)
	if start < 0 { return os.last_error() }
	writer(fd, line + '\n') or {
		write_error := err
		if C.ftruncate(fd, u64(start)) != 0 {
			return error('admin_state_store_append_rollback_failed:${os.last_error()}; write:${write_error}')
		}
		return write_error
	}
}
