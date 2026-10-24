module config

import os
import rand

fn test_project_overlay_compiles_cross_file_references_without_writing_disk() {
	root := os.join_path(os.temp_dir(), 'vhttpd-overlay-' + rand.hex(8))
	os.mkdir_all(os.join_path(root, 'nested', 'agent')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	main := os.join_path(root, 'vhttpd.toml')
	group := os.join_path(root, 'nested', 'group.toml')
	agent := os.join_path(root, 'nested', 'agent', 'relay.toml')
	main_text := 'version = 2\ninclude = ["nested/group.toml"]\n[listeners.web]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=18080\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n'
	agent_text := '[relays.edge]\nmode="agent"\ncarrier="websocket"\nurl="ws://localhost:19921/relay"\nnode_id="before"\nautostart=false\n[[pipelines]]\nid="remote"\ningress="relay:edge"\negress="adapter:reply"\n'
	os.write_file(main, main_text) or { panic(err) }
	os.write_file(group, 'include = ["agent/relay.toml"]\n') or { panic(err) }
	os.write_file(agent, agent_text) or { panic(err) }
	sources := runtime_config_sources(main) or { panic(err) }
	assert sources.len == 3
	assert sources[2].parent_path == group
	assert sources[2].relay_ids == ['edge']
	assert sources[2].pipeline_ids == ['remote']
	changed := agent_text.replace('node_id="before"', 'node_id="after"')
	plan := load_runtime_plan_with_overrides(main, {
		agent: changed
	}) or { panic(err) }
	assert plan.source.config_path == main
	assert plan.relays['edge'].options.strings['node_id'] == 'after'
	assert plan.pipelines.len == 2
	assert os.read_file(agent) or { panic(err) } == agent_text
	assert os.read_file(main) or { panic(err) } == main_text
	if _ := load_runtime_plan_with_overrides(main, {
		agent: changed.replace('adapter:reply', 'adapter:missing')
	}) {
		assert false, 'unresolved cross-file reference was accepted'
	}
	if _ := load_runtime_plan_with_overrides(main, {
		agent:                               changed
		os.join_path(root, 'unlinked.toml'): 'version=2\n'
	}) {
		assert false, 'unreferenced override was accepted'
	}
	if _ := load_runtime_plan_with_overrides(main, {
		group: 'include=["../vhttpd.toml"]\n'
	}) {
		assert false, 'include cycle was accepted'
	}
}
