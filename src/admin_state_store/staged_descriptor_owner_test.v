module admin_state_store

import os
import rand

fn C.fcntl(int, int, ...voidptr) int

fn staged_open_fd_count() int {
	mut count := 0
	for fd in 0 .. 1024 { if C.fcntl(fd, C.F_GETFD) >= 0 { count++ } }
	return count
}

fn staged_find_descriptor(path string) int {
	expected := os.lstat(path) or { panic(err) }
	for fd in 0 .. 1024 {
		mut native := C.stat{}
		if C.fstat(fd, &native) == 0 && u64(native.st_dev) == expected.dev && u64(native.st_ino) == expected.inode {
			return fd
		}
	}
	panic('missing staged config descriptor')
}

fn test_staged_fds_are_cloexec_and_close_after_publish_restore_and_compensation() {
	root := os.join_path(os.real_path(os.temp_dir()), 'staged-fd-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	for restoring in [false, true] {
		for fail in [false, true] {
			target := os.join_path(root, 'source-${restoring}-${fail}.toml')
			os.write_file(target, 'original') or { panic(err) }
			descriptors := chan int{cap: 1}
			before := staged_open_fd_count()
			commit := fn [descriptors] (source string, target string) ! {
				fd := staged_find_descriptor(source)
				descriptors <- fd
				assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
				rename_config_file(source, target)!
			}
			postcheck := fn [fail] () ! { if fail { return error('postcheck_failed') } }
			mut failure := ''
			if restoring {
				store.restore_config_files_with([ConfigFileRestore{ path: target, original_exists: true, original: 'original', value: 'next' }], fn () ! {}, postcheck, commit) or { failure = err.msg() }
			} else {
				store.publish_config_files_with([ConfigFileChange{ path: target, original: 'original', value: 'next' }], fn () ! {}, postcheck, commit) or { failure = err.msg() }
			}
			fd := <-descriptors
			assert C.fcntl(fd, C.F_GETFD) == -1
			assert staged_open_fd_count() == before
			assert failure == if fail { 'postcheck_failed' } else { '' }
			assert os.read_file(target) or { panic(err) } == if fail { 'original' } else { 'next' }
		}
	}
}
