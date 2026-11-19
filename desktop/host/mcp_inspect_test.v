module host

import json2 as json

fn test_target_logs_enforce_application_ownership_and_hide_storage_metadata() ! {
	req := McpInspectRequest{tool: 'target_logs_query', application_id: 'app-demo', limit: 1}
	body := '{"version":1,"file":"/private/runtime.log","storage_error":"private path","next_cursor":42,"records":[{"id":42,"app_id":"app-demo","message":"probe-ok","trace_id":"trace-42","unknown_secret":"never-return"}]}'
	result := json.encode(target_inspection_snapshot(req, body)!)
	assert result.contains('probe-ok') && result.contains('trace-42')
	for secret in ['/private/', 'private path', 'never-return', 'unknown_secret'] {
		assert !result.contains(secret)
	}
	if _ := target_inspection_snapshot(req, body.replace('app-demo', 'other-app')) {
		return error('cross-application log response accepted')
	}
	if _ := target_inspection_snapshot(req, body.replace('"version":1', '"version":2')) {
		return error('unknown log protocol accepted')
	}
}

fn test_target_event_projection_rejects_unlisted_fields() ! {
	req := McpInspectRequest{tool: 'target_events_query', limit: 1}
	body := '[{"id":"event-1","type":"request","at_unix":1,"fields":{"trace_id":"trace-1","token":"private-token","config_path":"/private/config.toml"}},{"id":"event-2"}]'
	result := json.encode(target_inspection_snapshot(req, body)!)
	assert result.contains('trace-1') && result.contains('"truncated":true')
	assert !result.contains('private-token') && !result.contains('/private/') && !result.contains('event-2')
}

fn test_websocket_diagnostics_require_process_scope() ! {
	if _ := diagnostic_snapshot('websocket', '{"scope":"listener","listeners":[]}') {
		return error('listener-local counts were accepted as process totals')
	}
	result := diagnostic_snapshot('websocket', '{"scope":"process","active_connections":3,"active_rooms":2,"listeners":[],"private_data":"secret"}')!
	assert result.contains('"active_connections":3') && !result.contains('private_data')
}
