module host

import os
import time

fn test_project_relay_details_use_includes_bindings_and_redacted_endpoints() ! {
	dir := os.join_path(os.temp_dir(), 'workbench-relay-details-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	os.write_file(os.join_path(dir, 'relay.toml'), 'version = 2\n[listeners.relay]\nprotocol = "websocket"\ntransport = "tcp"\nhost = "127.0.0.1"\nport = 19921\n[relays.hub]\nmode = "hub"\ncarrier = "websocket"\nlistener = "listener:relay"\npath = "/vhttpd/relay"\nnode_id = "test-hub"\ntoken = "secret-value"\n[relays.agent]\nmode = "agent"\ncarrier = "websocket"\nurl = "wss://user:password@example.test/vhttpd/relay?token=secret-value#secret-value"\nnode_id = "test-agent"\ntoken = "secret-value"\nautostart = false\n')!
	file := os.join_path(dir, 'vhttpd.toml')
	os.write_file(file, 'version = 2\ninclude = ["relay.toml"]\n[listeners.web]\nprotocol = "http"\ntransport = "tcp"\nhost = "127.0.0.1"\nport = 19920\n[adapters.response]\nkind = "fixed-response"\noptions.body = "ok"\n[adapters.remote]\nkind = "relay-delivery"\noptions.target = "relay:hub"\n[[pipelines]]\nid = "relay/receive"\ningress = "relay:agent"\negress = "adapter:response"\n[[pipelines]]\nid = "public/send"\ningress = "listener:web"\negress = "adapter:remote"\n')!
	original := os.read_file(file)!
	project := Project{name: 'relay-demo', config_path: file, workdir: dir}
	details := project_details(project)!
	assert details.relays.len == 2
	assert details.relays[0].mode == 'agent'
	assert details.relays[0].endpoint == 'wss://example.test/vhttpd/relay'
	assert details.relays[0].pipelines == ['relay/receive: relay:agent → adapter:response']
	assert details.relays[1].mode == 'hub'
	assert details.relays[1].endpoint == 'ws://127.0.0.1:19921/vhttpd/relay'
	assert details.relays[1].pipelines == ['public/send: listener:web → adapter:remote']
	assert !details.str().contains('password')
	assert !details.str().contains('secret-value')
	assert os.read_file(file)! == original
}

fn test_project_without_relay_has_empty_relay_summary() ! {
	dir := os.join_path(os.temp_dir(), 'workbench-no-relay-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	file := os.join_path(dir, 'vhttpd.toml')
	os.write_file(file, 'version = 2\n[listeners.web]\nprotocol = "http"\nhost = "127.0.0.1"\nport = 19920\n[adapters.ok]\nkind = "fixed-response"\noptions.body = "ok"\n[[pipelines]]\nid = "http/ok"\ningress = "listener:web"\negress = "adapter:ok"\n')!
	details := project_details(Project{name: 'plain', config_path: file, workdir: dir})!
	assert details.relays.len == 0
	assert details.listeners.len == 1
	assert details.entry == ''
}
