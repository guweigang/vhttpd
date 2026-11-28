module host

import json2
import os
import rand

fn history_fixture() !(string, Project, string, string) {
	dir := os.real_path(os.temp_dir()) + '/history-' + rand.hex(8)
	os.mkdir_all(dir)!
	root := dir + '/vhttpd.toml'
	os.write_file(root, 'version=2\ninclude=["relay.toml","routes.toml"]\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=19891\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n')!
	relay := '[relays.edge]\nmode="agent"\ncarrier="websocket"\nurl="ws://127.0.0.1:1/relay"\nnode_id="first"\ntoken="history-secret-first"\nautostart=false\n'
	routes := '[[pipelines]]\nid="receive"\ningress="relay:edge"\negress="adapter:reply"\nmatch.paths=["/first"]\n'
	os.write_file(dir + '/relay.toml', relay)!
	os.write_file(dir + '/routes.toml', routes)!
	return dir, Project{config_path: root, workdir: dir}, relay, routes
}

fn confirm_history_fixture(mut m Manager) ! {
	revisions := config_revisions(m.project.config_path)!
	m.record_recovery_baseline(revisions, recovery_sources(revisions)!, m.project.workdir + '/admin')
}

fn test_local_history_reopens_compares_redacted_versions_and_restores_selected_include_set() ! {
	dir, project, relay, routes := history_fixture()!
	defer { os.rmdir_all(dir) or {} }
	mut m := new_persistent_manager_at(dir + '/history')
	m.select_project(project)!
	confirm_history_fixture(mut m)!
	first := m.recovery_id
	path := m.recovery_path()
	original := os.read_file(path)!
	assert original.contains('history-secret-first') // Local files intentionally use plain JSON, not encryption.
	assert int(os.stat(path)!.mode & 0o777) == 0o600
	assert int(os.stat(dir + '/history')!.mode & 0o777) == 0o700
	confirm_history_fixture(mut m)!
	assert os.read_file(path)! == original
	assert m.recovery_history.len == 1
	os.write_file(dir + '/relay.toml', relay.replace('first', 'second'))!
	os.write_file(dir + '/routes.toml', routes.replace('/first', '/second'))!
	confirm_history_fixture(mut m)!
	second := m.recovery_id
	assert first != second
	assert m.recovery_history.len == 2
	mut reopened := new_persistent_manager_at(dir + '/history')
	reopened.select_project(project)!
	assert reopened.snapshot().recovery_history.len == 2
	assert reopened.snapshot().recovery_history[0].number == 2
	assert reopened.recovery_id == second
	reopened.compare_history_versions(first, second)!
	comparison := reopened.snapshot().history_comparison
	assert comparison.files.len == 2
	assert comparison.fields.any(it.field == 'options.node_id' && it.before == '"first"' && it.after == '"second"')
	assert comparison.fields.any(it.field == 'match.paths' && it.before.contains('/first') && it.after.contains('/second'))
	assert comparison.fields.any(it.field == 'options.token' && it.redacted && it.before == '[已脱敏]' && it.after == '[已脱敏]')
	assert !reopened.snapshot().str().contains('history-secret')
	assert os.read_file(dir + '/relay.toml')! == relay.replace('first', 'second')
	reopened.preview_history_rollback(first)!
	preview := reopened.snapshot().rollback_preview
	assert preview.version_id == first
	assert preview.version_label == '版本 1'
	assert preview.files.len == 2
	// Stale previews may not overwrite external edits, even for a selected historical target.
	os.write_file(dir + '/routes.toml', routes + '# external\n')!
	if _ := reopened.restore_config_rollback(preview.id) { assert false }
	assert os.read_file(dir + '/relay.toml')!.contains('second')
	reopened.preview_history_rollback(first)!
	reopened.restore_config_rollback(reopened.snapshot().rollback_preview.id)!
	assert os.read_file(dir + '/relay.toml')! == relay
	assert os.read_file(dir + '/routes.toml')! == routes
	assert reopened.snapshot().config_status.state != .effective
	assert reopened.recovery_history.len == 2 // An offline restore isn't a confirmed deployment.
	confirm_history_fixture(mut reopened)!
	assert reopened.recovery_history.len == 3
	assert reopened.recovery_id != first && reopened.recovery_id != second
	assert reopened.recovery_history.last().number == 3
	// Missing old include files remain recoverable across sessions.
	os.rm(dir + '/relay.toml')!
	mut missing := new_persistent_manager_at(dir + '/history')
	missing.select_project(project)!
	missing.preview_history_rollback(second)!
	missing.restore_config_rollback(missing.snapshot().rollback_preview.id)!
	assert os.read_file(dir + '/relay.toml')! == relay.replace('first', 'second')
	if _ := missing.preview_history_rollback('not-a-version') { assert false }
	assert !missing.snapshot().rollback_preview.available
}

fn test_history_retention_conflicting_writer_and_corruption_preserve_existing_data() ! {
	dir, project, relay, _ := history_fixture()!
	defer { os.rmdir_all(dir) or {} }
	mut m := new_persistent_manager_at(dir + '/history')
	m.select_project(project)!
	confirm_history_fixture(mut m)!
	first := m.recovery_id
	mut stale := new_persistent_manager_at(dir + '/history')
	stale.select_project(project)!
	for i in 2 .. 23 {
		os.write_file(dir + '/relay.toml', relay.replace('first', 'revision-${i}'))!
		confirm_history_fixture(mut m)!
	}
	assert m.recovery_history.len == 20
	assert m.recovery_history[0].number == 3
	assert m.recovery_history.last().number == 22
	assert !m.recovery_history.any(it.id == first)
	bytes := os.read_file(m.recovery_path())!
	confirm_history_fixture(mut stale)!
	assert !stale.recovery_saved
	assert stale.recovery_notice != ''
	assert os.read_file(m.recovery_path())! == bytes
	mut reopened := new_persistent_manager_at(dir + '/history')
	reopened.select_project(project)!
	assert reopened.recovery_history.len == 20
	// Corrupt source contents without updating the revision checksum.
	archive := json2.decode[RecoveryArchive](bytes)!
	version := archive.versions.last()
	mut sources := version.sources.clone()
	sources[0] = RecoverySource{...sources[0], value: 'corrupted'}
	os.write_file(m.recovery_path(), json2.encode(RecoveryArchive{versions: [RecoveryVersion{...version, sources: sources}]}))!
	mut broken := new_persistent_manager_at(dir + '/history')
	broken.select_project(project)!
	assert !broken.recovery_confirmed
	assert broken.recovery_notice != ''
	corrupted := os.read_file(m.recovery_path())!
	confirm_history_fixture(mut broken)!
	assert !broken.recovery_saved
	assert os.read_file(m.recovery_path())! == corrupted
	// Copying a local archive to another project still fails identity checks.
	other := Project{config_path: project.config_path, workdir: dir + '/other'}
	mut foreign := new_persistent_manager_at(dir + '/history')
	foreign.project = other
	os.write_file(foreign.recovery_path(), bytes)!
	if _ := foreign.load_recovery_version() { assert false }
	assert !foreign.recovery_confirmed
}
