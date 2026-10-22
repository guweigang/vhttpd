module admin_state_store

import os

fn config_check_bad() ! { return error('invalid_project') }

fn config_fail_second_commit(source string, target string) ! {
	if os.file_name(target) == 'b.toml' { return error('injected_commit_failure') }
	rename_config_file(source, target)!
}

fn test_config_changeset_publishes_every_file_and_preserves_permissions() {
	root, files := changeset_test_files()
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'admin')) or { panic(err) }
	store.publish_config_files(files, config_check_ok, config_check_ok) or { panic(err) }
	assert os.read_file(files[0].path) or { panic(err) } == 'new-a'
	assert os.read_file(files[1].path) or { panic(err) } == 'new-b'
	assert int(os.stat(files[0].path) or { panic(err) }.mode & 0o777) == 0o600
}

fn test_config_changeset_rejects_conflicts_before_writing_any_file() {
	root, files := changeset_test_files()
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'admin')) or { panic(err) }
	os.write_file(files[1].path, 'external-edit') or { panic(err) }
	if _ := store.publish_config_files(files, config_check_ok, config_check_ok) {
		assert false
	}
	assert os.read_file(files[0].path) or { panic(err) } == 'old-a'
	assert os.read_file(files[1].path) or { panic(err) } == 'external-edit'
}

fn test_config_changeset_rolls_back_on_partial_commit_or_postcheck_failure() {
	root, files := changeset_test_files()
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'admin')) or { panic(err) }
	if _ := store.publish_config_files_with(files, config_check_ok, config_check_ok, config_fail_second_commit) {
		assert false
	}
	assert os.read_file(files[0].path) or { panic(err) } == 'old-a'
	assert os.read_file(files[1].path) or { panic(err) } == 'old-b'
	if _ := store.publish_config_files(files, config_check_ok, config_check_bad) {
		assert false
	}
	assert os.read_file(files[0].path) or { panic(err) } == 'old-a'
	assert os.read_file(files[1].path) or { panic(err) } == 'old-b'
	assert int(os.stat(files[0].path) or { panic(err) }.mode & 0o777) == 0o600
	assert (os.ls(root) or { panic(err) }).filter(it.ends_with('.tmp')).len == 0
}

fn test_config_changeset_preflight_failure_leaves_both_sources_untouched() {
	root, files := changeset_test_files()
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'admin')) or { panic(err) }
	if _ := store.publish_config_files(files, config_check_bad, config_check_ok) {
		assert false
	}
	assert os.read_file(files[0].path) or { panic(err) } == 'old-a'
	assert os.read_file(files[1].path) or { panic(err) } == 'old-b'
}
