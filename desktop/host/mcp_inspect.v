module host

import crypto.sha256
import encoding.base64
import json2 as json
import net.urllib
import time

pub struct McpInspectRequest {
pub:
	tool string
	target_id string
	server_id string
	topic string
	application_id string
	search string
	limit int = 100
	cursor u64
	listener string
	path string
	protocol string
	message string
	timeout_ms int = 3000
	auth_ref string
	tls_trust string = 'system'
	tls_server_name string
	max_items int = 4
	method string = 'GET'
	generation u64
	deadline i64
	access &DevelopmentAccess = &DevelopmentAccess{}
	reply chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

fn (req McpInspectRequest) check() ! {
	if req.deadline <= time.now().unix() || req.access.is_revoked()
		|| req.access.selection().generation != req.generation {
		return error('stale_binding_revision: call context_get')
	}
	if req.limit < 1 || req.limit > 200 || req.search.len > 256 {
		return error('invalid_inspection_limit_or_search')
	}
}

fn (mut s ServerSession) mcp_inspect(req McpInspectRequest) !string {
	req.check()!
	if !s.state.connected || s.server.id != req.server_id { return error('remote_host_disconnected') }
	targets := s.state.projects.filter(it.id == req.target_id)
	if targets.len != 1 { return error('remote_target_changed') }
	target := targets[0]
	if req.tool == 'relay_connections_list' {
		s.relay_catalog_operation(ServerCommand{action: .relay_load, server: s.server})!
		req.check()!
		return mcp_relay_catalog(s.state.relay_catalog.entries, target.id)
	}
	mut sources := map[string]string{}
	mut visiting := map[string]bool{}
	s.read_project_sources(target.config_path, mut sources, mut visiting) or { return error('target_redaction_context_unavailable') }
	if req.tool in ['target_probe_options_get', 'target_protocol_probe'] {
        a := ProtocolProbeArgs{protocol: req.protocol, listener: req.listener, path: req.path, message: req.message, timeout_ms: req.timeout_ms, max_items: req.max_items, auth_ref: req.auth_ref, tls_trust: req.tls_trust, tls_server_name: req.tls_server_name}
        if req.tool == 'target_protocol_probe' { a.validate()! }
        script := remote_protocol_probe_script(target.config_path, sources, a, req.tool == 'target_probe_options_get')!
        body := s.shell_limited(script, 8000, 2097152) or { return error('target_protocol_probe_transport_failed') }
        result := json.decode[json.Any](body) or { return error('invalid_protocol_probe_response') }
        req.check()!
        if failure := result.as_map()['probe_error'] { return error(failure.str()) }
        return remote_protocol_probe_safe_result(result, sources, target.token)!
    }
	plan := remote_runtime_plan(target.config_path, sources) or { return error('target_redaction_context_unavailable') }
	mut secrets := [target.token]
	development_collect_secrets(json.decode[json.Any](json.encode(plan))!, false, mut secrets)
	mut safe := DevelopmentState{}
	for secret in secrets {
		if secret != '' { safe.secrets['<vhttpd-secret-' + sha256.hexhash(secret)[..16] + '>'] = secret }
	}
	if req.tool == 'target_request' {
		listener := plan.listeners[req.listener] or { return error('unknown_business_listener') }
		if control := plan.control.listener {
			if control.id == req.listener { return error('admin_requests_forbidden') }
		}
		if listener.protocol != 'http' || listener.tls.enabled || listener.port < 1
			|| listener.host !in ['127.0.0.1', 'localhost', '0.0.0.0', ''] {
			return error('target_plain_http_loopback_listener_required')
		}
		if req.method !in ['GET', 'HEAD'] || req.path.len > 2048 || !req.path.starts_with('/')
			|| req.path.starts_with('//') || req.path.contains('://') || req.path.bytes().any(it < 32 || it == 127)
			|| req.path.all_before('?').starts_with('/admin') {
			return error('invalid_business_probe')
		}
		payload := base64.encode(json.encode({'port': json.Any(listener.port), 'path': json.Any(req.path), 'method': json.Any(req.method)}).bytes())
		probe := "import base64,json,urllib.request,urllib.error\np=json.loads(base64.b64decode('" + payload + "'))\n" + $embed_file('remote_scripts/mcp_probe.py').to_string()
		body := s.shell_limited("python3 - <<'VHTTPD_MCP_PROBE'\n" + probe + "\nVHTTPD_MCP_PROBE\n", 8000, 2097152) or { return error('target_business_probe_failed') }
		result := json.decode[json.Any](body) or { return error('invalid_business_probe_response') }
		req.check()!
		return json.encode(safe.safe_json(json.Any({'target_id': json.Any(target.id), 'listener': json.Any(req.listener), 'source': json.Any('business_http'), 'response': result})))
	}
	mut manager := &RemoteManager{}
	manager.connect_with_session(target, '', s.state.control_path)!
	defer {
		manager.disconnect()
		for endpoint in manager.browser_endpoints {
			mut server := endpoint.server
			server.stop()
		}
	}
	path := match req.tool {
		'target_diagnostics_get' { diagnostic_path(req.topic)! }
		'target_applications_list' { '/admin/apps' }
		'target_logs_query' {
			if req.application_id == '' || req.application_id == '*' { return error('application_id_required') }
			body := shared_config_request(manager, .get, '/admin/apps', '')!
			apps := json.decode[ApplicationsResponse](body) or { return error('invalid_application_inventory') }
			if !apps.apps.any(it.id == req.application_id) { return error('unknown_target_application') }
			'/admin/logs?application=' + urllib.query_escape(req.application_id) + '&limit=' + req.limit.str() + '&after=' + req.cursor.str()
		}
		'target_events_query' { '/admin/events?limit=' + req.limit.str() }
		else { return error('unknown_target_inspection_tool') }
	}
	body := shared_config_request(manager, .get, path, '') or { return error('target_inspection_unavailable: verify the connection and target runtime version') }
	mut result := if req.tool == 'target_diagnostics_get' {
		json.decode[json.Any](diagnostic_snapshot(req.topic, body)!)!.as_map()
	} else {
		target_inspection_snapshot(req, body)!
	}
	result['target_id'] = json.Any(target.id)
	result['source'] = json.Any('live_admin')
	req.check()!
	return json.encode(safe.safe_json(json.Any(result)))
}

pub fn mcp_relay_catalog(entries []SharedRelay, target_id string) string {
	mut rows := []map[string]json.Any{}
	for entry in entries {
		rows << {
			'id': json.Any(entry.id)
			'name': json.Any(entry.name)
			'protocol': json.Any(if entry.is_native() { 'vhttpd' } else { 'websocket' })
			'relay_id': json.Any(entry.relay_id)
			'authenticated': json.Any(entry.token != '')
		}
	}
	return json.encode({'target_id': json.Any(target_id), 'source': json.Any('desktop_catalog'), 'connections': json.Any(rows.map(json.Any(it)))})
}

fn target_inspection_snapshot(req McpInspectRequest, body string) !map[string]json.Any {
	value := json.decode[json.Any](body) or { return error('invalid_target_inspection_response') }
	mut result := map[string]json.Any{}
	match req.tool {
		'target_applications_list' {
			apps := json.decode[ApplicationsResponse](body) or { return error('invalid_application_inventory') }
			mut rows := []json.Any{}
			for app in apps.apps[..if apps.apps.len > 200 { 200 } else { apps.apps.len }] {
				rows << json.Any({
					'id': json.Any(app.id)
					'label': json.Any(app.label)
					'status': json.Any(app.status)
					'identity': json.Any(diagnostic_fields(json.decode[json.Any](json.encode(app.identity))!, ['app_id', 'installation_id', 'component', 'version', 'deployment_id', 'fingerprint']))
					'listeners': json.decode[json.Any](json.encode(app.listeners.filter(!it.control).map(ApplicationItem{id: it.id, kind: it.protocol})))!
					'pipelines': json.decode[json.Any](json.encode(app.pipelines.map(it.id)))!
				})
			}
			result['applications'] = json.Any(rows)
			result['truncated'] = json.Any(apps.apps.len > 200)
		}
		'target_logs_query' {
			data := value.as_map()
			if (data['version'] or { json.Any(0) }).int() != 1 { return error('unsupported_application_logs_version') }
			records := data['records'] or { return error('invalid_application_logs_response') }
			mut rows := []json.Any{}
			for record in records.as_array()[..if records.as_array().len > req.limit { req.limit } else { records.as_array().len }] {
				if (record.as_map()['app_id'] or { json.Any('') }).str() != req.application_id {
					return error('application_log_ownership_mismatch')
				}
				fields := diagnostic_fields(record, ['id', 'at_unix', 'at_ms', 'app_id', 'engine_id', 'listener_id', 'pipeline_id', 'lane_id', 'request_id', 'trace_id', 'level', 'source', 'message'])
				if req.search == '' || json.encode(fields).contains(req.search) { rows << json.Any(fields) }
			}
			result = diagnostic_fields(value, ['version', 'retained', 'dropped', 'next_cursor'])
			result['records'] = json.Any(rows)
			result['truncated'] = json.Any(records.as_array().len > req.limit)
		}
		'target_events_query' {
			if value !is []json.Any { return error('invalid_runtime_events_response') }
			mut rows := []json.Any{}
			for item in value[..if value.len > req.limit { req.limit } else { value.len }] {
				mut event := diagnostic_fields(item, ['id', 'type', 'at_unix'])
				fields := item.as_map()['fields'] or { json.Any(map[string]json.Any{}) }
				event['fields'] = json.Any(diagnostic_fields(fields, ['request_id', 'trace_id', 'application_id', 'app_id', 'listener', 'pipeline', 'relay_id', 'action', 'status', 'method', 'duration_ms']))
				if req.search == '' || json.encode(event).contains(req.search) { rows << json.Any(event) }
			}
			result['events'] = json.Any(rows)
			result['truncated'] = json.Any(value.len > req.limit)
		}
		else { return error('unknown_target_inspection_tool') }
	}
	return result
}
