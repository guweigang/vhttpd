module executor

import os

fn C.fcntl(i32, i32, ...voidptr) i32

fn test_build_directory_inode_handle_excluded_from_exec_and_closed_on_release() ! {
	root := directory_identity_root('descriptor')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	for replaced in [false, true] {
		mut owner := VjsxBuildDirectory.reserve(root + '/build')!
		fd := owner.fd
		assert C.fcntl(i32(fd), C.F_GETFD, 0) & C.FD_CLOEXEC != 0
		control := C.fcntl(i32(fd), C.F_DUPFD, 0)
		assert control >= 0
		mut child := os.new_process(os.find_abs_path_of_executable('test')!)
		child.set_args(['-d', '/dev/fd/${control}', '-a', '!', '-d', '/dev/fd/${fd}'])
		child.run()
		child.wait()
		code := child.code
		child.close()
		C.close(control)
		assert code == 0
		if replaced {
			os.rename(owner.path, root + '/moved')!
			os.mkdir(owner.path)!
		}
		owner.release()
		assert C.fcntl(i32(fd), C.F_GETFD, 0) < 0
		// Reuse the freed number: duplicate release must not close a new owner.
		mut next := VjsxBuildDirectory.reserve(root + '/next')!
		owner.release()
		assert C.fcntl(i32(next.fd), C.F_GETFD, 0) >= 0
		next.release()
	}
}
