module host

import app_meta
import app_bundle
import os
import time

fn test_binding_persists_only_confirmed_deployments_and_never_matches_names() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'bindings-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root + '/data', true)
	defer {
		if value := previous {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		os.rmdir_all(root) or {}
	}
	source := create_application_source('alpha', 'vjsx-http', 0)!
	meta := app_meta.read(source.workdir)!
	b := ApplicationBinding{ app_id: meta.id, installation_id: app_meta.new_id()!, source: source, server_id: 'server-one', environment_id: 'env-one', config_path: '/target/vhttpd.toml', component: 'slot-alpha', engines: ['alpha'], operation_id: 'a'.repeat(24), phase: 'pending' }
	application := RuntimeApplication{ identity:app_bundle.ApplicationIdentity{app_id:meta.id,installation_id:b.installation_id}, id: 'alpha', engines: [ApplicationItem{ id: 'alpha' }] }
	record_application_binding(b)!
	assert binding_for_application('server-one', '/target/vhttpd.toml', application)!.installation_id == ''
	complete_application_binding(b.operation_id, true)!
	assert binding_for_application('server-one', '/target/vhttpd.toml', application)!.installation_id == b.installation_id
	assert binding_for_application('server-two', '/target/vhttpd.toml', application)!.installation_id == ''
	assert binding_for_application('server-one', '/another/vhttpd.toml', application)!.installation_id == ''
	assert validate_binding_source(b)!.workdir == source.workdir
	// Failed update preserves last successfully deployed source relation.
	pending := ApplicationBinding{ ...b, operation_id: 'b'.repeat(24), phase: 'pending', version: '2.0.0' }
	record_application_binding(pending)!
	complete_application_binding(pending.operation_id, false)!
	active := binding_for_application('server-one', '/target/vhttpd.toml', application)!
	assert active.version == ''
	assert active.operation_id == b.operation_id
	other := create_application_source('alpha', 'vjsx-http', 0)!
	different := RuntimeApplication{ ...application, identity: app_bundle.ApplicationIdentity{ app_id: app_meta.read(other.workdir)!.id, installation_id: b.installation_id } }
	assert binding_for_application('server-one', '/target/vhttpd.toml', different)!.installation_id == ''
	mut rejected := false
	validate_binding_source(ApplicationBinding{ ...b, source: other }) or { rejected = true }
	assert rejected
	// Source location can be explicitly re-associated after a move using the
	// portable identity received from the runtime, without naming heuristics.
	moved := root + '/moved'
	os.mv(source.workdir, moved)!
	project := project_from_file(moved + '/component.toml', moved)!
	identity := app_bundle.ApplicationIdentity{ app_id: meta.id, installation_id: b.installation_id, component: b.component, entry: 'component.toml', version: '0.1.0' }
	associate_application_source(b.server_id, b.environment_id, b.config_path, RuntimeApplication{ ...application, identity: identity }, project)!
	assert binding_for_application(b.server_id, b.config_path, application)!.source.workdir == moved
	environment := create_project(CreateProjectOptions{ name: 'local-env', parent_dir: root, template: 'environment' })!
	mut manager := new_manager()
	manager.select_project(environment)!
	manager.preview_component(project, 'local-copy')!
	manager.install_component(manager.component_preview.id, '')!
	targets := takeover_application_targets(environment.config_path)!
	assert project_uses_application_meta(environment.config_path)
 assert targets.len == 1
 assert targets[0].key() == b.installation_id+'/alpha'
	assert targets[0].binding.installation_id == b.installation_id
	assert targets[0].local_engine == 'alpha'
	// A source whose name matches but UUID differs cannot acquire this target.
	other_env := create_project(CreateProjectOptions{name:'other-env',parent_dir:root,template:'environment'})!
 manager.select_project(other_env)!
 manager.preview_component(other,'same-name')!
 manager.install_component(manager.component_preview.id,'')!
 assert project_uses_application_meta(other_env.config_path)
 assert takeover_application_targets(other_env.config_path)!.len == 0
}
