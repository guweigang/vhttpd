module admin_state_store

import os
import rand

fn staged_owner_root() string {
	root := os.join_path(os.real_path(os.temp_dir()), 'config-stage-owner-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn staged_owner_replace(root string, name string) !string {
	names := os.ls(root)!
	matches := names.filter(it.starts_with('.' + name + '.') && it.ends_with('.config.tmp'))
	if matches.len != 1 { return error('expected_one_staged_file') }
	source := os.join_path(root, matches[0])
	os.rename(source, os.join_path(root, 'moved-stage'))!
	os.write_file(source, 'other owner')!
	return source
}

fn test_publication_rejects_replaced_later_stage_and_compensates_prior_commit() {
	root := staged_owner_root()
	defer { os.rmdir_all(root) or {} }
	first := os.join_path(root, 'first.toml')
	second := os.join_path(root, 'second.toml')
	os.write_file(first, 'original-first') or { panic(err) }
	os.write_file(second, 'original-second') or { panic(err) }
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	mut failed := false
	store.publish_config_files_with([
		ConfigFileChange{ path: first, original: 'original-first', value: 'next-first' },
		ConfigFileChange{ path: second, original: 'original-second', value: 'next-second' },
	], fn () ! {}, fn () ! {}, fn [root, first] (source string, target string) ! {
		if target == first { staged_owner_replace(root, 'second.toml')! }
		rename_config_file(source, target)!
	}) or { failed = true }
	assert failed
	assert os.read_file(first) or { panic(err) } == 'original-first'
	assert os.read_file(second) or { panic(err) } == 'original-second'
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.ends_with('.config.tmp'))
	assert replacements.len == 1
	assert os.read_file(os.join_path(root, replacements[0])) or { panic(err) } == 'other owner'
}

fn test_failed_commit_preserves_replacement_staging_entry() {
	root := staged_owner_root()
	defer { os.rmdir_all(root) or {} }
	target := os.join_path(root, 'first.toml')
	os.write_file(target, 'original') or { panic(err) }
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	mut failure := ''
	store.publish_config_files_with([ConfigFileChange{ path: target, original: 'original', value: 'next' }], fn () ! {}, fn () ! {}, fn [root] (_ string, _ string) ! {
		staged_owner_replace(root, 'first.toml')!
		return error('commit_failed')
	}) or { failure = err.msg() }
	assert failure == 'commit_failed'
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.ends_with('.config.tmp'))
	assert replacements.len == 1
	assert os.read_file(os.join_path(root, replacements[0])) or { panic(err) } == 'other owner'
	assert os.read_file(target) or { panic(err) } == 'original'
}

fn test_restore_rejects_replaced_stage_and_compensates_created_file() {
	root := staged_owner_root()
	defer { os.rmdir_all(root) or {} }
	first := os.join_path(root, 'first.toml')
	second := os.join_path(root, 'second.toml')
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	mut failed := false
	store.restore_config_files_with([
		ConfigFileRestore{ path: first, value: 'next-first' },
		ConfigFileRestore{ path: second, value: 'next-second' },
	], fn () ! {}, fn () ! {}, fn [root, first] (source string, target string) ! {
		if target == first { staged_owner_replace(root, 'second.toml')! }
		rename_config_file(source, target)!
	}) or { failed = true }
	assert failed
	assert !os.exists(first) && !os.exists(second)
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.ends_with('.config.tmp'))
	assert replacements.len == 1
	assert os.read_file(os.join_path(root, replacements[0])) or { panic(err) } == 'other owner'
}

fn test_publication_rejects_staging_symlink_to_the_moved_owned_inode() {
	root := staged_owner_root()
	defer { os.rmdir_all(root) or {} }
	first := os.join_path(root, 'first.toml')
	second := os.join_path(root, 'second.toml')
	os.write_file(first, 'first') or { panic(err) }
	os.write_file(second, 'second') or { panic(err) }
	mut store := FileStore.new(os.join_path(root, 'state')) or { panic(err) }
	mut failed := false
	store.publish_config_files_with([
		ConfigFileChange{ path: first, original: 'first', value: 'next-first' },
		ConfigFileChange{ path: second, original: 'second', value: 'next-second' },
	], fn () ! {}, fn () ! {}, fn [root, first] (source string, target string) ! {
		if target == first {
			replacement := staged_owner_replace(root, 'second.toml')!
			os.rm(replacement)!
			os.symlink(os.join_path(root, 'moved-stage'), replacement)!
		}
		rename_config_file(source, target)!
	}) or { failed = true }
	assert failed
	assert !os.is_link(second)
	assert os.read_file(first) or { panic(err) } == 'first'
	assert os.read_file(second) or { panic(err) } == 'second'
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.ends_with('.config.tmp'))
	assert replacements.len == 1
	assert os.is_link(os.join_path(root, replacements[0]))
}
