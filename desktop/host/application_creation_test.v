module host

import crypto.sha256
import json2 as json
import os
import time

fn test_application_creation_install_and_scoped_switch() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'application-dev-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	old := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root + '/data', true)
	defer {
		if value := old {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		os.rmdir_all(root) or {}
	}
	project := create_project(CreateProjectOptions{ name: 'environment', parent_dir: root, template: 'environment' })!
	original := inspect_project(project)!
	mut manager := new_manager()
	manager.select_project(project)!
	for name in ['alpha', 'beta'] {
		source := create_application_source(name, 'vjsx-http', 0)!
		assert !os.read_file(source.config_path)!.contains('[control]')
		manager.preview_component(source, name)!
		manager.install_component(manager.component_preview.id, '')!
	}
	assert inspect_project(project)!.config_token == original.config_token
	assert inspect_project(project)!.admin_port == original.admin_port
	apps := development_applications(project)!
	assert apps.len == 2
	// The runtime workdir may be a repository containing unrelated large files.
	os.write_file(project.workdir + '/unrelated.json', 'x'.repeat(1024 * 1024 + 1))!
	os.write_file(project.workdir + '/apps/beta/unrelated.json', 'x'.repeat(1024 * 1024 + 1))!
	mut state := DevelopmentState{}
	access := &DevelopmentAccess{}
	selected := state.execute(mut manager, DevelopmentCall{ tool: '_select_application', arguments: '{}', project: project, application: 'alpha', access: access })
	assert !selected.error, selected.value
	generation := access.selection().generation
	read := state.execute(mut manager, DevelopmentCall{ tool: 'files_read', arguments: '{"path":"main.mjs"}', root: project.workdir, access: access, generation: generation })
	assert !read.error && read.value.contains('alpha'), read.value
	assert state.execute(mut manager, DevelopmentCall{ tool: 'files_read', arguments: '{"path":"../beta/main.mjs"}', root: project.workdir, access: access, generation: generation }).error
	content := os.read_file(project.workdir + '/apps/alpha/main.mjs')!
	args := json.encode({
		'files': [DevelopmentEdit{ path: 'main.mjs', revision: sha256.hexhash(content), content: 'export default c => c.json({edited:true},200)' }]
	})
	prepared := state.execute(mut manager, DevelopmentCall{ tool: 'changes_prepare', arguments: args, root: project.workdir, access: access, generation: generation })
	assert !prepared.error, prepared.value
	preview := json.decode[DevelopmentPrepared](prepared.value)!
	// Other applications' configuration remains part of the conflict baseline.
	beta_config := project.workdir + '/apps/beta/component.toml'
	beta_before := os.read_file(beta_config)!
	os.write_file(beta_config, beta_before + '\n# external config change\n')!
	mut rejected := false
	development_validate(manager, state.previews[preview.id]) or { rejected = err.msg().contains('workspace_changed') }
	assert rejected
	os.write_file(beta_config, beta_before)!
	apply := state.execute(mut manager, DevelopmentCall{ tool: 'changes_apply', arguments: json.encode({
		'id': preview.id
	}), root: project.workdir, access: access, generation: generation })
	assert !apply.error, apply.value
	assert os.read_file(project.workdir + '/apps/alpha/main.mjs')!.contains('edited')
	assert os.read_file(project.workdir + '/apps/beta/main.mjs')!.contains('beta')
	selected_beta := state.execute(mut manager, DevelopmentCall{ tool: '_select_application', arguments: '{}', project: project, application: 'beta', access: access })
	assert !selected_beta.error, selected_beta.value
	assert access.selection().generation > generation
	assert state.execute(mut manager, DevelopmentCall{ tool: 'changes_apply', arguments: json.encode({
		'id': preview.id
	}), root: project.workdir, access: access, generation: generation }).error
	assert state.previews.len == 0
}

fn test_component_templates_install_and_are_discoverable_without_private_files() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'application-templates-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	old := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root + '/data', true)
	defer {
		if value := old {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		os.rmdir_all(root) or {}
	}
	project := create_project(CreateProjectOptions{ name: 'environment', parent_dir: root, template: 'environment' })!
	mut manager := new_manager()
	manager.select_project(project)!
	mut state := DevelopmentState{}
	access := &DevelopmentAccess{}
	other := &DevelopmentAccess{}
	for kind in ['pipeline', 'wechat-cloud-functions', 'codexbot'] {
		result := state.execute(mut manager, DevelopmentCall{
			tool: 'application_install_prepare'
			arguments: json.encode({'name':kind,'template':kind})
			root: root
			access: access
		})
		assert !result.error, result.value
		id := json.decode[DevelopmentPrepared](result.value)!.id
		args := json.encode({'id':id})
		rejected := state.execute(mut manager, DevelopmentCall{tool:'application_install_apply',arguments:args,root:root,access:other})
		assert rejected.error
		applied := state.execute(mut manager, DevelopmentCall{tool:'application_install_apply',arguments:args,root:root,access:access})
		assert !applied.error, applied.value
	}
	apps := development_applications(project)!
	assert apps.map(it.id).sorted() == ['codexbot', 'pipeline', 'wechat-cloud-functions']
	assert !os.exists(project.workdir + '/apps/pipeline/main.mjs')
	assert os.is_file(project.workdir + '/apps/wechat-cloud-functions/lib/cloud/runtime.mjs')
	assert os.is_file(project.workdir + '/apps/codexbot/codex/ts/ContentItem.ts')
	assert !os.exists(project.workdir + '/apps/codexbot/config/bot.local.json')
}
