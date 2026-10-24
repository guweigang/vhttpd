module upload_store

import os
import rand

fn temporary_owner_root() string {
	root := os.join_path(os.temp_dir(), 'vhttpd-upload-temporary-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn replace_upload_temporary(root string, symlink bool) !string {
	names := os.ls(root)!
	name := names.filter(it.starts_with('.upload-'))[0]
	temporary := os.join_path(root, name)
	os.rename(temporary, os.join_path(root, 'moved-original'))!
	if symlink {
		os.symlink(os.join_path(root, 'victim'), temporary)!
	} else {
		os.write_file(temporary, 'other owner')!
	}
	return temporary
}

fn test_replaced_upload_temporary_is_neither_published_nor_removed() {
	root := temporary_owner_root()
	defer { os.rmdir_all(root) or {} }
	target := os.join_path(root, 'uploaded')
	mut rejected := false
	save_with(target, 'owned data', fn [root] (fd int, data string) ! {
		write_all(fd, data)!
		replace_upload_temporary(root, false)!
	}) or { rejected = true }
	assert rejected
	assert !os.exists(target)
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.starts_with('.upload-'))
	assert replacements.len == 1
	assert os.read_file(os.join_path(root, replacements[0])) or { panic(err) } == 'other owner'
	assert os.read_file(os.join_path(root, 'moved-original')) or { panic(err) } == 'owned data'
}

fn test_failed_writer_preserves_replaced_temporary_and_closes_original_fd() {
	root := temporary_owner_root()
	defer { os.rmdir_all(root) or {} }
	target := os.join_path(root, 'uploaded')
	mut rejected := false
	save_with(target, 'owned data', fn [root] (fd int, data string) ! {
		write_all(fd, data)!
		replace_upload_temporary(root, false)!
		return error_with_code('writer_failed', fd)
	}) or {
		rejected = true
		assert err.msg() == 'writer_failed'
		assert C.fcntl(err.code(), C.F_GETFD) == -1
	}
	assert rejected
	assert !os.exists(target)
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.starts_with('.upload-'))
	assert replacements.len == 1
	assert os.read_file(os.join_path(root, replacements[0])) or { panic(err) } == 'other owner'
}

fn test_upload_does_not_publish_or_remove_a_replacement_symlink() {
	root := temporary_owner_root()
	defer { os.rmdir_all(root) or {} }
	victim := os.join_path(root, 'victim')
	os.write_file(victim, 'victim') or { panic(err) }
	target := os.join_path(root, 'uploaded')
	mut rejected := false
	save_with(target, 'owned data', fn [root] (fd int, data string) ! {
		write_all(fd, data)!
		replace_upload_temporary(root, true)!
	}) or { rejected = true }
	assert rejected
	assert !os.exists(target) && !os.is_link(target)
	names := os.ls(root) or { panic(err) }
	replacements := names.filter(it.starts_with('.upload-'))
	assert replacements.len == 1
	assert os.is_link(os.join_path(root, replacements[0]))
	assert os.read_file(victim) or { panic(err) } == 'victim'
}
