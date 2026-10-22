module main

import config
import os

fn C.link(&char, &char) i32

fn draft_owner_app(root string) !App {
	os.mkdir_all(root + '/config')!
	path := root + '/config/vhttpd.toml'
	os.write_file(path, admin_state_runtime_plan_text('old'))!
	return App{
		DataPlaneRuntime: DataPlaneRuntime{ plan: config.load_runtime_plan_file(path)! }
		control_plane:    ControlPlaneRuntime{ event_log: root + '/events.ndjson' }
	}
}

fn test_source_draft_publication_preserves_hardlink_peer_and_permissions() ! {
	root := admin_state_runtime_test_root('draft-hardlink-owner')
	defer { os.rmdir_all(root) or {} }
	mut app := draft_owner_app(root)!
	path := root + '/entry.ts'
	peer := root + '/peer.ts'
	os.write_file(path, 'original')!
	os.chmod(path, 0o640)!
	assert C.link(&char(path.str), &char(peer.str)) == 0
	app.admin_state_put_draft('source', 'published')!
	result := app.admin_state_publish_source_draft('source', path)
	assert result.ok, result.error
	assert os.read_file(path)! == 'published'
	assert os.read_file(peer)! == 'original'
	assert int(os.stat(path)!.mode & 0o777) == 0o640
}

fn test_failed_include_draft_publication_leaves_no_new_directory_tree() ! {
	root := admin_state_runtime_test_root('draft-directory-owner')
	defer { os.rmdir_all(root) or {} }
	mut app := draft_owner_app(root)!
	path := root + '/config/vhttpd.toml'
	before := os.read_file(path)!
	// Valid alone, but duplicates the existing listener/adapter/pipeline IDs.
	app.admin_state_put_draft('conflict', admin_state_runtime_plan_text('duplicate'))!
	result := app.admin_state_publish_draft('conflict', '../new/nested/fragment.toml')
	assert !result.ok
	assert os.read_file(path)! == before
	assert !os.exists(root + '/new')
}

fn test_source_draft_publication_preserves_symlink_target() ! {
	root := admin_state_runtime_test_root('draft-symlink-owner')
	defer { os.rmdir_all(root) or {} }
	mut app := draft_owner_app(root)!
	path := root + '/entry.ts'
	target := root + '/target.ts'
	os.write_file(target, 'keep')!
	os.symlink(os.abs_path(target), path)!
	app.admin_state_put_draft('source', 'published')!
	result := app.admin_state_publish_source_draft('source', path)
	assert !result.ok
	assert os.is_link(path)
	assert os.read_file(target)! == 'keep'
}
