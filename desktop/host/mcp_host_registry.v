module host

import json2 as json

pub fn validate_mcp_host_registration(server RemoteServer) ! {
	if server.name.len < 1 || server.name.len > 64 || server.name.trim_space() != server.name || server.name.bytes().any(it < 32 || it == 127) {
		return error('invalid_host_name')
	}
	if server.ssh_port < 1 || server.ssh_port > 65535 || server.auth_method != 'key' {
		return error('invalid_key_host_registration')
	}
	RemoteServer{ ...server, id: if server.id == '' { '00'.repeat(12) } else { server.id } }.validate()!
}

fn register_mcp_host(candidate RemoteServer) !RemoteServer {
	validate_mcp_host_registration(candidate)!
	mut servers := load_remote_servers()!
	for server in servers {
		if server.ssh_host == candidate.ssh_host && server.ssh_port == candidate.ssh_port && server.ssh_user == candidate.ssh_user {
			if server.name != candidate.name || server.identity_file != candidate.identity_file || server.auth_method != candidate.auth_method {
				return error('host_endpoint_already_registered_with_different_settings')
			}
			return server
		}
		if server.name == candidate.name { return error('host_name_already_registered') }
	}
	server := RemoteServer{ ...candidate, id: new_remote_id()! }
	servers << server
	save_remote_servers(servers)!
	return server
}

fn (mut s ServerSession) adoption_profile(id string) !RemoteProfile {
	matches := s.state.projects.filter(it.id == id)
	if matches.len != 1 { return error('unknown_discovered_environment') }
	return matches[0]
}

fn (mut s ServerSession) adoption_identity(target RemoteProfile) !string {
	mut manager := &RemoteManager{}
	manager.connect_with_session(target, '', s.state.control_path) or { return error('discovered_admin_connection_failed') }
	defer {
		manager.disconnect()
		for endpoint in manager.browser_endpoints {
			mut server := endpoint.server
			server.stop()
		}
	}
	instance := shared_config_instance(manager) or { return error('discovered_admin_identity_unavailable') }
	if instance.config_path != target.config_path || instance.boot_id == '' || !instance.ready {
		return error('discovered_admin_identity_mismatch_or_not_ready')
	}
	return instance.boot_id
}

fn (mut s ServerSession) mcp_registry_request(r McpLifecycleRequest) !string {
	r.check()!
	if r.tool == 'host_register' {
		server := register_mcp_host(r.server)!
		s.state = ServerSnapshot{ ...s.state, mcp_registered_host: server }
		return json.encode({
			'host_id': server.id
			'name':    server.name
			'phase':   'registered'
		})
	}
	if r.tool == 'host_disconnect' {
		if s.state.busy || (s.state.connected && s.server.id != r.server.id) {
			return error('host_worker_busy_or_wrong_host')
		}
		if s.pending_deployment.id != '' || s.state.upgrades.any(!it.finished()) || s.state.deployments.any(!it.finished()) {
			return error('remote_operation_in_progress')
		}
		s.close()
		s.mcp_connect_request = McpLifecycleRequest{}
		s.mcp_lifecycle_plan = McpLifecyclePlan{}
		s.state = ServerSnapshot{ ...s.state, mcp_host_operations: s.mcp_host_operations.clone() }
		return json.encode({
			'host_id':          r.server.id
			'phase':            'disconnected'
			'remote_instances': 'unchanged'
		})
	}
	if !s.state.connected || s.server.id != r.server.id || s.state.busy {
		return error('connect_registered_host_first')
	}
	s.inspect()!
	r.check()!
	mut candidates := []map[string]json.Any{}
	for target in s.state.projects {
		candidates << {
			'target_id':  json.Any(target.id)
			'name':       json.Any(target.name)
			'runtime_id': json.Any(target.runtime_id)
			'managed':    json.Any(target.config_path == s.state.root + '/instances/' + target.name + '/vhttpd.toml' && target.runtime_id != '')
			'cached':     json.Any(true)
		}
	}
	return json.encode({
		'host_id':    json.Any(r.server.id)
		'source':     json.Any('live_ssh_discovery')
		'candidates': json.decode[json.Any](json.encode(candidates))!
	})
}
