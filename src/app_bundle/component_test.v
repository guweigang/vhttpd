module app_bundle

import config
import encoding.base64
import os
import time

fn component_fixture() !string {
	root := os.join_path(os.real_path(os.temp_dir()), 'component-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root)!
	return root
}

fn component_source(root string, id string, port int) !string {
	dir := os.join_path(root, id)
	os.mkdir_all(dir)!
	os.write_file(dir + '/component.toml', '[listeners.${id}]\nprotocol="http"\nhost="127.0.0.1"\nport=${port}\n[engines.${id}]\nkind="vjsx"\nentry="main.mjs"\n[adapters.${id}]\nkind="http-handler"\nengine="engine:${id}"\n[[pipelines]]\nid="${id}"\ningress="listener:${id}"\negress="adapter:${id}"\n')!
	os.write_file(dir + '/main.mjs', 'export default c => c.json({app:"${id}"})')!
	return dir
}

fn test_additive_components_keep_environment_and_prior_application() ! {
	root := component_fixture()!
	defer { os.rmdir_all(root) or {} }
	env := root + '/environment'
	os.mkdir(env)!
	main := '# private environment\nversion=2\ninclude = [\n "shared.toml",\n]\n\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=39200\n[control]\nlistener="listener:admin"\ntoken="unchanged-environment-token"\n'
	os.write_file(env + '/vhttpd.toml', main)!
	shared_text := '[resources.db.shared]\nkind="sqlite"\ndatabase="keep.sqlite"\n'
	os.write_file(env + '/shared.toml', shared_text)!
	os.write_file(env + '/credentials.json', 'PRIVATE-FIXTURE')!
	for i, id in ['alpha', 'beta'] {
		source := component_source(root, id, 39201 + i)!
		os.write_file(source + '/credentials.json', 'DO-NOT-BUNDLE')!
		p := collect_component(source, source + '/component.toml', 'a'.repeat(24), id)!
		assert !p.files.any(base64.decode_str(it.data).contains('DO-NOT-BUNDLE'))
		composed := compose_component(p, env + '/vhttpd.toml')!
		materialize(composed, env)!
		assert os.read_file(env + '/shared.toml')! == shared_text
		assert os.read_file(env + '/credentials.json')! == 'PRIVATE-FIXTURE'
		assert os.read_file(env + '/vhttpd.toml')!.contains(main.all_after(']\n\n'))
		plan := config.load_runtime_plan_file(env + '/vhttpd.toml')!
		assert plan.engines.len == i + 1
	}
	same_id := component_source(root, 'same-id', 39204)!
	os.write_file(same_id + '/component.toml', os.read_file(same_id + '/component.toml')!.replace('same-id', 'alpha'))!
	same := collect_component(same_id, same_id + '/component.toml', 'd'.repeat(24), 'different-directory')!
	if _ := compose_component(same, env + '/vhttpd.toml') {
		assert false, 'Existing identifiers must not be redefined'
	}
	assert os.read_file(env + '/apps/alpha/main.mjs')! == 'export default c => c.json({app:"alpha"})'
	duplicate := collect_component(root + '/alpha', root + '/alpha/component.toml', 'b'.repeat(24), 'alpha')!
	if _ := compose_component(duplicate, env + '/vhttpd.toml') {
		assert false, 'Existing application must not be overwritten'
	}
	collision_source := component_source(root, 'gamma', 39201)!
	collision := collect_component(collision_source, collision_source + '/component.toml', 'c'.repeat(24), 'gamma')!
	if _ := compose_component(collision, env + '/vhttpd.toml') {
		assert false, 'Port conflict must be rejected'
	}
}

fn test_component_boundary_checks_and_include_byte_preservation() ! {
	root := component_fixture()!
	defer { os.rmdir_all(root) or {} }
	source := component_source(root, 'app', 39301)!
	for text in ['[control]\ntoken="forbidden"\n', 'include=["../outside.toml"]\n',
		'[resources.db.x]\ndriver="mysql"\npassword="forbidden"\n',
		'[engines.x]\nkind="vjsx"\nentry="../outside.mjs"\n'] {
		os.write_file(source + '/component.toml', text)!
		mut rejected := false
		collect_component(source, source + '/component.toml', 'a'.repeat(24), 'app') or { rejected = true }
		assert rejected
	}
	for id in ['', '../escape', 'with space', 'x/y', '-bad'] {
		assert !valid_component_id(id)
	}
	for text in ['# keep\nversion=2\n[server]\npid_file="runtime.pid"\n',
		'version=2\r\ninclude=[]\r\n# keep\r\n[server]\r\npid_file="runtime.pid"\r\n'] {
		result := append_component_include(text, 'apps/demo/component.toml')!
		assert result.contains(text[text.index('[server]') or { panic('missing section') }..])
	}
}
