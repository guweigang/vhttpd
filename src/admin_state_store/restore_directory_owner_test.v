module admin_state_store

import os
import rand

fn restore_directory_root() string {
	root := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-restore-dir-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_failed_restore_preserves_replacement_parent_directories() {
	root := restore_directory_root()
	defer { os.rmdir_all(root) or {} }
	parent := os.join_path(root, 'created')
	moved := os.join_path(root, 'moved')
	leaf := os.join_path(parent, 'nested')
	target := os.join_path(leaf, 'source.toml')
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	mut failure := ''
	store.restore_config_files_with([ConfigFileRestore{ path: target, value: 'candidate' }], fn () ! {}, fn () ! {}, fn [parent, moved, leaf] (_ string, _ string) ! {
		os.rename(parent, moved)!
		os.mkdir_all(leaf)!
		return error('commit_failed')
	}) or { failure = err.msg() }
	assert failure == 'commit_failed'
	assert os.is_dir(parent)
	assert os.is_dir(leaf)
	assert !os.exists(target)
	assert (os.ls(leaf) or { panic(err) }).len == 0
	// The moved staging tree has a different pathname and is left there.
	assert os.is_dir(os.join_path(moved, 'nested'))
}
