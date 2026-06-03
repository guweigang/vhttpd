module executor

import transport
import net.http
import net.unix
import x.json2

pub interface AppFacade {
	// Config & Backend details
	get_runtime_config_json() string
	worker_backend_read_timeout_ms() int
	worker_backend_sockets_len() int
mut:
	// Worker Backend routing/lifecycle methods
	worker_backend_select_socket_queued() !string
	on_worker_request_started(socket_path string)
	on_worker_request_finished(socket_path string)
	worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string)
	worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
	worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
	worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse

	// Platform & Dispatcher methods
	emit(kind string, fields map[string]string)
	admin_runtime_snapshot() AdminRuntimeSummary
	feishu_card_bridge_dispatch_callback(app_name string, trace_id string, summary FeishuRuntimeEventSummary, payload string) !FeishuCardBridgeResult
	execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult
	run_command_envelopes(request_id string, dispatch_ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) string
}

pub struct FeishuRuntimeEventSummary {
pub mut:
	event_id          string
	event_kind        string
	event_type        string
	message_id        string
	message_type      string
	chat_id           string
	chat_type         string
	target_type       string
	target            string
	open_message_id   string
	root_id           string
	parent_id         string
	create_time       string
	sender_id         string
	sender_id_type    string
	sender_tenant_key string
	action_tag        string
	action_value      string
	token             string
}

fn feishu_json_field_string(obj map[string]json2.Any, key string) string {
	return (obj[key] or { json2.Any('') }).str()
}

fn feishu_json_map_field(obj map[string]json2.Any, key string) map[string]json2.Any {
	return (obj[key] or { json2.Any(map[string]json2.Any{}) }).as_map()
}

pub fn feishu_runtime_event_summary(payload string) FeishuRuntimeEventSummary {
	parsed := json2.decode[json2.Any](payload) or { return FeishuRuntimeEventSummary{} }
	root := parsed.as_map()
	header := feishu_json_map_field(root, 'header')
	event := feishu_json_map_field(root, 'event')
	context := feishu_json_map_field(root, 'context')
	operator := feishu_json_map_field(root, 'operator')
	message := feishu_json_map_field(event, 'message')
	sender := feishu_json_map_field(event, 'sender')
	sender_id := feishu_json_map_field(sender, 'sender_id')
	mut action := feishu_json_map_field(event, 'action')
	if action.len == 0 {
		action = feishu_json_map_field(root, 'action')
	}
	mut operator_id_type := ''
	mut operator_id_value := ''
	for key, value in operator {
		candidate := value.str()
		if candidate == '' {
			continue
		}
		operator_id_type = key
		operator_id_value = candidate
		break
	}
	mut sender_id_type := ''
	mut sender_id_value := ''
	for key, value in sender_id {
		candidate := value.str()
		if candidate == '' {
			continue
		}
		sender_id_type = key
		sender_id_value = candidate
		break
	}
	action_value := if action_value_any := action['value'] {
		action_value_any.str()
	} else {
		''
	}
	open_message_id := if feishu_json_field_string(event, 'open_message_id') != '' {
		feishu_json_field_string(event, 'open_message_id')
	} else if feishu_json_field_string(context, 'open_message_id') != '' {
		feishu_json_field_string(context, 'open_message_id')
	} else {
		feishu_json_field_string(action, 'open_message_id')
	}
	mut event_kind := 'event'
	if message.len > 0 || feishu_json_field_string(message, 'message_id') != '' {
		event_kind = 'message'
	}
	if action.len > 0 || feishu_json_field_string(action, 'tag') != '' {
		event_kind = 'action'
	}
	mut target_type := ''
	mut target := ''
	chat_id := feishu_json_field_string(message, 'chat_id')
	if chat_id != '' {
		target_type = 'chat_id'
		target = chat_id
	} else if open_message_id != '' {
		target_type = 'open_message_id'
		target = open_message_id
	}
	return FeishuRuntimeEventSummary{
		event_id:          feishu_json_field_string(header, 'event_id')
		event_kind:        event_kind
		event_type:        feishu_json_field_string(header, 'event_type')
		message_id:        feishu_json_field_string(message, 'message_id')
		message_type:      feishu_json_field_string(message, 'message_type')
		chat_id:           chat_id
		chat_type:         feishu_json_field_string(message, 'chat_type')
		target_type:       target_type
		target:            target
		open_message_id:   open_message_id
		root_id:           feishu_json_field_string(message, 'root_id')
		parent_id:         feishu_json_field_string(message, 'parent_id')
		create_time:       feishu_json_field_string(message, 'create_time')
		sender_id:         if sender_id_value != '' { sender_id_value } else { operator_id_value }
		sender_id_type:    if sender_id_type != '' { sender_id_type } else { operator_id_type }
		sender_tenant_key: if feishu_json_field_string(root, 'tenant_key') != '' {
			feishu_json_field_string(root, 'tenant_key')
		} else {
			feishu_json_field_string(sender, 'tenant_key')
		}
		action_tag:        feishu_json_field_string(action, 'tag')
		action_value:      action_value
		token:             feishu_json_field_string(root, 'token')
	}
}
