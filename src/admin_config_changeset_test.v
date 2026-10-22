module main

import admin_state_store
import config
import json2 as json
import os
import rand

fn changeset_app_fixture() (string, string, string, string, App) {
	root := os.join_path(os.temp_dir(), 'vhttpd-project-set-' + rand.hex(8))
	os.mkdir_all(os.join_path(root, 'config')) or { panic(err) }
	root_file := os.join_path(root, 'vhttpd.toml')
	relay_file := os.join_path(root, 'config', 'relay.toml')
	route_file := os.join_path(root, 'config', 'routes.toml')
	os.write_file(root_file, 'version=2\ninclude=["config/relay.toml","config/routes.toml"]\n[listeners.web]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=18080\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n') or { panic(err) }
	os.write_file(relay_file, '[relays.edge]\nmode="agent"\nurl="ws://127.0.0.1:19921/relay"\nnode_id="before"\nautostart=false\n') or { panic(err) }
	os.write_file(route_file, '[[pipelines]]\nid="remote"\ningress="relay:edge"\negress="adapter:reply"\n') or { panic(err) }
	plan := config.load_runtime_plan_file(root_file) or { panic(err) }
	return root, root_file, relay_file, route_file, App{ DataPlaneRuntime: DataPlaneRuntime{ plan: plan }, control_plane: ControlPlaneRuntime{ event_log: os.join_path(root, 'events.ndjson') } }
}

fn test_changeset_workspace_identifies_separate_relay_pipeline_and_adapter_sources() {
	root, _, relay_file, route_file, app_value := changeset_app_fixture()
	defer { os.rmdir_all(root) or {} }
	mut app := app_value
	workspace := app.admin_config_workspace() or { panic(err) }
	assert workspace.files.len == 3
	assert workspace.files.any(it.source.path == relay_file && it.source.relay_ids == ['edge'])
	assert workspace.pipelines.any(it.id == 'remote' && it.source_path == route_file && it.ingress == 'relay:edge')
	assert workspace.adapters[0].source_path == workspace.config_path
}

fn test_changeset_validates_combined_overrides_and_publishes_without_touching_root() {
	root, root_file, relay_file, route_file, app_value := changeset_app_fixture()
	defer { os.rmdir_all(root) or {} }
	mut app := app_value
	root_text := os.read_file(root_file) or { panic(err) }
	relay_text := os.read_file(relay_file) or { panic(err) }
	route_text := os.read_file(route_file) or { panic(err) }
	changed_relay := relay_text.replace('relays.edge', 'relays.next')
	changed_route := route_text.replace('relay:edge', 'relay:next')
	if _ := config.load_runtime_plan_with_overrides(root_file, {
		relay_file: changed_relay
	}) {
		assert false
	}
	bundle := AdminConfigChangeSet{ config_path: root_file, files: [
		admin_state_store.ConfigFileChange{ path: relay_file, original: relay_text, value: changed_relay },
		admin_state_store.ConfigFileChange{ path: route_file, original: route_text, value: changed_route },
	] }
	app.admin_config_changeset_save('pair', json.encode(bundle)) or { panic(err) }
	validation := app.admin_config_changeset_validate('pair')
	assert validation.ok, validation.error
	assert validation.counts.pipelines == 2
	assert os.read_file(relay_file) or { panic(err) } == relay_text
	result := app.admin_config_changeset_publish('pair') or { panic(err) }
	assert result.paths == [relay_file, route_file]
	assert os.read_file(root_file) or { panic(err) } == root_text
	assert os.read_file(relay_file) or { panic(err) } == changed_relay
	assert os.read_file(route_file) or { panic(err) } == changed_route
	config.load_runtime_plan_file(root_file) or { panic(err) }
}

fn test_changeset_conflict_or_detached_source_cannot_partially_publish() {
	root, root_file, relay_file, route_file, app_value := changeset_app_fixture()
	defer { os.rmdir_all(root) or {} }
	mut app := app_value
	relay_text := os.read_file(relay_file) or { panic(err) }
	route_text := os.read_file(route_file) or { panic(err) }
	bundle := AdminConfigChangeSet{ config_path: root_file, files: [
		admin_state_store.ConfigFileChange{ path: relay_file, original: relay_text, value: relay_text.replace('before', 'after') },
		admin_state_store.ConfigFileChange{ path: route_file, original: route_text, value: route_text + '\n# new route comment\n' },
	] }
	app.admin_config_changeset_save('conflict', json.encode(bundle)) or { panic(err) }
	os.write_file(route_file, route_text + '\n# external edit\n') or { panic(err) }
	if _ := app.admin_config_changeset_publish('conflict') {
		assert false
	}
	assert os.read_file(relay_file) or { panic(err) } == relay_text
	os.write_file(root_file, (os.read_file(root_file) or { panic(err) }).replace(',"config/routes.toml"', '')) or { panic(err) }
	if _ := app.admin_config_changeset_publish('conflict') {
		assert false
	}
	assert os.read_file(relay_file) or { panic(err) } == relay_text
}
