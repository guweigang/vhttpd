module admin_state_store

import os
import rand

// One operation owns the descriptor until its final pathname cleanup. Keeping
// the inode open prevents reuse of its identity while ownership is checked.
struct TemporaryFile {
	path     string  @[required]
	fd       int     @[required]
	identity os.Stat @[required]
}

fn new_temporary_file(target string, suffix string, mode int) !TemporaryFile {
	path := os.join_path(os.dir(target), '.${os.file_name(target)}.${rand.uuid_v4()}.${suffix}')
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC, mode)
	if fd < 0 { return os.last_error() }
	mut native := C.stat{}
	for C.fstat(fd, &native) != 0 {
		if C.errno == C.EINTR { continue }
		failure := os.last_error()
		C.close(fd)
		return failure
	}
	return TemporaryFile{ path: path, fd: fd, identity: os.Stat{ dev: u64(native.st_dev), inode: u64(native.st_ino) } }
}

fn (file TemporaryFile) matches() bool {
	current := os.lstat(file.path) or { return false }
	return current.get_filetype() == .regular && current.dev == file.identity.dev && current.inode == file.identity.inode
}

fn (file TemporaryFile) release() {
	defer { C.close(file.fd) }
	if file.matches() { os.rm(file.path) or {} }
}
