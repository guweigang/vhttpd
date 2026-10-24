module admin_state_store

import os
import rand

fn C.fcntl(int, int, ...voidptr) int

fn restore_directory_descriptor(path string) int {
	expected := os.lstat(path) or { panic(err) }
	for fd in 0 .. 1024 {
		mut native := C.stat{}
		if C.fstat(fd, &native) == 0 && u64(native.st_dev) == expected.dev && u64(native.st_ino) == expected.inode {
			return fd
		}
	}
	panic('missing restore directory descriptor')
}

fn test_created_directory_descriptors_are_cloexec_and_released_on_success_and_rollback() {
	root := os.join_path(os.real_path(os.temp_dir()), 'restore-directory-fd-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	for fail in [false, true] {
		parent := os.join_path(root, 'created-${fail}')
		leaf := os.join_path(parent, 'nested')
		path := os.join_path(leaf, 'source.toml')
		descriptors := chan []int{cap: 1}
		mut failure := ''
		store.restore_config_files_with([ConfigFileRestore{ path: path, value: 'candidate' }], fn () ! {}, fn [fail] () ! {
			if fail { return error('postcheck_failed') }
		}, fn [parent, leaf, descriptors] (source string, target string) ! {
			owned := [restore_directory_descriptor(parent), restore_directory_descriptor(leaf)]
			descriptors <- owned
			for fd in owned {
				assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
			}
			rename_config_file(source, target)!
		}) or { failure = err.msg() }
		owned := <-descriptors
		assert failure == if fail { 'postcheck_failed' } else { '' }
		for fd in owned {
			assert C.fcntl(fd, C.F_GETFD) == -1
		}
		assert os.exists(parent) == !fail
		assert os.exists(path) == !fail
	}
}
