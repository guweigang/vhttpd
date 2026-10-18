module admin_state_store

import os
import rand

fn C.fcntl(int, int, ...voidptr) int

fn atomic_owner_root() string {
	root := os.join_path(os.real_path(os.temp_dir()), 'atomic-owner-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn check_atomic_replacement(fail bool, link bool) {
	root := atomic_owner_root()
	defer { os.rmdir_all(root) or {} }
	target := os.join_path(root, 'key.json')
	moved := os.join_path(root, 'moved')
	os.write_file(target, 'original') or { panic(err) }
	descriptors := chan int{cap: 1}
	replacements := chan string{cap: 1}
	mut failure := ''
	atomic_write_with(target, 'next', fn [root, moved, fail, link, descriptors, replacements] (fd int, value string) ! {
		descriptors <- fd
		assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
		write_all(fd, value)!
		names := os.ls(root)!
		temporary := names.filter(it.starts_with('.key.json.') && it.ends_with('.tmp'))
		assert temporary.len == 1
		source := os.join_path(root, temporary[0])
		rename_config_file(source, moved)!
		if link { os.symlink(moved, source)! } else { os.write_file(source, 'foreign')! }
		replacements <- source
		if fail { return error('injected_writer_failure') }
	}) or { failure = err.msg() }
	fd := <-descriptors
	source := <-replacements
	assert C.fcntl(fd, C.F_GETFD) == -1
	assert failure != ''
	if fail {
		assert failure == 'injected_writer_failure'
	}
	assert os.read_file(target) or { panic(err) } == 'original'
	assert os.exists(source)
	assert os.is_link(source) == link
	assert os.read_file(source) or { panic(err) } == if link { 'next' } else { 'foreign' }
	assert os.read_file(moved) or { panic(err) } == 'next'
}

fn test_atomic_write_rejects_foreign_temporary_file() { check_atomic_replacement(false, false) }

fn test_atomic_write_failure_preserves_foreign_temporary_file() {
	check_atomic_replacement(true, false)
}

fn test_atomic_write_rejects_symlink_to_moved_owned_inode() {
	check_atomic_replacement(false, true)
}

fn test_atomic_write_failure_preserves_symlink_to_moved_owned_inode() {
	check_atomic_replacement(true, true)
}

fn test_atomic_write_success_preserves_creation_mode_and_releases_descriptor() {
	root := atomic_owner_root()
	defer { os.rmdir_all(root) or {} }
	control := os.join_path(root, 'control')
	target := os.join_path(root, 'key.json')
	os.write_file(control, 'control') or { panic(err) }
	descriptors := chan int{cap: 1}
	atomic_write_with(target, 'next', fn [descriptors] (fd int, value string) ! {
		descriptors <- fd
		assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
		write_all(fd, value)!
	}) or { panic(err) }
	fd := <-descriptors
	assert C.fcntl(fd, C.F_GETFD) == -1
	assert os.read_file(target) or { panic(err) } == 'next'
	assert (os.stat(target) or { panic(err) }).mode & 0o777 == (os.stat(control) or { panic(err) }).mode & 0o777
	assert (os.ls(root) or { panic(err) }).len == 2
}
