module upload_store

import os
import rand

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

fn C.open(&char, int, ...int) int
fn C.close(int) int
fn C.write(int, voidptr, uint) int
fn C.link(&char, &char) int
fn C.fstat(int, &C.stat) int
fn C.fcntl(int, int, ...voidptr) int

// The request owns its unpublished file until all bytes are written and the fd
// is closed. Publication transfers the completed file to upload-directory
// storage; it must never overwrite an existing upload or follow its symlink.
pub fn save(path string, data string) ! {
	save_with(path, data, write_all)!
}

fn save_with(path string, data string, writer fn (int, string) !) ! {
	temporary := os.join_path(os.dir(path), '.upload-${rand.uuid_v4()}.tmp')
	fd := C.open(&char(temporary.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC, 0o666)
	if fd < 0 { return os.last_error() }
	mut closed := false
	defer { if !closed { C.close(fd) } }
	mut native := C.stat{}
	for C.fstat(fd, &native) != 0 {
		if C.errno == C.EINTR { continue }
		return os.last_error()
	}
	identity := os.Stat{ dev: u64(native.st_dev), inode: u64(native.st_ino) }
	// Keep the inode pinned after closing the writer, until publication and
	// path cleanup finish. A reused inode cannot impersonate this temporary.
	anchor := C.fcntl(fd, C.F_DUPFD_CLOEXEC, 0)
	if anchor < 0 {
		failure := os.last_error()
		remove_owned_temporary(temporary, identity)
		return failure
	}
	defer {
		remove_owned_temporary(temporary, identity)
		C.close(anchor)
	}
	writer(fd, data)!
	// close can consume the descriptor even when it returns an error; never retry
	// it, since another request may already have reused that descriptor number.
	closed = true
	if C.close(fd) != 0 { return os.last_error() }
	if !owns_temporary(temporary, identity) { return error('upload_temporary_ownership_changed') }
	// Both paths share a directory/filesystem. link provides exact-path atomic
	// publication without replacement; rename/mv would overwrite an existing file.
	if C.link(&char(temporary.str), &char(path.str)) != 0 { return os.last_error() }
}

// Only unlink a directory entry still naming the pinned regular file.
fn owns_temporary(path string, identity os.Stat) bool {
	current := os.lstat(path) or { return false }
	return current.get_filetype() == .regular && current.dev == identity.dev && current.inode == identity.inode
}

fn remove_owned_temporary(path string, identity os.Stat) {
	if owns_temporary(path, identity) { os.rm(path) or {} }
}

fn write_all(fd int, data string) ! {
	mut offset := 0
	for offset < data.len {
		remaining := data[offset..]
		n := C.write(fd, remaining.str, uint(remaining.len))
		if n < 0 {
			if C.errno == C.EINTR { continue }
			return os.last_error()
		}
		if n == 0 { return error('upload_short_write') }
		offset += int(n)
	}
}
