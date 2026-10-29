module host

import os

import windows_files

#include "@VMODROOT/src/windows_files/native.h"

fn create_project_file(path string) !int {
	fd := C.vh_open(path.str, C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_EXCL, 0o600)
	if fd < 0 { return error('无法创建项目文件：${path}') }
	return fd
}

fn write_project_contents(fd int, content string) ! {
	defer { C.vh_close(fd) }
	mut offset := 0
	for offset < content.len {
		written := unsafe { C.vh_write(fd, content.str + offset, content.len - offset) }
		if written < 0 {
			if C.errno == C.EINTR { continue }
			return error('项目文件写入失败。')
		}
		if written == 0 { return error('项目文件未完整写入。') }
		offset += int(written)
	}
}
