module host

import windows_files

#include "@VMODROOT/src/windows_files/native.h"

fn write_recovery_data(path string, bytes []u8) ! {
	fd := C.vh_open(path.str, C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_EXCL | C.VH_O_CLOEXEC | C.VH_O_NOFOLLOW, 0o600)
	if fd < 0 { return error('recovery_stage_failed') }
	defer { C.vh_close(fd) }
	mut offset := 0
	for offset < bytes.len {
		written := unsafe { C.vh_write(fd, &u8(bytes.data) + offset, bytes.len - offset) }
		if written < 0 {
			if C.errno == C.EINTR { continue }
			return error('recovery_write_failed')
		}
		if written == 0 { return error('recovery_write_incomplete') }
		offset += int(written)
	}
	if C.vh_fsync(fd) != 0 { return error('recovery_sync_failed') }
}

fn replace_recovery_data(source string, target string) ! {
	if C.vh_rename(source.str, target.str) != 0 { return error('recovery_commit_failed') }
}

fn lock_recovery_archive(path string) !int {
	fd := C.vh_open(path.str, C.VH_O_RDWR | C.VH_O_CREAT | C.VH_O_NOFOLLOW | C.VH_O_CLOEXEC, 0o600)
	if fd < 0 { return error('history_lock_open_failed') }
	if C.vh_flock(fd, C.VH_LOCK_EX | C.VH_LOCK_NB) != 0 {
		C.vh_close(fd)
		return error('history_in_use')
	}
	return fd
}

fn release_recovery_archive(fd int) {
	C.vh_flock(fd, C.VH_LOCK_UN)
	C.vh_close(fd)
}
