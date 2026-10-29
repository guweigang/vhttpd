module logging

$if !windows {

import os

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

fn C.open(&char, i32, ...int) i32
fn C.close(i32) i32
fn C.write(i32, voidptr, uint) int

// Each append owns its descriptor from allocation through the last write.
// O_CLOEXEC excludes it from worker exec even while the write is in progress.
pub fn append_line(path string, line string) ! {
	append_line_with(path, line, write_log_bytes)!
}

fn append_line_with(path string, line string, writer fn (int, string) !) ! {
	if path.contains('\x00') { return error('invalid_log_path') }
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_APPEND | C.O_CLOEXEC, 0o666)
	if fd < 0 { return os.last_error() }
	defer { C.close(fd) }
	writer(fd, line + '\n')!
}

fn write_log_bytes(fd int, data string) ! {
	mut offset := 0
	for offset < data.len {
		remaining := data[offset..]
		n := C.write(i32(fd), remaining.str, uint(remaining.len))
		if n < 0 {
			if C.errno == C.EINTR { continue }
			return os.last_error()
		}
		if n == 0 { return error('log_short_write') }
		offset += int(n)
	}
}

}
