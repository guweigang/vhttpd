module host

import crypto.sha256
import json2 as json
import net
import os
import time

fn development_fixture() !(string, &Manager, DevelopmentState) {
	root := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-development-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	project := create_project(CreateProjectOptions{ name: 'app', parent_dir: root, template: 'vjsx-http' })!
	mut manager := new_manager()
	manager.select_project(project)!
	mut state := DevelopmentState{}
	state.remember_secrets(manager)
	return root, manager, state
}

fn development_prepare_id(mut state DevelopmentState, manager &Manager, edits []DevelopmentEdit) !string {
	value := json.decode[DevelopmentPrepared](state.prepare(manager, edits)!)!
	return value.id
}

fn test_development_updates_source_config_and_new_include_then_restores() ! {
	root, mut m, mut d := development_fixture()!
	defer { os.rmdir_all(root) or {} }
	original := os.read_file(m.project.config_path)!
	original_token := m.info.config_token
	source := os.read_file(m.project.workdir + '/main.mjs')!
	id := development_prepare_id(mut d, m, [
		DevelopmentEdit{ path: 'main.mjs', revision: sha256.hexhash(source), content: 'export default c => c.json({changed:true},200)' },
		DevelopmentEdit{ path: 'extra.toml', content: '# included application configuration\n' },
		DevelopmentEdit{ path: 'vhttpd.toml', revision: sha256.hexhash(original), content: d.mask(original.replace('version = 2', 'version = 2\ninclude = ["extra.toml"]')) },
	])!
	p := d.previews[id]
	development_validate(m, p)!
	development_apply(mut m, p)!
	assert m.phase == .stopped
	assert os.read_file(m.project.workdir + '/main.mjs')! != source
	assert inspect_project(m.project)!.config_token == original_token
	development_restore(mut m, p)!
	assert os.read_file(m.project.config_path)! == original
	assert os.read_file(m.project.workdir + '/main.mjs')! == source
	assert !os.exists(m.project.workdir + '/extra.toml')
}

fn test_development_rejects_stale_preview_invalid_config_and_external_process() ! {
	root, mut m, mut d := development_fixture()!
	defer { os.rmdir_all(root) or {} }
	source_path := m.project.workdir + '/main.mjs'
	source := os.read_file(source_path)!
	id := development_prepare_id(mut d, m, [DevelopmentEdit{ path: 'main.mjs', revision: sha256.hexhash(source), content: 'export default c => c.json({ok:true})' }])!
	os.write_file(source_path, source + '\n// external')!
	mut rejected := false
	development_apply(mut m, d.previews[id]) or { rejected = err.msg().contains('workspace_changed') }
	assert rejected
	assert os.read_file(source_path)! == source + '\n// external'
	os.write_file(source_path, source)!
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${m.info.admin_port}')!
	rejected = false
	development_apply(mut m, d.previews[id]) or { rejected = err.msg().contains('runtime_admin_port_in_use') }
	assert rejected
	listener.close()!
	config_text := os.read_file(m.project.config_path)!
	bad := development_prepare_id(mut d, m, [DevelopmentEdit{ path: 'vhttpd.toml', revision: sha256.hexhash(config_text), content: 'not valid toml = [' }])!
	rejected = false
	development_apply(mut m, d.previews[bad]) or { rejected = true }
	assert rejected && os.read_file(m.project.config_path)! == config_text
}

fn test_development_secret_roundtrip_paths_and_restore_conflict() ! {
	root, mut m, mut d := development_fixture()!
	defer { os.rmdir_all(root) or {} }
	secret := m.info.config_token
	call := DevelopmentCall{ tool: 'files_read', arguments: '{"path":"vhttpd.toml"}', root: root }
	result := d.execute(mut m, call)
	assert !result.error && !result.value.contains(secret)
	assert result.value.contains('<vhttpd-secret-')
	for path in ['../vhttpd.toml', '.env', 'credentials.json', 'a/../../main.mjs', '/tmp/main.mjs',
		'a\\main.mjs'] {
		mut rejected := false
		development_target(m.project.workdir, path) or { rejected = true }
		assert rejected, path
	}
	outside := root + '/outside.mjs'
	os.write_file(outside, 'outside')!
	os.symlink(outside, m.project.workdir + '/linked.mjs')!
	mut rejected := false
	development_target(m.project.workdir, 'linked.mjs') or { rejected = true }
	assert rejected
	source := os.read_file(m.project.workdir + '/main.mjs')!
	id := development_prepare_id(mut d, m, [DevelopmentEdit{ path: 'main.mjs', revision: sha256.hexhash(source), content: 'export default c => c.json({changed:true})' }])!
	development_apply(mut m, d.previews[id])!
	os.write_file(m.project.workdir + '/main.mjs', 'external edit')!
	rejected = false
	development_restore(mut m, d.previews[id]) or { rejected = true }
	assert rejected && os.read_file(m.project.workdir + '/main.mjs')! == 'external edit'
}

fn test_development_disabled_requests_never_mutate() ! {
	root, mut m, mut d := development_fixture()!
	defer { os.rmdir_all(root) or {} }
	mut access := &DevelopmentAccess{}
	access.revoke()
	result := d.execute(mut m, DevelopmentCall{ tool: 'project_create', arguments: '{"name":"forbidden","template":"vjsx-http"}', root: root, access: access })
	assert result.error
	assert !os.exists(root + '/forbidden')
}

fn test_development_rejects_external_includes_and_management_changes() ! {
	root, mut m, mut d := development_fixture()!
	defer { os.rmdir_all(root) or {} }
	text := os.read_file(m.project.config_path)!
	os.write_file(root + '/outside.toml', '# outside selected project')!
	for replacement in [
		text.replace('version = 2', 'version = 2\ninclude=["../outside.toml"]'),
		text.replace(m.info.config_token, 'replacement-credential'),
	] {
		id := development_prepare_id(mut d, m, [DevelopmentEdit{ path: 'vhttpd.toml', revision: sha256.hexhash(text), content: replacement }])!
		mut rejected := false
		development_validate(m, d.previews[id]) or { rejected = true }
		assert rejected
		assert os.read_file(m.project.config_path)! == text
	}
}

fn test_development_real_runtime_request_update_failure_restore_and_retry() ! {
	binary := os.getenv('VHTTPD_COMPONENT_TEST_BIN')
	if binary == '' { return }
	root, mut m, mut d := development_fixture()!
	defer {
		m.shutdown()
		os.rmdir_all(root) or {}
	}
	m.start_timeout = 20000
	m.start(m.project, binary)!
	m.installation_ready()!
	assert development_request(m, DevelopmentArgs{ listener: 'web', path: '/' })!.contains('200')
	schema := d.execute(mut m, DevelopmentCall{ tool: 'schema_get', arguments: '{}', root: root })
	assert !schema.error && schema.value.contains('vjsx') && schema.value.contains('live_admin'), schema.value
	mut rejected := false
	development_request(m, DevelopmentArgs{ listener: 'admin', path: '/admin/workbench/instance' }) or { rejected = true }
	assert rejected
	source := os.read_file(m.project.workdir + '/main.mjs')!
	id := development_prepare_id(mut d, m, [DevelopmentEdit{ path: 'main.mjs', revision: sha256.hexhash(source), content: 'export default function (' }])!
	rejected = false
	development_apply(mut m, d.previews[id]) or { rejected = err.msg().contains('stop_runtime') }
	assert rejected
	m.installation_stop()!
	development_apply(mut m, d.previews[id])!
	m.start(m.project, binary)!
	m.installation_ready() or { rejected = true }
	assert m.phase == .failed
	m.installation_stop()!
	development_restore(mut m, d.previews[id])!
	m.start(m.project, binary)!
	m.installation_ready()!
	assert development_request(m, DevelopmentArgs{ listener: 'web', path: '/' })!.contains('200')
}

fn test_development_schema_uses_selected_package_while_stopped() ! {
	binary := os.getenv('VHTTPD_SCHEMA_TEST_BIN')
	if binary == '' { return }
	root, mut m, mut d := development_fixture()!
	defer { os.rmdir_all(root) or {} }
	for arguments in ['{}', '{"domain":"engines"}', '{"domain":"engines","kind":"vjsx"}'] {
		reply := d.execute(mut m, DevelopmentCall{ tool: 'schema_get', arguments: arguments, root: root, binary: binary })
		assert !reply.error, reply.value
		assert reply.value.contains('runtime_package') && reply.value.contains('vjsx'), reply.value
		assert reply.value.contains('runtime_version'), reply.value
	}
	for args in ['{"domain":"missing"}', '{"domain":"engines","kind":"missing"}'] {
		reply := d.execute(mut m, DevelopmentCall{ tool: 'schema_get', arguments: args, root: root, binary: binary })
		assert reply.error && reply.value.contains('_not_found'), reply.value
	}
	missing := d.execute(mut m, DevelopmentCall{ tool: 'schema_get', arguments: '{}', root: root })
	assert missing.error && missing.value.contains('runtime_schema_unavailable'), missing.value
	assert m.phase == .stopped
}
