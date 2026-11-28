module host

import json2 as json
import os
import rand
import toml

fn shared_edit_fixture() SharedConfigWorkspace {
	return SharedConfigWorkspace{config_path: '/isolated/vhttpd.toml', files: [
		SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/vhttpd.toml'}, value: 'version=2\ninclude=["routes.toml","response.toml"]\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=19001\n[control]\nlistener="listener:admin"\ntoken="private-fixture"\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=19002\n'},
		SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/routes.toml'}, value: '# hand maintained route\n[[pipelines]]\nid="qa.shared"\ningress="listener:web"\nmatch.paths=[\n "/before", # previous path\n]\negress="adapter:reply"\n'},
		SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/response.toml'}, value: '[adapters.reply]\nkind="fixed-response"\noptions.status="200"\noptions.body="before" # body comment\nint_options.timeout_ms=1000\n'},
	]}
}

fn test_shared_config_multi_file_scalar_array_insert_and_delete_preserve_unedited_bytes() ! {
	workspace := shared_edit_fixture()
	changes, before, after := shared_build_changes(workspace, [
		McpConfigEdit{domain: 'pipelines', component: 'qa.shared', field: ['match','paths'], value: json.Any([json.Any('/after')])},
		McpConfigEdit{domain: 'pipelines', component: 'qa.shared', field: ['match','methods'], value: json.Any([json.Any('GET')])},
		McpConfigEdit{domain: 'adapters', component: 'reply', field: ['options','body'], value: json.Any('after')},
		McpConfigEdit{domain: 'adapters', component: 'reply', field: ['int_options','timeout_ms'], remove: true},
	])!
	assert changes.len == 2
	assert changes[0].value.contains('# hand maintained route')
	assert changes[1].value.contains('"after" # body comment')
	assert !changes[1].value.contains('int_options.timeout_ms')
	assert !json.encode(before).contains('private-fixture') && !json.encode(after).contains('private-fixture')
	assert changes[0].original == workspace.files[1].value
	assert changes[1].original == workspace.files[2].value
}

fn test_shared_inline_scalar_edit_and_delete_are_semantically_exact() ! {
	source := 'adapters.reply={kind="fixed-response",options={status="200",body="before"}} # comment\n'
	next, _, _ := shared_edit_text(source, McpConfigEdit{domain:'adapters',component:'reply',field:['options','body'],value:json.Any('after')})!
	assert next == source.replace('"before"','"after"')
	removed, _, _ := shared_edit_text(next, McpConfigEdit{domain:'adapters',component:'reply',field:['options','status'],remove:true})!
	assert !removed.contains('status') && removed.ends_with('# comment\n')
	assert toml.parse_text(removed)!.value('adapters.reply.options.body').string() == 'after'
}

fn test_shared_config_protects_admin_identity_secrets_app_sources_and_invalid_references() ! {
	workspace := shared_edit_fixture()
	for edit in [
		McpConfigEdit{domain:'listeners',component:'admin',field:['port'],value:json.Any(20000)},
		McpConfigEdit{domain:'adapters',component:'reply',field:['options','token'],value:json.Any('secret')},
		McpConfigEdit{domain:'engines',component:'app',field:['entry'],value:json.Any('../outside.mts')},
		McpConfigEdit{domain:'pipelines',component:'qa.shared',field:['egress'],value:json.Any('adapter:missing')},
		McpConfigEdit{domain:'adapters',component:'reply',field:['options','body'],value:json.Any('ws://private')},
	] {
		if _, _, _ := shared_build_changes(workspace,[edit]) { assert false }
	}
	if _ := shared_source_relative(workspace,'/isolated/apps/app/component.toml') { assert false }
	if _ := shared_source_relative(workspace,'/other/config.toml') { assert false }
	rows := shared_components(workspace)!
	assert !json.encode(rows).contains('private-fixture')
	assert rows.any(it['component']!.str() == 'reply')
}

fn test_config_history_survives_reopen_deduplicates_and_rejects_tampering_or_foreign_scope() ! {
	dir := os.join_path(os.real_path(os.temp_dir()), 'mcp-config-history-' + rand.hex(8))
	os.mkdir_all(dir)!
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR',dir,true)
	defer { if value := previous { os.setenv('VHTTPD_DESKTOP_DATA_DIR',value,true) } else { os.unsetenv('VHTTPD_DESKTOP_DATA_DIR') }; os.rmdir_all(dir) or {} }
	workspace := shared_edit_fixture()
	id := config_archive_save('fixture',workspace)!
	assert config_archive_save('fixture',workspace)! == id
	archive := config_archive_read('fixture')!
	assert archive.versions.len == 1 && archive.versions[0].id == id
	assert archive.versions[0].workspace.files == workspace.files
	assert int(os.stat(config_archive_path('fixture'))!.mode & 0o777) == 0o600
	assert config_archive_read('different-target')!.versions.len == 0
	path := config_archive_path('fixture')
	os.write_file(path,os.read_file(path)!.replace('private-fixture','tampered'))!
	if _ := config_archive_read('fixture') { assert false }
}

fn test_history_restore_uses_all_original_sources_and_refuses_membership_or_admin_changes() ! {
	original := shared_edit_fixture()
	mut files := original.files.clone()
	files[2] = SharedConfigSource{...files[2],value:files[2].value.replace('body="before"','body="after"')}
	current := SharedConfigWorkspace{...original,files:files}
	changes := shared_history_changes(current,original)!
	assert changes.len == 1 && changes[0].value == original.files[2].value
	if _ := shared_history_changes(current,SharedConfigWorkspace{...original,files:original.files[..2]}) { assert false }
	mut bad := original.files.clone();bad[0] = SharedConfigSource{...bad[0],value:bad[0].value.replace('private-fixture','different-token')}
	if _ := shared_history_changes(current,SharedConfigWorkspace{...original,files:bad}) { assert false }
}

fn test_shared_secret_resource_identity_and_history_are_protected() ! {
	source := '[resources.secret.env]\nkind="environment"\nsource="PRIVATE_TOKEN"\n'
	if _ := shared_component_path(source, McpConfigEdit{domain:'resources',component:'secret/env',field:['kind']}) { assert false }
	assert shared_protected_document(source)! != shared_protected_document(source.replace('environment','file'))!
}
