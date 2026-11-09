module host

fn ordinary_test_workspace(value string) SharedConfigWorkspace {
	return SharedConfigWorkspace{ config_path: '/isolated/vhttpd.toml', files: [SharedConfigSource{ source: SharedConfigSourcePath{ path: '/isolated/vhttpd.toml' }, value: value }] }
}

fn ordinary_test_source() string {
	return 'version=2\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=55301\n[control]\nlistener="listener:admin"\ntoken="admin-private-fixture"\n[adapters.reply]\nkind="fixed-response"\noptions.body="relay-ok"\n'
}

fn test_owned_agent_start_stop_preserves_exact_configuration_for_recovery() ! {
	source := ordinary_test_source()
	connection := SharedRelay{ id: 'ab'.repeat(12), name: 'QA', relay_id: 'qa', url: 'ws://127.0.0.1:55311/relay', token: 'relay-private-fixture' }
	agent, _ := ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'agent', relay_id: 'qa', adapter_id: 'reply' }, ordinary_test_workspace(source), connection)!
	assert agent.original == source && agent.value.starts_with(source)
	assert agent.value.contains('autostart = false')
	start, _ := ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'start', relay_id: 'qa' }, ordinary_test_workspace(agent.value), SharedRelay{})!
	assert start.value.contains('autostart = true')
	stop, _ := ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'stop', relay_id: 'qa' }, ordinary_test_workspace(start.value), SharedRelay{})!
	assert stop.value == agent.value
}

fn test_unowned_relay_is_never_overwritten() ! {
	source := ordinary_test_source() + '\n[relays.qa]\nmode="agent"\nurl="ws://127.0.0.1:55311/relay"\nautostart=false\n'
	ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'stop', relay_id: 'qa' }, ordinary_test_workspace(source), SharedRelay{}) or {
		assert err.msg().contains('existing_relay')
		return
	}
	assert false
}

fn test_invalid_relay_identifiers_and_resource_conflicts_are_rejected() ! {
	for id in ['../escape', 'bad\nrelay', 'a.b', ''] {
		ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'hub', relay_id: id, port: 55311, path: '/relay', verify_path: '/probe' }, ordinary_test_workspace(ordinary_test_source()), SharedRelay{}) or { continue }
		assert false
	}
	ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'hub', relay_id: 'qa', port: 55301, path: '/relay', verify_path: '/probe' }, ordinary_test_workspace(ordinary_test_source()), SharedRelay{}) or {
		assert err.msg().contains('port_already_configured')
		return
	}
	assert false
}

fn test_hub_configuration_contains_no_extra_process_and_one_shared_listener() ! {
	change, route := ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'hub', relay_id: 'qa', port: 55311, path: '/relay', verify_path: '/probe' }, ordinary_test_workspace(ordinary_test_source()), SharedRelay{})!
	plan := ordinary_runtime_plan(ordinary_test_workspace(change.value))!
	assert plan.listeners['desktop_relay_qa'].protocol == 'http'
	ref := plan.relays['qa'].ingress or { return error('missing hub listener') }
	assert ref.id == 'desktop_relay_qa'
	assert plan.relays['qa'].options.strings['token'].len == 64
	assert route == 'desktop/relay/qa'
}

fn test_hub_without_explicit_verification_path_has_no_http_forwarding_route() ! {
	change, _ := ordinary_build_config(McpOrdinaryRelayRequest{ mode: 'hub', relay_id: 'qa', port: 55311, path: '/relay' }, ordinary_test_workspace(ordinary_test_source()), SharedRelay{})!
	assert !change.value.contains('[pipelines.')
	assert !change.value.contains('[routes.')
	plan := ordinary_runtime_plan(ordinary_test_workspace(change.value))!
	assert plan.relays['qa'].mode == 'hub'
}
