module logging

import os
import windows_files

#include "@VMODROOT/src/windows_files/native.h"

// Each append owns its descriptor from allocation through the last write.
// O_CLOEXEC excludes it from worker exec even while the write is in progress.
pub fn append_line(path string, line string) ! {
	append_line_with(path, line, write_log_bytes)!
}

fn append_line_with(path string, line string, writer fn (int, string) !) ! {
	if path.contains('\x00') { return error('invalid_log_path') }
	fd := C.vh_open(&char(path.str), C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_APPEND | C.VH_O_CLOEXEC, 0o666)
	if fd < 0 { return os.last_error() }
	defer { C.vh_close(fd) }
	if C.vh_flock(fd, C.VH_LOCK_EX) != 0 { return error('log_lock_failed') }
	if C.vh_lseek(fd, 0, C.SEEK_END) < 0 { return error('log_seek_failed') }
	writer(fd, line + '\n')!
}

fn write_log_bytes(fd int, data string) ! {
	mut offset := 0
	for offset < data.len {
		remaining := data[offset..]
		n := C.vh_write(i32(fd), remaining.str, uint(remaining.len))
		if n < 0 {
			if C.errno == C.EINTR { continue }
			return os.last_error()
		}
		if n == 0 { return error('log_short_write') }
		offset += int(n)
	}
}
