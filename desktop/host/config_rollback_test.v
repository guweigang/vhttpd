module host

import os
import rand

fn test_rollback_preview_redacts_and_guards_cross_include_restore() ! {
	dir := os.real_path(os.temp_dir()) + '/host-rollback-' + rand.hex(8)
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := dir + '/vhttpd.toml'
	relay := dir + '/relay.toml'
	routes := dir + '/routes.toml'
	root_value := 'version=2\ninclude=["relay.toml","routes.toml"]\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=19891\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n'
	relay_value := '[relays.edge]\nmode="agent"\ncarrier="websocket"\nurl="ws://127.0.0.1:1/relay"\nnode_id="before"\ntoken="old-secret"\nautostart=false\n'
	routes_value := '[[pipelines]]\nid="receive"\ningress="relay:edge"\negress="adapter:reply"\nmatch.paths=["/before"]\n'
	os.write_file(root, root_value)!
	os.write_file(relay, relay_value)!
	os.write_file(routes, routes_value)!
	os.chmod(relay, 0o600)!
	mut m := new_manager()
	m.phase = .running
	m.project = Project{config_path: root, workdir: dir}
	revisions := config_revisions(root)!
	m.record_recovery_baseline(revisions, recovery_sources(revisions)!, dir + '/admin')
	os.write_file(relay, relay_value.replace('before', 'after').replace('old-secret', 'new-secret'))!
	os.write_file(routes, routes_value.replace('/before', '/after'))!
	m.preview_config_rollback()!
	preview := m.snapshot().rollback_preview
	assert preview.files.len == 2
	assert preview.fields.any(it.field == 'options.node_id' && it.before == '"after"' && it.after == '"before"')
	assert preview.fields.any(it.field == 'match.paths' && it.before.contains('/after') && it.after.contains('/before'))
	assert !preview.str().contains('old-secret') && !preview.str().contains('new-secret')
	assert os.read_file(relay)!.contains('after')
	os.write_file(routes, routes_value + '# external edit\n')!
	if _ := m.restore_config_rollback(preview.id) { assert false }
	assert os.read_file(relay)!.contains('after')
	assert os.read_file(routes)!.contains('external edit')
	m.preview_config_rollback()!
	m.restore_config_rollback(m.snapshot().rollback_preview.id)!
	assert os.read_file(root)! == root_value
	assert os.read_file(relay)! == relay_value
	assert os.read_file(routes)! == routes_value
	assert int(os.stat(relay)!.mode & 0o777) == 0o600
	if _ := m.restore_config_rollback(preview.id) { assert false }
	// Include graph edits, missing sources and an invalid current project remain recoverable.
	os.write_file(dir + '/new.toml', '# keep me\n')!
	os.write_file(root, root_value.replace('"relay.toml","routes.toml"', '"relay.toml","new.toml"'))!
	os.rm(routes)!
	m.preview_config_rollback()!
	assert m.snapshot().rollback_preview.files.any(it.action.contains('文件保留'))
	m.restore_config_rollback(m.snapshot().rollback_preview.id)!
	assert os.read_file(routes)! == routes_value
	assert os.read_file(root)! == root_value
	assert os.read_file(dir + '/new.toml')! == '# keep me\n'
	os.write_file(root, 'invalid toml [')!
	m.preview_config_rollback()!
	assert m.snapshot().rollback_preview.message.contains('无法编译')
	m.restore_config_rollback(m.snapshot().rollback_preview.id)!
	assert os.read_file(root)! == root_value
}
