module app_bundle

import app_meta
import encoding.base64
import os
import time

fn test_application_installation_identity_update_delete_and_environment_preservation() ! {
	root := installation_fixture()!
	defer { os.rmdir_all(root) or {} }
	env := root + '/env'
	os.mkdir(env)!
	os.write_file(env + '/vhttpd.toml', 'version=2\n')!
	source := installation_source(root, 'alpha', 39701)!
	meta := app_meta.initialize(source, 'alpha', 'component.toml')!
	os.write_file(source + '/obsolete.mjs', 'old-owned-source')!
	p := collect_component(source, source + '/component.toml', 'a'.repeat(24), 'first-slot')!
	initial := compose_component(p, env + '/vhttpd.toml')!
	// Preview recomposition is deterministic; no random installation UUID drift.
	assert initial.files == compose_component(p, env + '/vhttpd.toml')!.files
	materialize(initial, env)!
	record := read_installation(env, 'first-slot')!
 whole := collect(env,env+'/vhttpd.toml','d'.repeat(24))!
 assert !whole.files.any(os.file_name(it.path) == '.vhttpd-installation.json')
	assert record.app_id == meta.id
	assert engine_manifest(env + '/vhttpd.toml', 'alpha')!.id == meta.id
	assert engine_identity(env + '/vhttpd.toml', 'alpha')!.installation_id == record.id
	assert entry_identity(env + '/apps/first-slot/main.mjs')!.installation_id == record.id
	assert entry_identity(source + '/main.mjs')!.installation_id == ''
	assert record.id != meta.id
	os.write_file(env + '/apps/first-slot/family-data.json', 'DO NOT REMOVE')!
	os.rm(source + '/obsolete.mjs')!
	os.write_file(source + '/main.mjs', 'export default c => c.json({updated:true})')!
	os.write_file(source + '/component.toml', os.read_file(source + '/component.toml')!.replace('port=39701', 'port=39999'))!
	original := os.read_file(env + '/vhttpd.toml')!
	update := collect_component_update(source, source + '/component.toml', 'b'.repeat(24), 'first-slot', record.id)!
	next := compose_component(update, env + '/vhttpd.toml')!
	assert next.files.any(it.path == 'apps/first-slot/obsolete.mjs' && it.remove)
	assert !next.files.any(it.path.ends_with('family-data.json'))
	assert base64.decode_str(next.files.filter(it.path == 'vhttpd.toml')[0].data) == original
	for file in next.files {
		if file.remove { os.rm(env + '/' + file.path)! }
	}
	materialize(next, env)!
	assert !os.read_file(env + '/apps/first-slot/component.toml')!.contains('39999')
	assert read_installation(env, 'first-slot')!.id == record.id
	assert read_installation(env, 'first-slot')!.deployment_id == 'b'.repeat(24)
	assert os.read_file(env + '/apps/first-slot/family-data.json')! == 'DO NOT REMOVE'
	os.write_file(source + '/family-data.json', 'source conflict')!
	conflict := collect_component_update(source, source + '/component.toml', 'c'.repeat(24), 'first-slot', record.id)!
	mut conflict_rejected := false
	compose_component(conflict, env + '/vhttpd.toml') or { conflict_rejected = err.msg() == 'application_unowned_file_conflict' }
	assert conflict_rejected
	os.rm(source + '/family-data.json')!
	// Explicit target identity is mandatory, even with matching names/app UUIDs.
	wrong := Payload{ ...update, target_installation_id: meta.id }
	mut rejected := false
	compose_component(wrong, env + '/vhttpd.toml') or { rejected = true }
	assert rejected
	os.write_file(env + '/apps/first-slot/main.mjs', 'external modification')!
	rejected = false
	compose_component(update, env + '/vhttpd.toml') or { rejected = true }
	assert rejected
}

fn installation_fixture() !string {
	root := os.join_path(os.real_path(os.temp_dir()), 'component-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root)!
	return root
}

fn installation_source(root string, id string, port int) !string {
	dir := os.join_path(root, id)
	os.mkdir_all(dir)!
	os.write_file(dir + '/component.toml', '[listeners.${id}]\nprotocol="http"\nhost="127.0.0.1"\nport=${port}\n[engines.${id}]\nkind="vjsx"\nentry="main.mjs"\n[adapters.${id}]\nkind="http-handler"\nengine="engine:${id}"\n[[pipelines]]\nid="${id}"\ningress="listener:${id}"\negress="adapter:${id}"\n')!
	os.write_file(dir + '/main.mjs', 'export default c => c.json({app:"${id}"})')!
	return dir
}
