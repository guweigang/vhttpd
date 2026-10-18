module executor

import os
import time

fn directory_identity_root(label string) string {
	return os.join_path(os.temp_dir(), 'vhttpd-directory-identity-${label}-${os.getpid()}-${time.sys_mono_now()}')
}

fn test_build_directory_release_preserves_replacement_directory() ! {
	root := directory_identity_root('replacement')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	mut owner := VjsxBuildDirectory.reserve(root + '/build')!
	moved := root + '/moved'
	os.rename(owner.path, moved)!
	os.mkdir(owner.path)!
	os.write_file(owner.path + '/keep', 'replacement')!
	owner.release()
	assert os.read_file(owner.path + '/keep')! == 'replacement'
	assert os.is_dir(moved)
	owner.release()
	assert os.read_file(owner.path + '/keep')! == 'replacement'
}

fn test_build_directory_release_preserves_replacement_symlink() ! {
	root := directory_identity_root('symlink')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	mut owner := VjsxBuildDirectory.reserve(root + '/build')!
	moved := root + '/moved'
	os.rename(owner.path, moved)!
	os.write_file(moved + '/keep', 'original')!
	os.symlink(moved, owner.path)!
	owner.release()
	assert os.is_link(owner.path)
	assert os.read_file(moved + '/keep')! == 'original'
}

fn test_build_directory_release_removes_owned_tree_once() ! {
	root := directory_identity_root('owned')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	mut owner := VjsxBuildDirectory.reserve(root + '/build')!
	os.mkdir(owner.path + '/nested')!
	os.write_file(owner.path + '/nested/output', 'compiled')!
	owner.release()
	assert !os.exists(owner.path)
	os.mkdir(owner.path)!
	os.write_file(owner.path + '/keep', 'next')!
	owner.release()
	assert os.read_file(owner.path + '/keep')! == 'next'
}
