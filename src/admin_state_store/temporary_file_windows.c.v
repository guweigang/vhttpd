module admin_state_store

import os
import rand
import sync
import windows_files

#include "@VMODROOT/src/windows_files/native.h"

// One operation owns the descriptor until its final pathname cleanup. Keeping
// the inode open prevents reuse of its identity while ownership is checked.
@[heap]
struct WindowsTemporaryOwner {
mut:
	mu     sync.Mutex
	closed bool
}

struct TemporaryFile {
	path     string                 @[required]
	fd       int                    @[required]
	identity os.Stat                @[required]
	owner    &WindowsTemporaryOwner @[required]
}

fn new_temporary_file(target string, suffix string, mode int) !TemporaryFile {
	path := os.join_path(os.dir(target), '.${os.file_name(target)}.${rand.uuid_v4()}.${suffix}')
	fd := C.vh_open(&char(path.str), C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_EXCL | C.VH_O_CLOEXEC, mode)
	if fd < 0 { return os.last_error() }
	identity := os.Stat{ dev: C.vh_dev(fd), inode: C.vh_ino(fd) }
	return TemporaryFile{ path: path, fd: fd, identity: identity, owner: &WindowsTemporaryOwner{} }
}

fn (file TemporaryFile) matches() bool {
	return C.vh_matches(file.path.str, file.identity.dev, file.identity.inode) != 0
}

// Windows rejects replacement of a published target while our old handle
// remains open. The pathname transfer ends temporary ownership; later cleanup
// must not close a descriptor number that another operation has already reused.
fn (file TemporaryFile) close_published() {
	mut owner := file.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed || file.matches() { return }
	C.vh_close(file.fd)
	owner.closed = true
}

fn (file TemporaryFile) release() {
	mut owner := file.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed { return }
	if file.matches() {
		C.vh_remove_owned(file.fd, file.path.str, file.identity.dev, file.identity.inode)
	}
	C.vh_close(file.fd)
	owner.closed = true
}
