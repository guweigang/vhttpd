module host

import os

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

fn C.open(&char, i32, ...int) i32

fn create_project_file(path string) !int {
	fd := C.open(path.str, C.O_WRONLY | C.O_CREAT | C.O_EXCL, 0o600)
	if fd < 0 { return error('无法创建项目文件：${path}') }
	return fd
}

fn write_project_contents(fd int, content string) ! {
	defer { os.fd_close(fd) }
	mut offset := 0
	for offset < content.len {
		written := unsafe { C.write(fd, content.str + offset, content.len - offset) }
		if written < 0 {
			if C.errno == C.EINTR { continue }
			return error('项目文件写入失败。')
		}
		if written == 0 { return error('项目文件未完整写入。') }
		offset += int(written)
	}
}
