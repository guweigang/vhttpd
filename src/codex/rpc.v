module codex

import jsonutils
import log
import net.websocket as ws
import time

// ── JSON-RPC Classification ──

// RpcClassification holds the result of lightweight frame classification.
pub struct RpcClassification {
pub:
	is_response     bool // has "id" + ("result" or "error"), no "method"
	is_notification bool // has "method", no "id"
	is_request      bool // has "method" + "id" (server-initiated request, e.g. approvals)
	method          string
	id_raw          string // raw id value as string (may be int)
	has_error       bool
}

pub struct RpcFrame {}

pub struct RpcDebug {}

pub struct RpcField {}

pub struct SandboxMode {}

pub struct WebSocketHeartbeat {}

// ── Encoding ──

// encode_request builds a JSON-RPC request frame.
pub fn encode_request(method string, id int, params string) string {
	if params == '' || params == '{}' {
		return '{"method":"${method}","id":${id},"params":{}}'
	}
	return '{"method":"${method}","id":${id},"params":${params}}'
}

pub fn RpcFrame.request(method string, id int, params string) string {
	return encode_request(method, id, params)
}

// encode_notification builds a JSON-RPC notification frame (no id).
pub fn encode_notification(method string, params string) string {
	if params == '' || params == '{}' {
		return '{"method":"${method}","params":{}}'
	}
	return '{"method":"${method}","params":${params}}'
}

pub fn RpcFrame.notification(method string, params string) string {
	return encode_notification(method, params)
}

// format_sandbox converts sandbox type between kebab-case and camelCase.
pub fn format_sandbox(val string, to_camel bool) string {
	if to_camel {
		return match val {
			'read-only' { 'readOnly' }
			'workspace-write' { 'workspaceWrite' }
			'danger-full-access' { 'dangerFullAccess' }
			else { val }
		}
	} else {
		return match val {
			'readOnly' { 'read-only' }
			'workspaceWrite' { 'workspace-write' }
			'dangerFullAccess' { 'danger-full-access' }
			else { val }
		}
	}
}

pub fn SandboxMode.format(val string, to_camel bool) string {
	return format_sandbox(val, to_camel)
}

// ── Classification ──

// classify_rpc performs lightweight JSON-RPC message classification using string
// scanning. Avoids full JSON parse for every incoming frame.
pub fn classify_rpc(raw string) RpcClassification {
	has_method := jsonutils.has_any_top_level_key(raw, ['method'])
	has_id := jsonutils.has_any_top_level_key(raw, ['id'])
	has_result := jsonutils.has_any_top_level_key(raw, ['result'])
	has_error := jsonutils.has_any_top_level_key(raw, ['error'])

	method := if has_method { extract_string_field(raw, 'method') } else { '' }
	id_raw := if has_id { extract_raw_field(raw, 'id') } else { '' }

	if has_method && !has_id {
		return RpcClassification{
			is_notification: true
			method:          method
		}
	}
	if has_method && has_id {
		return RpcClassification{
			is_request: true
			method:     method
			id_raw:     id_raw
		}
	}
	if has_id && (has_result || has_error) {
		return RpcClassification{
			is_response: true
			id_raw:      id_raw
			has_error:   has_error
		}
	}
	return RpcClassification{}
}

pub fn RpcFrame.classify(raw string) RpcClassification {
	return classify_rpc(raw)
}

// classification_kind returns a human-readable kind label.
pub fn classification_kind(cls RpcClassification) string {
	if cls.is_response {
		return 'response'
	}
	if cls.is_notification {
		return 'notification'
	}
	if cls.is_request {
		return 'request'
	}
	return 'unknown'
}

// ── Field Extraction ──

// extract_nested_item_field extracts a field from a nested "item" object.
pub fn extract_nested_item_field(raw string, field string) string {
	if !raw.contains('"item"') {
		return ''
	}
	if item_idx := raw.index('"item"') {
		return extract_string_field(raw[item_idx..], field)
	}
	return ''
}

// frame_summary builds a human-readable summary of an RPC frame.
pub fn frame_summary(raw string, cls RpcClassification) string {
	method := cls.method
	id_raw := cls.id_raw
	thread_id := extract_string_field(raw, 'threadId')
	turn_id := extract_string_field(raw, 'turnId')
	mut item_id := extract_string_field(raw, 'itemId')
	if item_id == '' {
		item_id = extract_nested_item_field(raw, 'id')
	}
	mut item_type := extract_string_field(raw, 'itemType')
	if item_type == '' {
		item_type = extract_nested_item_field(raw, 'type')
	}
	status_type := extract_string_field(raw, 'type')
	return 'kind=${classification_kind(cls)} method=${method} id=${id_raw} has_error=${cls.has_error} thread_id=${thread_id} turn_id=${turn_id} item_id=${item_id} item_type=${item_type} status_type=${status_type}'
}

pub fn RpcFrame.summary(raw string, cls RpcClassification) string {
	return frame_summary(raw, cls)
}

// extract_string_field extracts a quoted string value for a given JSON key.
pub fn extract_string_field(raw string, field string) string {
	marker := '"${field}"'
	mut idx := raw.index(marker) or { return '' }
	idx += marker.len
	// skip : and optional whitespace
	for idx < raw.len && (raw[idx] == `:` || raw[idx] == ` ` || raw[idx] == `\t`
		|| raw[idx] == `\n` || raw[idx] == `\r`) {
		idx++
	}
	if idx >= raw.len || raw[idx] != `"` {
		return ''
	}
	idx++ // skip opening quote
	start := idx
	for idx < raw.len && raw[idx] != `"` {
		if raw[idx] == `\\` {
			idx++ // skip escaped char
		}
		idx++
	}
	return raw[start..idx]
}

pub fn RpcField.string(raw string, field string) string {
	return extract_string_field(raw, field)
}

// extract_rpc_thread_id extracts threadId from a params JSON string.
pub fn extract_rpc_thread_id(params string) string {
	if params == '' || !params.contains('"threadId"') {
		return ''
	}
	return extract_string_field(params, 'threadId')
}

pub fn RpcField.thread_id(params string) string {
	return extract_rpc_thread_id(params)
}

// extract_raw_field extracts a raw JSON value (string, number, object, array, bool, null)
// for a given key.
pub fn extract_raw_field(raw string, field string) string {
	marker := '"${field}"'
	mut idx := raw.index(marker) or { return '' }
	idx += marker.len
	for idx < raw.len && (raw[idx] == `:` || raw[idx] == ` ` || raw[idx] == `\t`) {
		idx++
	}
	if idx >= raw.len {
		return ''
	}
	start := idx
	// value can be number, string, object, array, bool, null
	if raw[idx] == `"` {
		// string value — find closing quote
		idx++
		for idx < raw.len {
			if raw[idx] == `\\` {
				idx++
			} else if raw[idx] == `"` {
				idx++
				break
			}
			idx++
		}
	} else if raw[idx] == `{` || raw[idx] == `[` {
		// object/array value — track nesting while ignoring quoted strings
		mut stack := []u8{cap: 16}
		stack << raw[idx]
		idx++
		mut in_string := false
		mut escaped := false
		for idx < raw.len && stack.len > 0 {
			ch := raw[idx]
			if in_string {
				if escaped {
					escaped = false
				} else if ch == `\\` {
					escaped = true
				} else if ch == `"` {
					in_string = false
				}
				idx++
				continue
			}
			if ch == `"` {
				in_string = true
				idx++
				continue
			}
			if ch == `{` || ch == `[` {
				stack << ch
			} else if ch == `}` {
				if stack.len > 0 && stack[stack.len - 1] == `{` {
					stack.delete(stack.len - 1)
				} else {
					break
				}
			} else if ch == `]` {
				if stack.len > 0 && stack[stack.len - 1] == `[` {
					stack.delete(stack.len - 1)
				} else {
					break
				}
			}
			idx++
		}
	} else {
		// number, bool, null — read until , or } or ]
		for idx < raw.len && raw[idx] != `,` && raw[idx] != `}` && raw[idx] != `]`
			&& raw[idx] != ` ` && raw[idx] != `\n` {
			idx++
		}
	}
	return raw[start..idx].trim_space()
}

pub fn RpcField.raw(raw string, field string) string {
	return extract_raw_field(raw, field)
}

// ── Debug Helpers ──

fn debug_enabled() bool {
	$if prod {
		return false
	}
	return true
}

fn debug_snippet(raw string, limit int) string {
	if raw.len <= limit {
		return raw
	}
	return raw[..limit] + '...'
}

// debug_log logs a labelled debug snippet when not in production mode.
pub fn debug_log(label string, raw string) {
	if !debug_enabled() {
		return
	}
	log.info('[codex][debug] ${label}: ${debug_snippet(raw, 1600)}')
}

pub fn RpcDebug.log(label string, raw string) {
	debug_log(label, raw)
}

// ── WebSocket Ping ──

// ping_loop sends periodic WebSocket pings until the connection closes.
pub fn ping_loop(mut client ws.Client) {
	for client.get_state() == .open {
		client.ping() or {
			log.error('[codex] ❌ ping failed: ${err}')
			return
		}
		time.sleep(20 * time.second)
	}
}

pub fn WebSocketHeartbeat.loop(mut client ws.Client) {
	ping_loop(mut client)
}
