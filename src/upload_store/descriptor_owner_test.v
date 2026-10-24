module upload_store

import os
import rand

fn upload_anchor_for_test(writer int) int {
	mut original := C.stat{}
	assert C.fstat(writer, &original) == 0
	for fd in 0 .. 1024 {
		if fd == writer { continue }
		mut candidate := C.stat{}
		if C.fstat(fd, &candidate) == 0 && candidate.st_dev == original.st_dev && candidate.st_ino == original.st_ino {
			return fd
		}
	}
	panic('missing upload inode anchor')
}

fn test_upload_anchor_is_cloexec_and_released_after_success_or_writer_error() {
	root := os.join_path(os.temp_dir(), 'vhttpd-upload-fd-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	for fail in [false, true] {
		descriptors := chan []int{cap: 1}
		path := os.join_path(root, 'upload-${fail}')
		mut rejected := false
		save_with(path, 'owned', fn [descriptors, fail] (fd int, data string) ! {
			anchor := upload_anchor_for_test(fd)
			descriptors <- [fd, anchor]
			assert C.fcntl(anchor, C.F_GETFD) & C.FD_CLOEXEC != 0
			write_all(fd, data)!
			if fail { return error('injected_writer_failure') }
		}) or { rejected = true }
		owned := <-descriptors
		assert rejected == fail
		assert C.fcntl(owned[0], C.F_GETFD) == -1
		assert C.fcntl(owned[1], C.F_GETFD) == -1
		assert os.exists(path) == !fail
	}
	assert (os.ls(root) or { panic(err) }).all(!it.starts_with('.upload-'))
}
