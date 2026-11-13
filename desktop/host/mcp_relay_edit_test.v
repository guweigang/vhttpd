module host

import json2 as json

fn edit_test_source() string { return 'version=2\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=55301\n[control]\nlistener="listener:admin"\ntoken="private-admin"\n' }

fn test_existing_relay_edit_preserves_comments_secrets_and_other_tables() ! {
	source := edit_test_source() + '\n# 手工 Relay 保留注释\n[relays."legacy"]\nmode="agent"\ncarrier="websocket"\nurl="ws://127.0.0.1:55311/relay"\ntoken=\'private-fixture\' # preserve exactly\nnode_id="before" # node comment\nautostart=true\n'
	next, before, after := relay_edit_change(McpOrdinaryRelayRequest{relay_id: 'legacy', updates: {'node_id': json.Any('after'), 'reconnect_delay_ms': json.Any(750)}}, SharedConfigWorkspace{config_path: '/isolated/vhttpd.toml', files: [SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/vhttpd.toml'}, value: source}]}, SharedRelay{})!
	assert next[0].value.contains('node_id="after" # node comment')
	assert next[0].value.contains("token='private-fixture' # preserve exactly")
	assert next[0].value.starts_with(edit_test_source())
	assert next[0].value.contains('# 手工 Relay 保留注释')
	assert before['node_id']!.str() == 'before' && after['node_id']!.str() == 'after'
	assert !json.encode(before).contains('private-fixture') && !json.encode(after).contains('ws://')
}

fn test_existing_inline_and_dotted_relay_values_are_edited_losslessly() ! {
	for source in ['relays = { "legacy" = { mode="agent", node_id="old", token="private" } }\n', 'relays.legacy.mode="agent"\nrelays.legacy.node_id="old" # comment\n'] {
		next := relay_edit_scalar(source, 'legacy', 'node_id', json.Any('new'))!
		assert next == source.replace('"old"', '"new"')
	}
	inline := 'relays = { legacy = { mode="agent", node_id="old" } } # keep\n'
	next := relay_edit_scalar(inline, 'legacy', 'autostart', json.Any(false))!
	assert next.contains('autostart = false') && next.ends_with('# keep\n')
	dotted := 'relays.legacy.mode="agent"\nrelays.legacy.node_id="old" # comment\n'
	inserted := relay_edit_scalar(dotted, 'legacy', 'max_channels', json.Any(8))!
	assert inserted.starts_with(dotted)
	assert inserted.contains('relays."legacy".max_channels = 8')
}

fn test_existing_relay_include_source_is_selected_and_no_marker_is_required() ! {
	fragment := '[relays.legacy]\nmode="agent"\nurl="ws://127.0.0.1:55311/relay"\nnode_id="before"\n'
	workspace := SharedConfigWorkspace{config_path: '/isolated/vhttpd.toml', files: [SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/vhttpd.toml'}, value: edit_test_source()}, SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/conf/relay.toml'}, value: fragment}]}
	file := relay_edit_sources(workspace, 'legacy')!
	assert file[0].source.path == '/isolated/conf/relay.toml'
	assert !file[0].value.contains('DESKTOP MCP')
}

fn test_existing_relay_patch_rejects_secrets_urls_and_invalid_types() {
	for patch in [ {'token': json.Any('secret')}, {'url': json.Any('ws://example.invalid')}, {'mode': json.Any('invalid')}, {'autostart': json.Any('false')}, {'max_channels': json.Any(0)}, {'path': json.Any('//bad')}, {'node_id': json.Any(r'${env.PRIVATE}')} ] {
		relay_edit_validate(patch) or { continue }
		assert false
	}
}

fn test_wire_json_integers_are_normalized_and_fractional_values_rejected() ! {
	patch := json.decode[map[string]json.Any]('{"max_channels":32,"reconnect_delay_ms":750}')!
	relay_edit_validate(patch)!
	source := 'relays.legacy.mode="agent"\n'
	next := relay_edit_scalar(source, 'legacy', 'max_channels', patch['max_channels']!)!
	assert next.contains('max_channels = 32\n')
	for raw in ['{"max_channels":32.5}', '{"max_channels":1e100}', '{"max_channels":-1}'] {
		relay_edit_validate(json.decode[map[string]json.Any](raw)!) or { continue }
		assert false
	}
}

fn test_relay_field_removal_preserves_comments_and_inline_neighbors() ! {
	for source in ['[relays.legacy]\nmode="agent"\nnode_id="old" # keep comment\n', 'relays.legacy.mode="agent"\nrelays.legacy.node_id="old" # keep comment\n', 'relays = { legacy = { node_id="old", mode="agent" } }\n', 'relays = { legacy = { mode="agent", node_id="old" } }\n'] {
		next := relay_edit_remove(source, 'legacy', 'node_id')!
		assert 'node_id' !in relay_edit_values(next, 'legacy')!
		assert next.contains('mode="agent"')
		if source.contains('# keep') { assert next.contains('# keep comment') }
	}
}

fn test_split_relay_edit_tracks_each_original_source_and_removes_in_place() ! {
	root := edit_test_source()
	mode := '[relays.legacy]\nmode="agent"\ncarrier="websocket"\nurl="ws://localhost:55311/relay"\n'
	options := '# options remain separate\n[relays.legacy]\nnode_id="before"\nmax_channels=16 # keep\n'
	workspace := SharedConfigWorkspace{config_path: '/isolated/vhttpd.toml', files: [SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/vhttpd.toml'}, value: root.replace('version=2', 'version=2\ninclude=["mode.toml","options.toml"]')}, SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/mode.toml'}, value: mode}, SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/options.toml'}, value: options}]}
	changes, before, after := relay_edit_change(McpOrdinaryRelayRequest{relay_id: 'legacy', updates: {'node_id': json.Any('after'), 'reconnect_delay_ms': json.Any(700)}, remove_fields: ['max_channels']}, workspace, SharedRelay{})!
	assert changes.len == 2
	assert changes[0].path == '/isolated/mode.toml'
	assert changes[0].original == mode
	assert changes[0].value.contains('reconnect_delay_ms = 700')
	assert changes[1].original == options
	assert changes[1].value.contains('node_id="after"') && changes[1].value.contains('# keep')
	assert !changes[1].value.contains('max_channels')
	assert before['max_channels']!.int() == 16 && 'max_channels' !in after
}

fn test_relay_mode_conversion_requires_reference_and_removes_incompatible_fields() ! {
	base := edit_test_source() + '[relays.legacy]\nmode="agent"\ncarrier="websocket"\nurl="ws://localhost:55311/relay"\ntoken="private"\nautostart=true\nreconnect_delay_ms=750\n'
	workspace := SharedConfigWorkspace{config_path: '/isolated/vhttpd.toml', files: [SharedConfigSource{source: SharedConfigSourcePath{path: '/isolated/vhttpd.toml'}, value: base}]}
	changes, _, after := relay_edit_change(McpOrdinaryRelayRequest{relay_id: 'legacy', updates: {'mode': json.Any('hub'), 'listener': json.Any('listener:admin'), 'path': json.Any('/relay')}}, workspace, SharedRelay{})!
	assert after['mode']!.str() == 'hub' && !after['url_present']!.bool()
	assert !changes[0].value.contains('autostart') && !changes[0].value.contains('reconnect_delay_ms')
	assert changes[0].value.contains('token="private"')
	hub := SharedConfigWorkspace{...workspace, files: [SharedConfigSource{...workspace.files[0], value: changes[0].value + 'auth="transform:legacy_auth"\n'}]}
	if _ , _, _ := relay_edit_change(McpOrdinaryRelayRequest{relay_id: 'legacy', updates: {'mode': json.Any('agent')}}, hub, SharedRelay{}) { assert false }
	connection := SharedRelay{id: 'ab'.repeat(12), name: 'test', relay_id: 'legacy', token: 'new-private', url: 'ws://127.0.0.1:55311/relay'}
	reversed, previous, next := relay_edit_change(McpOrdinaryRelayRequest{relay_id: 'legacy', connection_id: connection.id, updates: {'mode': json.Any('agent'), 'autostart': json.Any(true)}}, hub, connection)!
	assert previous['auth']!.str() == 'transform:legacy_auth' && 'auth' !in next
	assert next['mode']!.str() == 'agent' && next['url_present']!.bool()
	assert !reversed[0].value.contains('listener =') && !reversed[0].value.contains('path =')
	assert !json.encode(next).contains('new-private')
}
