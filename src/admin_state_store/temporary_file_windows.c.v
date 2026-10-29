module admin_state_store

import os
import rand
import windows_files

#include "@VMODROOT/src/windows_files/native.h"

// One operation owns the descriptor until its final pathname cleanup. Keeping
// the inode open prevents reuse of its identity while ownership is checked.
struct TemporaryFile {
	path     string  @[required]
	fd       int     @[required]
	identity os.Stat @[required]
}

fn new_temporary_file(target string, suffix string, mode int) !TemporaryFile {
	path := os.join_path(os.dir(target), '.${os.file_name(target)}.${rand.uuid_v4()}.${suffix}')
	fd := C.vh_open(&char(path.str), C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_EXCL | C.VH_O_CLOEXEC, mode)
	if fd < 0 { return os.last_error() }
	identity := os.Stat{ dev: C.vh_dev(fd), inode: C.vh_ino(fd) }
	return TemporaryFile{ path: path, fd: fd, identity: identity }
}

fn (file TemporaryFile) matches() bool {
	return C.vh_matches(file.path.str, file.identity.dev, file.identity.inode) != 0
}

fn (file TemporaryFile) release() {
	defer { C.vh_close(file.fd) }
	if file.matches() {
		C.vh_remove_owned(file.fd, file.path.str, file.identity.dev, file.identity.inode)
	}
}
