module host

import json2 as json
import relaydb

fn (mut s ServerSession) ordinary_database(r McpOrdinaryRelayRequest) !string {
	mut manager := &RemoteManager{}
	endpoint := if r.target_id == '' {
		r.local_endpoint(false)!
	} else {
		remote, ep := s.ordinary_remote(r.target_id)!
		manager = remote
		ep
	}
	defer { if r.target_id != '' { ordinary_close(mut manager) } }
	instance := ordinary_instance(endpoint)!
	workspace := ordinary_workspace(endpoint)!
	if ordinary_source_revision(workspace) != instance.disk_revision { return error('relay_source_not_effective') }
	plan := ordinary_runtime_plan(workspace)!
	if r.tool == 'relay_database_resources_list' {
		mut rows := []map[string]json.Any{}
		for id, resource in plan.resources {
			if resource.category != 'db' { continue }
			ref := resource.options.strings['relay']
			if ref != '' {
				rows << {'resource_id': json.Any(id), 'role': json.Any('relay_client'), 'driver': json.Any(resource.kind), 'relay_id': json.Any(ref.all_after('relay:')), 'route': json.Any(resource.options.strings['route']), 'remote_resource': json.Any(resource.options.strings['remote_resource']), 'supported': json.Any(resource.kind == 'mysql')}
			}
		}
		for pipeline in plan.pipelines {
			if pipeline.ingress.domain != .relay || pipeline.egress.domain != .adapter { continue }
			adapter := plan.adapters[pipeline.egress.id] or { continue }
			if adapter.kind != 'db-resource' { continue }
			id := adapter.options.strings['resource']
			resource := plan.resources[id] or { continue }
			rows << {'resource_id': json.Any(id), 'role': json.Any('export'), 'driver': json.Any(resource.kind), 'relay_id': json.Any(pipeline.ingress.id), 'route': json.Any(pipeline.id), 'access': json.Any(if adapter.options.strings['access'] == 'read-write' { 'read-write' } else { 'read-only' }), 'supported': json.Any(resource.kind == 'mysql')}
		}
		return json.encode({'resources': json.Any(rows.map(json.Any(it))), 'source': json.Any('live_effective_configuration')})
	}
	if !r.resource_id.starts_with('db/') || r.resource_id.len > 128 || r.resource_id !in plan.resources {
		return json.encode(relaydb.ProbeResult{stage: 'configuration', error: 'unknown_database_resource'})
	}
	r.check()!
	raw := ordinary_request(endpoint, .post, '/admin/runtime/relay/database/probe', json.encode({'resource_id': r.resource_id})) or {
		return json.encode(relaydb.ProbeResult{stage: 'runtime', error: if err.msg() == 'relay_admin_request_rejected_404' { 'runtime_probe_endpoint_unavailable_upgrade_required' } else { 'runtime_probe_unavailable_check_runtime_status' }})
	}
	result := json.decode[relaydb.ProbeResult](raw) or { return error('invalid_runtime_probe_response') }
	// Only stable categories cross the management boundary, never server errors.
	if result.stage !in ['input', 'configuration', 'carrier', 'transport', 'database', 'response', 'query'] || result.error !in ['', 'invalid_probe_input', 'invalid_database_resource', 'unknown_database_resource', 'authenticated_mysql_relay_resource_required', 'relay_not_connected', 'invalid_relay_database_binding', 'relay_database_transport_failed_no_replay', 'invalid_database_response', 'database_operation_failed', 'unexpected_probe_result'] {
		return error('invalid_runtime_probe_response')
	}
	r.check()!
	return json.encode(result)
}
