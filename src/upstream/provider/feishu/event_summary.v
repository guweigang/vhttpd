module feishu

import executor
import x.json2

// ── Event Summary ──

pub fn RuntimeEventSnapshot.summary_from_payload(payload string) executor.FeishuRuntimeEventSummary {
	parsed := json2.decode[json2.Any](payload) or { return executor.FeishuRuntimeEventSummary{} }
	root := parsed.as_map()
	h := JsonField.map(root, 'header')
	event := JsonField.map(root, 'event')
	context := JsonField.map(root, 'context')
	operator := JsonField.map(root, 'operator')
	message := JsonField.map(event, 'message')
	sender := JsonField.map(event, 'sender')
	sender_id := JsonField.map(sender, 'sender_id')
	mut action := JsonField.map(event, 'action')
	if action.len == 0 {
		action = JsonField.map(root, 'action')
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
	open_message_id := if JsonField.string(event, 'open_message_id') != '' {
		JsonField.string(event, 'open_message_id')
	} else if JsonField.string(context, 'open_message_id') != '' {
		JsonField.string(context, 'open_message_id')
	} else {
		JsonField.string(action, 'open_message_id')
	}
	mut event_kind := 'event'
	if message.len > 0 || JsonField.string(message, 'message_id') != '' {
		event_kind = 'message'
	}
	if action.len > 0 || JsonField.string(action, 'tag') != '' {
		event_kind = 'action'
	}
	mut target_type := ''
	mut target := ''
	chat_id := JsonField.string(message, 'chat_id')
	if chat_id != '' {
		target_type = 'chat_id'
		target = chat_id
	} else if open_message_id != '' {
		target_type = 'open_message_id'
		target = open_message_id
	}
	return executor.FeishuRuntimeEventSummary{
		event_id:          JsonField.string(h, 'event_id')
		event_kind:        event_kind
		event_type:        JsonField.string(h, 'event_type')
		message_id:        JsonField.string(message, 'message_id')
		message_type:      JsonField.string(message, 'message_type')
		chat_id:           chat_id
		chat_type:         JsonField.string(message, 'chat_type')
		target_type:       target_type
		target:            target
		open_message_id:   open_message_id
		root_id:           JsonField.string(message, 'root_id')
		parent_id:         JsonField.string(message, 'parent_id')
		create_time:       JsonField.string(message, 'create_time')
		sender_id:         if sender_id_value != '' { sender_id_value } else { operator_id_value }
		sender_id_type:    if sender_id_type != '' { sender_id_type } else { operator_id_type }
		sender_tenant_key: if JsonField.string(root, 'tenant_key') != '' {
			JsonField.string(root, 'tenant_key')
		} else {
			JsonField.string(sender, 'tenant_key')
		}
		action_tag:        JsonField.string(action, 'tag')
		action_value:      action_value
		token:             JsonField.string(root, 'token')
	}
}

pub fn RuntimeEventSnapshot.should_dispatch_upstream(summary executor.FeishuRuntimeEventSummary) bool {
	if summary.event_type == 'im.message.message_read_v1' {
		return false
	}
	return true
}
