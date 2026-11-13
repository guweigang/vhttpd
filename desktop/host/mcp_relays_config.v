module host

import crypto.rand
import json2 as json
import runtime_plan

fn ordinary_name(id string) bool {
	return id.len in 1 .. 65 && id.bytes().all(it.is_alnum() || it in [u8(`_`), `-`])
}

fn ordinary_path(path string) bool {
	return path.len in 1 .. 257 && path.starts_with('/') && !path.starts_with('//') && path.bytes().all(it.is_alnum() || it in [
		u8(`/`),
		`-`,
		`_`,
		`.`,
		`~`,
	])
}

fn ordinary_markers(id string) (string, string) {
	return '# BEGIN DESKTOP MCP RELAY ' + id + '\n', '# END DESKTOP MCP RELAY ' + id + '\n'
}

fn ordinary_fragment(source string, id string) !string {
	begin, end := ordinary_markers(id)
	if source.count(begin) != 1 || source.count(end) != 1 {
		return error('relay_not_owned_by_desktop_mcp')
	}
	return begin + source.all_after(begin).all_before(end) + end
}

fn ordinary_replace_fragment(source string, id string, fragment string) !string {
	begin, end := ordinary_markers(id)
	if !source.contains(begin) && !source.contains(end) { return source + '\n' + fragment }
	current := ordinary_fragment(source, id)!
	return source.replace(current, fragment)
}

fn ordinary_runtime_plan(workspace SharedConfigWorkspace) !runtime_plan.RuntimePlan {
	mut sources := map[string]string{}
	for file in workspace.files { sources[file.source.path] = file.value }
	return remote_runtime_plan(workspace.config_path, sources)!
}

fn ordinary_build_config(r McpOrdinaryRelayRequest, workspace SharedConfigWorkspace, connection SharedRelay) !(OrdinaryConfigChange, string) {
	if !ordinary_name(r.relay_id) { return error('invalid_relay_id') }
	roots := workspace.files.filter(it.source.path == workspace.config_path)
	if roots.len != 1 || roots[0].value.len > 262144 {
		return error('relay_root_source_unavailable')
	}
	source := roots[0].value
	plan := ordinary_runtime_plan(workspace)!
	begin, end := ordinary_markers(r.relay_id)
	existing := r.relay_id in plan.relays
	if existing && !source.contains(begin) {
		return error('existing_relay_requires_explicit_desktop_edit')
	}
	mut fragment := begin
	route := if r.route == '' { 'desktop/relay/' + r.relay_id } else { r.route }
	if !ordinary_path('/' + route) { return error('invalid_relay_route') }
	if r.mode in ['start', 'stop'] {
		descriptor := plan.relays[r.relay_id] or { return error('unknown_relay') }
		if descriptor.mode != 'agent' { return error('relay_agent_required') }
		current := ordinary_fragment(source, r.relay_id)!
		mut lines := current.split('\n')
		mut found := 0
		for i, line in lines {
			if line.all_before('=').trim_space() == 'autostart' {
				lines[i] = 'autostart = ' + if r.mode == 'start' { 'true' } else { 'false' }
				found++
			}
		}
		if found != 1 { return error('owned_relay_autostart_missing') }
		fragment = lines.join('\n')
	} else if r.mode == 'hub' {
		if r.port !in 1024 .. 65536 || !ordinary_path(r.path) || (r.verify_path != '' && !ordinary_path(r.verify_path)) {
			return error('invalid_hub_listener_or_path')
		}
		listener := 'desktop_relay_' + r.relay_id
		adapter := listener + '_delivery'
		if !existing && (listener in plan.listeners || adapter in plan.adapters) {
			return error('owned_relay_resource_conflict')
		}
		for id, other in plan.listeners {
			if other.port == r.port && id != listener {
				return error('hub_port_already_configured')
			}
		}
		token := if existing {
			plan.relays[r.relay_id].options.strings['token']
		} else {
			rand.bytes(32)!.hex()
		}
		if token == '' { return error('authenticated_hub_required') }
		fragment += '[listeners.${listener}]\nprotocol = "http"\ntransport = "tcp"\nhost = "0.0.0.0"\nport = ${r.port}\n\n[relays.${r.relay_id}]\nmode = "hub"\ncarrier = "websocket"\nlistener = "listener:${listener}"\npath = ${json.encode(r.path)}\nnode_id = "desktop-hub-${r.relay_id}"\ntoken = ${json.encode(token)}\n\n'
		if r.verify_path != '' {
			fragment += '[adapters.${adapter}]\nkind = "relay-delivery"\noptions.target = "relay:${r.relay_id}"\noptions.completion_mode = "wait"\nint_options.completion_timeout_ms = 5000\noptions.frame_kind = "open"\noptions.route = ${json.encode(route)}\n\n[[pipelines]]\nid = "desktop/${r.relay_id}/forward"\ningress = "listener:${listener}"\nmatch.paths = [${json.encode(r.verify_path)}]\negress = "adapter:${adapter}"\n'
		}
		fragment += end
	} else if r.mode == 'agent' {
		connection.validate()!
		if !connection.is_native() || connection.relay_id != r.relay_id {
			return error('native_relay_connection_id_mismatch')
		}
		if !ordinary_name(r.adapter_id) || r.adapter_id !in plan.adapters {
			return error('choose_existing_local_adapter')
		}
		fragment += shared_relay_toml(connection, r.relay_id, 'mcp-conn-' + connection.id)!
		fragment += '\n[[pipelines]]\nid = ${json.encode(route)}\ningress = "relay:${r.relay_id}"\negress = "adapter:${r.adapter_id}"\n' + end
	} else {
		return error('unknown_relay_configuration_mode')
	}
	value := ordinary_replace_fragment(source, r.relay_id, fragment)!
	// Compile every include before sending the draft to the selected runtime.
	mut candidate := map[string]string{}
	for file in workspace.files {
		candidate[file.source.path] = if file.source.path == workspace.config_path {
			value
		} else {
			file.value
		}
	}
	_ := remote_runtime_plan(workspace.config_path, candidate)!
	return OrdinaryConfigChange{ path: workspace.config_path, original: source, value: value }, route
}
