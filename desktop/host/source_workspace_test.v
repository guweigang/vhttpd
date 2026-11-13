module host

import crypto.sha256
import json2 as json
import os
import time

fn source_test_call(mut d DevelopmentState, mut m Manager, access &DevelopmentAccess, tool string, args string) !json.Any {
	call := DevelopmentCall{ tool: tool, arguments: args, access: access, generation: access.selection().generation, root: access.selection().project.workdir, binary: access.selection().binary }
	result := d.execute(mut m, call)
	if result.error { return error(result.value) }
	return json.decode[json.Any](result.value)!
}

fn test_source_binding_initializes_existing_empty_directory_and_recovers_without_install() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'source-test-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	os.mkdir(root + '/empty')!
	mut m := new_manager()
	mut d := DevelopmentState{}
	access := &DevelopmentAccess{}
	opened := d.open_source_workspace(mut m, DevelopmentCall{ tool: '_open_source_workspace', directory: root, access: access, binary: '/unused' })!
	assert opened.contains('source_workspace') && access.selection().generation == 1
	plan := source_test_call(mut d, mut m, access, 'source_workspace_prepare', '{"directory":"empty","template":"vjsx-api","binding_revision":1}')!
	assert os.ls(root + '/empty')!.len == 0
	value := source_test_call(mut d, mut m, access, 'source_workspace_bind', json.encode({
		'id':               plan.as_map()['plan_id']!
		'binding_revision': json.Any(1)
	}))!
	assert value.as_map()['binding_revision']!.int() == 2
	assert !os.exists(root + '/empty/app.json') && !os.exists(root + '/empty/apps')
	assert m.project.workdir == root + '/empty' && m.project.source_workspace
	before := os.read_file(root + '/empty/main.mjs')!
	args := json.encode({
		'binding_revision': json.Any(2)
		'files':            json.Any([json.Any({
			'path':     json.Any('main.mjs')
			'revision': json.Any(sha256.hexhash(before))
			'content':  json.Any('export default c => c.json({source:true},200)')
		})])
	})
	change := source_test_call(mut d, mut m, access, 'changes_prepare', args)!
	id := change.as_map()['id']!.str()
	source_test_call(mut d, mut m, access, 'changes_validate', json.encode({
		'binding_revision': json.Any(2)
		'id':               json.Any(id)
	}))!
	source_test_call(mut d, mut m, access, 'changes_apply', json.encode({
		'binding_revision': json.Any(2)
		'id':               json.Any(id)
	}))!
	if _ := source_test_call(mut d, mut m, access, 'source_workspace_unbind', '{"binding_revision":2}') {
		return error('lost applied recovery on unbind')
	}
	source_test_call(mut d, mut m, access, 'changes_restore', json.encode({
		'binding_revision': json.Any(2)
		'id':               json.Any(id)
	}))!
	assert os.read_file(root + '/empty/main.mjs')! == before
	source_test_call(mut d, mut m, access, 'source_workspace_unbind', '{"binding_revision":2}')!
	assert access.selection().generation == 3
	if _ := source_test_call(mut d, mut m, access, 'files_read', '{"path":"main.mjs","binding_revision":2}') {
		return error('stale binding accepted')
	}
}

fn test_source_binding_preserves_existing_project_and_rejects_conflicts_and_symlinks() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'source-existing-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	os.mkdir(root + '/existing')!
	os.write_file(root + '/existing/business.js', 'original')!
	mut m := new_manager()
	mut d := DevelopmentState{}
	access := &DevelopmentAccess{}
	d.open_source_workspace(mut m, DevelopmentCall{ directory: root, access: access, binary: '/unused' })!
	plan := source_test_call(mut d, mut m, access, 'source_workspace_prepare', '{"directory":"existing","binding_revision":1}')!
	os.write_file(root + '/existing/business.js', 'concurrent')!
	if _ := source_test_call(mut d, mut m, access, 'source_workspace_bind', json.encode({
		'binding_revision': json.Any(1)
		'id':               plan.as_map()['plan_id']!
	})) {
		return error('stale source plan accepted')
	}
	for args in ['{"directory":"../escape","binding_revision":1}',
		'{"directory":"existing","template":"vjsx-http","binding_revision":1}'] {
		if _ := source_test_call(mut d, mut m, access, 'source_workspace_prepare', args) {
			return error('unsafe source binding accepted')
		}
	}
	$if !windows {
		os.symlink(root + '/existing', root + '/link')!
		if _ := source_test_call(mut d, mut m, access, 'source_workspace_prepare', '{"directory":"link","binding_revision":1}') {
			return error('symlink binding accepted')
		}
	}
	p := source_test_call(mut d, mut m, access, 'source_workspace_prepare', '{"directory":"existing","binding_revision":1}')!
	source_test_call(mut d, mut m, access, 'source_workspace_bind', json.encode({
		'binding_revision': json.Any(1)
		'id':               p.as_map()['plan_id']!
	}))!
	assert os.read_file(root + '/existing/business.js')! == 'concurrent'
	args := '{"binding_revision":2,"files":[{"path":"business.js","revision":"' + sha256.hexhash('concurrent') + '","content":"draft"}]}'
	change := source_test_call(mut d, mut m, access, 'changes_prepare', args)!
	id := change.as_map()['id']!.str()
	source_test_call(mut d, mut m, access, 'changes_validate', json.encode({
		'binding_revision': json.Any(2)
		'id':               json.Any(id)
	}))!
	source_test_call(mut d, mut m, access, 'changes_apply', json.encode({
		'binding_revision': json.Any(2)
		'id':               json.Any(id)
	}))!
	source_test_call(mut d, mut m, access, 'changes_restore', json.encode({
		'binding_revision': json.Any(2)
		'id':               json.Any(id)
	}))!
	assert os.read_file(root + '/existing/business.js')! == 'concurrent'
	assert !os.exists(root + '/existing/vhttpd.toml')
}

fn test_source_draft_can_add_runtime_configuration_and_restore_its_absence() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'source-draft-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	mut m := new_manager()
	mut d := DevelopmentState{}
	access := &DevelopmentAccess{}
	d.open_source_workspace(mut m, DevelopmentCall{ directory: root, access: access, binary: '/unused' })!
	seed := create_project(CreateProjectOptions{ name: 'seed', parent_dir: root, template: 'vjsx-http' })!
	text := os.read_file(seed.config_path)!
	source := os.read_file(seed.workdir + '/main.mjs')!
	change := source_test_call(mut d, mut m, access, 'changes_prepare', json.encode({
		'binding_revision': json.Any(1)
		'files':            json.Any([
			json.Any({
				'path':     json.Any('vhttpd.toml')
				'content':  json.Any(text)
				'revision': json.Any('')
			}),
			json.Any({
				'path':     json.Any('main.mjs')
				'content':  json.Any(source)
				'revision': json.Any('')
			}),
		])
	}))!
	args := json.encode({
		'binding_revision': json.Any(1)
		'id':               change.as_map()['id']!
	})
	source_test_call(mut d, mut m, access, 'changes_validate', args)!
	source_test_call(mut d, mut m, access, 'changes_apply', args)!
	assert inspect_project(m.project)!.admin_port > 0
	source_test_call(mut d, mut m, access, 'changes_restore', args)!
	assert !os.exists(root + '/vhttpd.toml') && !os.exists(root + '/main.mjs')
	assert os.is_file(seed.config_path)
}

fn test_source_binding_rejects_external_includes_and_directory_replacement() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'source-boundary-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	os.mkdir(root + '/app')!
	os.write_file(root + '/outside.toml', 'version = 2\n')!
	os.write_file(root + '/app/vhttpd.toml', 'version = 2\ninclude = ["../outside.toml"]\n')!
	mut m := new_manager()
	mut d := DevelopmentState{}
	access := &DevelopmentAccess{}
	d.open_source_workspace(mut m, DevelopmentCall{ directory: root, access: access, binary: '/unused' })!
	if _ := source_test_call(mut d, mut m, access, 'source_workspace_prepare', '{"directory":"app","binding_revision":1}') {
		return error('include escaped source directory')
	}
	os.rm(root + '/app/vhttpd.toml')!
	p := source_test_call(mut d, mut m, access, 'source_workspace_prepare', '{"directory":"app","binding_revision":1}')!
	source_test_call(mut d, mut m, access, 'source_workspace_bind', json.encode({
		'binding_revision': json.Any(1)
		'id':               p.as_map()['plan_id']!
	}))!
	save_projects(root + '/registry.json', [m.project])!
	assert os.read_file(root + '/registry.json')! == '[]'
	os.rename(root + '/app', root + '/old')!
	os.mkdir(root + '/app')!
	os.write_file(root + '/app/business.js', 'replacement')!
	if _ := source_test_call(mut d, mut m, access, 'files_list', '{"binding_revision":2}') {
		return error('directory replacement retained source access')
	}
	c := source_test_call(mut d, mut m, access, 'source_workspace_get', '{"binding_revision":2}')!
	assert c.as_map()['target']!.as_map()['configuration_state']!.str() == 'directory_changed'
}
