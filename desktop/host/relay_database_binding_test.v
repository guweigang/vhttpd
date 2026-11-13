module host

import config
import os

fn test_database_binding_draft_preserves_names_and_includes_without_writing_sources() ! {
	dir := os.join_path(os.temp_dir(), 'relay-db-desktop-' + os.getpid().str())
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := os.join_path(dir, 'vhttpd.toml')
	db := os.join_path(dir, 'database.toml')
	os.write_file(root, 'version=2\ninclude=["database.toml"]\n')!
	os.write_file(db, '[resources.db.wechat]\nkind="mysql"\nhost="127.0.0.1"\npassword="fixture-secret"\ndatabase="fixture"\n')!
	original := os.read_file(db)!
	r := SharedRelay{relay_id: 'database', id: new_shared_relay_id()!, name: 'test', url: 'ws://127.0.0.1:23456/relay', token: 'fixture'}
	selection := RelayDatabaseSelection{local_resource: 'wechat', remote_resource: 'db/production', route: 'resource/database'}
	bundle := relay_database_changeset(root, r, selection)!
	assert bundle.files.len == 2
	mut overrides := map[string]string{}
	for file in bundle.files { overrides[file.path] = file.value }
	plan := config.load_runtime_plan_with_overrides(root, overrides)!
	assert plan.resources['db/wechat'].options.strings['relay'] == 'relay:database'
	assert plan.resources['db/wechat'].options.strings['remote_resource'] == 'db/production'
	assert plan.resources['db/wechat'].options.strings['password'] == ''
	assert plan.relays['database'].options.bools['autostart']
	assert os.read_file(db)! == original
	assert !overrides[db].contains('fixture-secret')
	relay_database_changeset(root, SharedRelay{...r, token: ''}, selection) or { return }
	assert false, 'Unauthenticated database connection accepted'
}
