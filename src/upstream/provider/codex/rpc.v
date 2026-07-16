module codex

import jsonutils
import log
import net.websocket as ws
import time

// ── JSON-RPC Classification ──

pub struct RpcFrame {}

pub struct RpcField {}

pub struct SandboxMode {}

pub struct RpcDebug {}

pub struct WebSocketHeartbeat {}

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

// ── Encoding ──

// request builds a JSON-RPC request frame.
pub fn RpcFrame.request(method string, id int, params string) string {
	if params == '' || params == '{}' {
		return '{"method":"${method}","id":${id},"params":{}}'
	}
	return '{"method":"${method}","id":${id},"params":${params}}'
}

// notification builds a JSON-RPC notification frame (no id).
pub fn RpcFrame.notification(method string, params string) string {
	if params == '' || params == '{}' {
		return '{"method":"${method}","params":{}}'
	}
	return '{"method":"${method}","params":${params}}'
}

// format converts sandbox type between kebab-case and camelCase.
pub fn SandboxMode.format(val string, to_camel bool) string {
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

// ── Classification ──

// classify performs lightweight JSON-RPC message classification using string
// scanning. Avoids full JSON parse for every incoming frame.
pub fn RpcFrame.classify(raw string) RpcClassification {
	has_method := jsonutils.has_any_top_level_key(raw, ['method'])
	has_id := jsonutils.has_any_top_level_key(raw, ['id'])
	has_result := jsonutils.has_any_top_level_key(raw, ['result'])
	has_error := jsonutils.has_any_top_level_key(raw, ['error'])

	method := if has_method { RpcField.string(raw, 'method') } else { '' }
	id_raw := if has_id { RpcField.raw(raw, 'id') } else { '' }

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

// kind returns a human-readable kind label.
pub fn (cls RpcClassification) kind() string {
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

// nested_item extracts a field from a nested "item" object.
pub fn RpcField.nested_item(raw string, field string) string {
	if !raw.contains('"item"') {
		return ''
	}
	if item_idx := raw.index('"item"') {
		return RpcField.string(raw[item_idx..], field)
	}
	return ''
}

// summary builds a human-readable summary of an RPC frame.
pub fn RpcFrame.summary(raw string, cls RpcClassification) string {
	method := cls.method
	id_raw := cls.id_raw
	thread_id := RpcField.string(raw, 'threadId')
	turn_id := RpcField.string(raw, 'turnId')
	mut item_id := RpcField.string(raw, 'itemId')
	if item_id == '' {
		item_id = RpcField.nested_item(raw, 'id')
	}
	mut item_type := RpcField.string(raw, 'itemType')
	if item_type == '' {
		item_type = RpcField.nested_item(raw, 'type')
	}
	status_type := RpcField.string(raw, 'type')
	return 'kind=${cls.kind()} method=${method} id=${id_raw} has_error=${cls.has_error} thread_id=${thread_id} turn_id=${turn_id} item_id=${item_id} item_type=${item_type} status_type=${status_type}'
}

// string extracts a quoted string value for a given JSON key.
pub fn RpcField.string(raw string, field string) string {
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

// thread_id extracts threadId from a params JSON string.
pub fn RpcField.thread_id(params string) string {
	if params == '' || !params.contains('"threadId"') {
		return ''
	}
	return RpcField.string(params, 'threadId')
}

// raw extracts a raw JSON value (string, number, object, array, bool, null)
// for a given key.
pub fn RpcField.raw(raw string, field string) string {
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

// ── Debug Helpers ──

fn RpcDebug.enabled() bool {
	$if prod {
		return false
	}
	return true
}

fn RpcDebug.snippet(raw string, limit int) string {
	if raw.len <= limit {
		return raw
	}
	return raw[..limit] + '...'
}

// log emits a labelled debug snippet when not in production mode.
pub fn RpcDebug.log(label string, raw string) {
	if !RpcDebug.enabled() {
		return
	}
	log.info('[codex][debug] ${label}: ${RpcDebug.snippet(raw, 1600)}')
}

// ── WebSocket Ping ──

// loop sends periodic WebSocket pings until the connection closes.
pub fn WebSocketHeartbeat.loop(mut client ws.Client) {
	for client.get_state() == .open {
		client.ping() or {
			log.error('[codex] ❌ ping failed: ${err}')
			return
		}
		time.sleep(20 * time.second)
	}
}
