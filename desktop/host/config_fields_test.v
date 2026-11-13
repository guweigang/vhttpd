module host

import json2
import os
import time

fn test_fields_show_before_after_but_never_cache_or_export_secrets() ! {
	dir := os.join_path(os.temp_dir(), 'config-fields-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := os.join_path(dir, 'vhttpd.toml')
	relay := os.join_path(dir, 'relay.toml')
	routes := os.join_path(dir, 'routes.toml')
	os.write_file(root, 'version=2\ninclude=["relay.toml","routes.toml"]\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=19891\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n')!
	old_relay := '[relays.edge]\nmode="agent"\ncarrier="websocket"\nnode_id="before-node"\nurl="wss://alice:old-password@example.test/relay?session=old-query#old-fragment"\ntoken="old-relay-secret"\nautostart=false\n'
	old_routes := '[[pipelines]]\nid="receive"\ningress="relay:edge"\negress="adapter:reply"\nmatch.paths=["/before"]\nmatch.headers={Authorization="Bearer old-header-secret","X-Custom"="old-custom-secret"}\nmatch.query={session=["old-query-secret"]}\n'
	os.write_file(relay, old_relay)!
	os.write_file(routes, old_routes)!
	before := config_component_fields(root, config_revisions(root)!, 'test-salt')!
	os.write_file(relay, old_relay.replace('before-node', 'after-node').replace('old-', 'new-'))!
	os.write_file(routes, old_routes.replace('/before', '/after').replace('old-', 'new-'))!
	after := config_component_fields(root, config_revisions(root)!, 'test-salt')!
	changes := config_field_diffs(before, after)
	for secret in ['old-relay-secret', 'new-relay-secret', 'old-password', 'new-password', 'old-query', 'new-query', 'old-fragment', 'new-fragment', 'old-header-secret', 'new-header-secret', 'old-custom-secret', 'new-custom-secret', 'old-query-secret', 'new-query-secret'] {
		assert !before.str().contains(secret), secret
		assert !after.str().contains(secret), secret
		assert !changes.str().contains(secret), secret
	}
	nodes := changes.filter(it.field == 'options.node_id')
	assert nodes.len == 1
	assert nodes[0].before == '"before-node"'
	assert nodes[0].after == '"after-node"'
	assert !nodes[0].redacted
	tokens := changes.filter(it.field == 'options.token')
	assert tokens.len == 1
	assert tokens[0].before == '[已脱敏]'
	assert tokens[0].after == '[已脱敏]'
	assert tokens[0].redacted
	assert tokens[0].source_after == relay
	paths := changes.filter(it.field == 'match.paths')
	assert paths.len == 1
	assert paths[0].before.contains('/before')
	assert paths[0].after.contains('/after')
	assert paths[0].source_after == routes
	assert changes.any(it.field == 'match.headers.Authorization' && it.redacted)
	assert changes.any(it.field == 'match.query.session' && it.redacted)
	assert changes.any(it.field == 'options.url' && it.redacted)
	os.write_file(relay, old_relay)!
	os.write_file(routes, old_routes)!
	assert config_field_diffs(before, config_component_fields(root, config_revisions(root)!, 'test-salt')!).len == 0
}

fn test_field_add_remove_move_and_secret_clear_preserve_distinctions() {
	visible := config_field_value(json2.Any('value'), false, 'salt', [])
	hidden := config_field_value(json2.Any('secret-value'), true, 'salt', [])
	cleared := config_field_value(json2.Any(''), true, 'salt', [])
	old := [ConfigComponentFields{kind: 'Relay', id: 'edge', source: '/old.toml', values: {'options.token': hidden, 'mode': visible}}]
	next := [ConfigComponentFields{kind: 'Relay', id: 'edge', source: '/new.toml', values: {'options.token': cleared, 'carrier': visible}}]
	changes := config_field_diffs(old, next)
	assert changes.any(it.field == 'mode' && it.change == '移除' && it.after == '未定义')
	assert changes.any(it.field == 'carrier' && it.change == '新增' && it.before == '未定义')
	assert changes.any(it.field == 'options.token' && it.after == '空值（敏感字段）')
	assert changes.any(it.field == '配置来源' && it.before == '/old.toml' && it.after == '/new.toml')
	assert config_field_diffs([], old).all(it.change == '新增')
	assert config_field_diffs(old, []).all(it.change == '移除')
	assert !changes.str().contains('secret-value')
}

fn test_unknown_credentials_nested_array_urls_and_known_secret_echo_are_hidden() {
	for key in ['API_KEY', 'client-secret', 'accessToken', 'private_key', 'Cookie', 'Authorization', 'password'] { assert sensitive_config_key(key) }
	value := config_field_value(json2.Any('node-private-secret'), false, 'salt', ['private-secret'])
	assert !value.text.contains('private-secret')
	assert value.redacted
	values := config_field_value(json2.Any([json2.Any('https://name:password@example.test/a?key=secret#fragment')]), false, 'salt', [])
	for secret in ['password', 'secret', 'fragment', 'name:'] { assert !values.text.contains(secret) }
	assert values.redacted
	assert config_field_value(json2.Any('same-token'), true, 'one', []).fingerprint != config_field_value(json2.Any('same-token'), true, 'two', []).fingerprint
}
