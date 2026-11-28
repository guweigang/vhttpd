module devmcp

import host
import json2 as json

fn (s &Service) queue_target_inspection(call RelayCall, inventory ManagementTargets) ! {
	s.check_management_binding(call)!
	profiles := inventory.profiles.filter(it.id == call.args.target_id)
	if profiles.len != 1 || !inventory.server.connected || inventory.server.busy
		|| profiles[0].server_id != inventory.server.server_id {
		return error('connect the registered target host in Desktop: call targets_list')
	}
	profile := profiles[0]
	select {
		inventory.worker.commands <- host.ServerCommand{action: .mcp_inspect, mcp_inspect: host.McpInspectRequest{
			tool: call.tool
			target_id: profile.id
			server_id: profile.server_id
			topic: call.args.topic
			application_id: call.args.application_id
			search: call.args.search
			limit: call.args.limit
			cursor: call.args.cursor
			listener: call.args.listener
			path: call.args.path
			auth_ref: call.args.auth_ref
			tls_trust: call.args.tls_trust
			tls_server_name: call.args.tls_server_name
			protocol: call.args.protocol
			message: call.args.message
			timeout_ms: call.args.timeout_ms
			max_items: call.args.max_items
			method: call.args.method
			generation: call.args.binding_revision
			deadline: call.deadline
			access: s.access
			reply: call.reply
		}} {}
		else { return error('Desktop server worker busy') }
	}
}

fn (inventory &ManagementTargets) host_inventory(id string) !string {
	hosts := inventory.servers.filter(it.id == id)
	if hosts.len != 1 { return error('unknown_host: call targets_list') }
	connected := inventory.server.connected && inventory.server.server_id == id
	mut candidates := []map[string]json.Any{}
	if connected {
		for profile in inventory.server.projects {
			registered := inventory.profiles.any(it.server_id == id && it.config_path == profile.config_path)
			candidates << {
				'id': json.Any(profile.id)
				'name': json.Any(profile.name)
				'runtime_id': json.Any(profile.runtime_id)
				'registered': json.Any(registered)
			}
		}
	}
	packages := if connected {
		inventory.server.runtimes.map(ManagementRuntimePackage{id: it.id, version: it.version, release_tag: it.release_tag})
	} else { []ManagementRuntimePackage{} }
	return json.encode({
		'host_id': json.Any(id)
		'name': json.Any(hosts[0].name)
		'connected': json.Any(connected)
		'busy': json.Any(connected && inventory.server.busy)
		'platform': json.Any(if connected { inventory.server.platform } else { '' })
		'source': json.Any('desktop_host_snapshot')
		'environments': json.decode[json.Any](json.encode(candidates))!
		'runtime_packages': json.decode[json.Any](json.encode(packages))!
	})
}

fn (inventory &ManagementTargets) inspection_inventory(tool string, target_id string) !string {
	if tool == 'target_history_list' {
		profiles := inventory.profiles.filter(it.id == target_id)
		if profiles.len != 1 { return error('unknown_target: call targets_list') }
		profile := profiles[0]
		if !inventory.server.connected || inventory.server.server_id != profile.server_id {
			return error('connect the original target host in Desktop')
		}
		return json.encode({'target_id': json.Any(target_id), 'source': json.Any('desktop_host_snapshot'),
			'operations': json.decode[json.Any](json.encode(inventory.operations(profile)))!})
	}
	mut entries := []host.SharedRelay{}
	if target_id == '' {
		entries = host.load_shared_relays()!
	} else {
		profiles := inventory.profiles.filter(it.id == target_id)
		if profiles.len != 1 { return error('unknown_target: call targets_list') }
		if !inventory.server.connected || inventory.server.server_id != profiles[0].server_id
			|| !inventory.server.relay_catalog.loaded {
			return error('load the target host Relay catalog in Desktop')
		}
		entries = inventory.server.relay_catalog.entries
	}
	return host.mcp_relay_catalog(entries, target_id)
}
