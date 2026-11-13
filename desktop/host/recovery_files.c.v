module host

$if !windows {
import os

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/file.h>

fn C.flock(int, int) int

fn C.fsync(int) int
fn C.rename(&char, &char) int

fn write_recovery_data(path string, bytes []u8) ! {
	fd := C.open(path.str, C.O_WRONLY | C.O_CREAT | C.O_EXCL | C.O_CLOEXEC | C.O_NOFOLLOW, 0o600)
	if fd < 0 { return error('recovery_stage_failed') }
	defer { os.fd_close(fd) }
	mut offset := 0
	for offset < bytes.len {
		written := unsafe { C.write(fd, &u8(bytes.data) + offset, bytes.len - offset) }
		if written < 0 {
			if C.errno == C.EINTR { continue }
			return error('recovery_write_failed')
		}
		if written == 0 { return error('recovery_write_incomplete') }
		offset += int(written)
	}
	if C.fsync(fd) != 0 { return error('recovery_sync_failed') }
}

fn replace_recovery_data(source string, target string) ! {
	if C.rename(source.str, target.str) != 0 { return error('recovery_commit_failed') }
}

fn lock_recovery_archive(path string) !int {
	fd := C.open(path.str, C.O_RDWR | C.O_CREAT | C.O_NOFOLLOW | C.O_CLOEXEC, 0o600)
	if fd < 0 { return error('history_lock_open_failed') }
	if C.flock(fd, C.LOCK_EX | C.LOCK_NB) != 0 { os.fd_close(fd); return error('history_in_use') }
	return fd
}

fn release_recovery_archive(fd int) {
	C.flock(fd, C.LOCK_UN)
	os.fd_close(fd)
}
}
