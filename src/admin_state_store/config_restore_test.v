module admin_state_store

import os
import rand

fn restore_ok() ! {}
fn restore_bad() ! { return error('postcheck failed') }
fn restore_fail_root(source string, target string) ! {
	if target.ends_with('root.toml') { return error('injected failure') }
	rename_config_file(source, target)!
}

fn test_restore_stages_full_set_recreates_missing_and_preserves_modes() ! {
	dir := os.real_path(os.temp_dir()) + '/restore-' + rand.hex(8)
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := dir + '/root.toml'
	fragment := dir + '/nested/missing.toml'
	os.write_file(root, 'pending')!
	mut store := FileStore.new(dir + '/admin')!
	changes := [ConfigFileRestore{path: fragment, value: 'effective include', mode: 0o600}, ConfigFileRestore{path: root, original_exists: true, original: 'pending', value: 'effective', mode: 0o640}]
	// Both partial commit and post-validation failure must restore the original set.
	if _ := store.restore_config_files_with(changes, restore_ok, restore_ok, restore_fail_root) { assert false }
	assert os.read_file(root)! == 'pending'
	assert !os.exists(fragment)
	assert !os.exists(dir + '/nested')
	if _ := store.restore_config_files(changes, restore_ok, restore_bad) { assert false }
	assert os.read_file(root)! == 'pending'
	assert !os.exists(fragment)
	store.restore_config_files(changes, restore_ok, restore_ok)!
	assert os.read_file(root)! == 'effective'
	assert os.read_file(fragment)! == 'effective include'
	assert int(os.stat(root)!.mode & 0o777) == 0o640
	assert int(os.stat(fragment)!.mode & 0o777) == 0o600
	assert os.ls(dir)!.all(!it.ends_with('.config.tmp'))
}

fn test_restore_conflict_and_symlink_write_nothing() ! {
	dir := os.real_path(os.temp_dir()) + '/restore-guard-' + rand.hex(8)
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := dir + '/root.toml'
	os.write_file(root, 'external edit')!
	mut store := FileStore.new(dir + '/admin')!
	if _ := store.restore_config_files([ConfigFileRestore{path: root, original_exists: true, original: 'pending', value: 'effective'}], restore_ok, restore_ok) { assert false }
	assert os.read_file(root)! == 'external edit'
	os.symlink(root, dir + '/link.toml')!
	if _ := store.restore_config_files([ConfigFileRestore{path: dir + '/link.toml', original_exists: true, original: 'external edit', value: 'effective'}], restore_ok, restore_ok) { assert false }
	assert os.read_file(root)! == 'external edit'
}
