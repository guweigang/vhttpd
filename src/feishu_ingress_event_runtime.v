module main

import executor

fn feishu_runtime_event_metadata(action string, summary executor.FeishuRuntimeEventSummary) map[string]string {
	mut metadata := {
		'event_id':          summary.event_id
		'event_kind':        summary.event_kind
		'chat_type':         summary.chat_type
		'message_type':      summary.message_type
		'message_id':        summary.message_id
		'target_type':       summary.target_type
		'target':            summary.target
		'open_message_id':   summary.open_message_id
		'root_id':           summary.root_id
		'parent_id':         summary.parent_id
		'create_time':       summary.create_time
		'sender_id':         summary.sender_id
		'sender_id_type':    summary.sender_id_type
		'sender_tenant_key': summary.sender_tenant_key
		'action_tag':        summary.action_tag
		'action_value':      summary.action_value
		'token':             summary.token
	}
	if action.trim_space() != '' {
		metadata['action'] = action.trim_space()
	}
	return metadata
}

fn (mut app App) dispatch_feishu_provider_ingress_event(app_name string, trace_id string, activity_id string, action string, summary executor.FeishuRuntimeEventSummary, payload string) bool {
	return app.dispatch_provider_ingress_event(websocket_upstream_provider_feishu, app_name,
		trace_id, activity_id, summary.event_type, summary.event_kind, payload, feishu_runtime_event_metadata(action,
		summary))
}
