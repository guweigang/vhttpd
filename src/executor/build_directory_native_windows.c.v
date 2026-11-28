module executor

import os
import windows_files

#include "@VMODROOT/src/windows_files/native.h"

fn retain_build_directory(path string, identity os.Stat) !int {
	fd := C.vh_open_dir(path.str)
	if fd < 0 { return error('inproc_vjsx_executor_build_directory_open_failed') }
	if C.vh_dev(fd) != identity.dev || C.vh_ino(fd) != identity.inode {
		C.vh_close(fd)
		return error('inproc_vjsx_executor_build_directory_replaced')
	}
	return fd
}

fn close_build_directory(fd int) { C.vh_close(fd) }

fn windows_build_directory_identity(path string) !os.Stat {
	fd := C.vh_open_dir(path.str)
	if fd < 0 { return error('inproc_vjsx_executor_build_directory_open_failed') }
	defer { C.vh_close(fd) }
	return os.Stat{ dev: C.vh_dev(fd), inode: C.vh_ino(fd) }
}
