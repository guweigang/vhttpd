module host

import json2 as json

fn diagnostic_path(topic string) !string {
	return match topic {
		'graph' { '/admin/runtime/graph' }
		'workers' { '/admin/workers' }
		'providers' { '/admin/runtime/provider-instances' }
		'relay' { '/admin/runtime/relay' }
		'websocket' { '/admin/runtime/websocket-listeners' }
		else { return error('unknown_runtime_diagnostics_topic') }
	}
}

fn diagnostic_fields(value json.Any, names []string) map[string]json.Any {
	source := value.as_map()
	mut fields := map[string]json.Any{}
	for name in names {
		if child := source[name] {
			match child {
				string, bool, int, i64, u64, f64 { fields[name] = child }
				else {}
			}
		}
	}
	return fields
}

fn diagnostic_rows(value json.Any, names []string) json.Any {
	rows := value.as_array()
	return json.Any(rows[..if rows.len > 256 { 256 } else { rows.len }].map(json.Any(diagnostic_fields(it, names))))
}

fn development_diagnostics(m &Manager, topic string) !string {
	path := diagnostic_path(topic)!
	if m.phase != .running { return error('runtime_not_running') }
	body := workspace_get(m.info.admin_url.all_before('/admin/ui/'), m.token, path) or {
		return error('runtime_diagnostics_unavailable: ' + err.msg())
	}
	return diagnostic_snapshot(topic, body)!
}

fn diagnostic_snapshot(topic string, body string) !string {
	value := json.decode[json.Any](body) or { return error('invalid_runtime_diagnostics_response') }
	data := value.as_map()
	mut snapshot := map[string]json.Any{}
	mut total := 0
	match topic {
		'graph' {
			nodes := data['nodes'] or { return error('invalid_runtime_diagnostics_response') }
			edges := data['edges'] or { return error('invalid_runtime_diagnostics_response') }
			snapshot['nodes'] = diagnostic_rows(nodes, ['id', 'ref', 'domain', 'kind', 'group', 'status'])
			snapshot['edges'] = diagnostic_rows(edges, ['from', 'to', 'kind'])
			snapshot['node_count'] = json.Any(nodes.as_array().len)
			snapshot['edge_count'] = json.Any(edges.as_array().len)
			total = if nodes.as_array().len > edges.as_array().len { nodes.as_array().len } else { edges.as_array().len }
		}
		'workers' {
			workers := data['workers'] or { return error('invalid_runtime_diagnostics_response') }
			snapshot = diagnostic_fields(value, ['worker_autostart', 'worker_pool_size', 'worker_max_requests'])
			snapshot['workers'] = diagnostic_rows(workers, ['id', 'alive', 'pid', 'rss_kb', 'draining', 'inflight_requests', 'served_requests', 'restart_count'])
			total = workers.as_array().len
		}
		'providers' {
			if value !is []json.Any { return error('invalid_runtime_diagnostics_response') }
			snapshot['instances'] = diagnostic_rows(value, ['provider', 'instance', 'desired_state', 'runtime_configured', 'runtime_connected', 'config_present'])
			total = value.as_array().len
		}
		'relay' {
			agents := data['agents'] or { return error('invalid_runtime_diagnostics_response') }
			snapshot = diagnostic_fields(value, ['open_channels', 'pending_frames', 'carrier_count'])
			snapshot['agents'] = diagnostic_rows(agents, ['relay_id', 'state', 'attempt', 'next_attempt_at_ms'])
			total = agents.as_array().len
		}
		'websocket' {
			if (data['scope'] or { json.Any('') }).str() != 'process' {
				return error('websocket_process_scope_unavailable')
			}
			listeners := data['listeners'] or { return error('invalid_runtime_diagnostics_response') }
			snapshot = diagnostic_fields(value, ['scope', 'active_connections', 'active_rooms'])
			mut rows := []json.Any{}
			for listener in json.decode[WorkspaceWebSockets](body)!.listeners[..if listeners.as_array().len > 256 { 256 } else { listeners.as_array().len }] {
				rows << json.Any({'listener_ids': json.Any(listener.listener_ids.map(json.Any(it))),
					'active_connections': json.Any(listener.active_connections), 'active_rooms': json.Any(listener.active_rooms)})
			}
			snapshot['listeners'] = json.Any(rows)
			total = listeners.as_array().len
		}
		else {}
	}
	return json.encode({
		'topic': json.Any(topic)
		'source': json.Any('live_admin')
		'truncated': json.Any(total > 256)
		'snapshot': json.Any(snapshot)
	})
}
