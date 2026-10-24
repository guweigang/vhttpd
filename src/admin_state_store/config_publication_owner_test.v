module admin_state_store

import os

fn test_publication_rechecks_source_type_after_preflight() ! {
	root, files := changeset_test_files()
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'admin'))!
	path := files[0].path
	target := os.join_path(root, 'external.toml')
	os.write_file(target, files[0].original)!
	preflight := fn [path, target] () ! {
		os.rm(path)!
		os.symlink(target, path)!
	}
	if _ := store.publish_config_files(files, preflight, config_check_ok) {
		assert false, 'a replaced symlink must not be published over'
	}
	assert os.is_link(path)
	assert os.read_file(target)! == files[0].original
	assert os.read_file(files[1].path)! == files[1].original
	assert os.ls(root)!.filter(it.ends_with('.config.tmp')).len == 0
}

fn test_publication_rollback_preserves_replacement_symlink_and_restores_other_files() ! {
	root, files := changeset_test_files()
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(os.join_path(root, 'admin'))!
	path := files[0].path
	target := os.join_path(root, 'external.toml')
	os.write_file(target, files[0].value)!
	postcheck := fn [path, target] () ! {
		os.rm(path)!
		os.symlink(target, path)!
		return error('injected_postcheck_failure')
	}
	mut failure := ''
	store.publish_config_files(files, config_check_ok, postcheck) or { failure = err.msg() }
	assert failure.starts_with('config_changeset_rollback_failed:')
	assert os.is_link(path)
	assert os.read_file(target)! == files[0].value
	assert os.read_file(files[1].path)! == files[1].original
	assert os.ls(root)!.filter(it.ends_with('.config.tmp')).len == 0
}
