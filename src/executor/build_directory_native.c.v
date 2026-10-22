module executor

import os

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

fn C.open(&char, i32, ...int) i32
fn C.close(i32) i32
fn C.fstat(i32, &C.stat) i32

// Keep the directory inode alive until release, so inode-number reuse cannot
// make a replacement path appear to belong to the old owner.
fn retain_build_directory(path string, identity os.Stat) !int {
	fd := C.open(&char(path.str), C.O_RDONLY | C.O_DIRECTORY | C.O_NOFOLLOW | C.O_CLOEXEC)
	if fd < 0 { return os.last_error() }
	mut native := C.stat{}
	if C.fstat(fd, &native) != 0 {
		failure := os.last_error()
		C.close(fd)
		return failure
	}
	if u64(native.st_dev) != identity.dev || u64(native.st_ino) != identity.inode {
		C.close(fd)
		return error('inproc_vjsx_executor_build_directory_replaced')
	}
	return int(fd)
}

fn close_build_directory(fd int) {
	C.close(i32(fd))
}
