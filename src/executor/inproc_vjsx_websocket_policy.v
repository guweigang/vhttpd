module executor

import config as app_config
import upstream.transport
import vjsx

struct WebSocketAffinityPolicy {}

struct WebSocketActorPolicy {}

struct WebSocketAffinityDecision {
mut:
	key      string
	priority int
}

fn WebSocketAffinityPolicy.normalize_source(raw string) string {
	source := raw.trim_space().to_lower()
	return match source {
		'app', 'hook', 'runtime' { 'app' }
		'header', 'headers' { 'header' }
		'path_param', 'path-param', 'pathparam' { 'path_param' }
		else { 'query' }
	}
}

fn WebSocketAffinityPolicy.normalize_scope(raw string) string {
	scope := raw.trim_space().to_lower()
	return if scope == '' { 'lane' } else { scope }
}

fn WebSocketAffinityPolicy.normalize_fallback(raw string) string {
	fallback := raw.trim_space().to_lower()
	return if fallback == 'reject' { 'reject' } else { 'round_robin' }
}

fn WebSocketActorPolicy.normalize_source(raw string) string {
	source := raw.trim_space().to_lower()
	return match source {
		'connection_cache', 'connection-cache', 'cache' { 'connection_cache' }
		'app', 'hook', 'runtime' { 'app' }
		'header', 'headers' { 'header' }
		'metadata', 'meta' { 'metadata' }
		else { 'query' }
	}
}

fn WebSocketActorPolicy.normalize_fallback(raw string) string {
	fallback := raw.trim_space().to_lower()
	return if fallback == 'reject' { 'reject' } else { 'unkeyed' }
}

fn WebSocketActorPolicy.normalize_event(raw string) string {
	event := raw.trim_space().to_lower()
	return match event {
		'open', 'message', 'close', 'info' { event }
		else { '' }
	}
}

fn WebSocketActorPolicy.events_include(events []string, event string) bool {
	normalized_event := WebSocketActorPolicy.normalize_event(event)
	if normalized_event == '' {
		return false
	}
	if events.len == 0 {
		return true
	}
	for raw in events {
		if WebSocketActorPolicy.normalize_event(raw) == normalized_event {
			return true
		}
	}
	return false
}

fn WebSocketActorPolicy.queue_key(class_name string, key string) string {
	trimmed_key := key.trim_space()
	if trimmed_key == '' {
		return ''
	}
	trimmed_class := class_name.trim_space()
	if trimmed_class == '' {
		return trimmed_key
	}
	return '${trimmed_class}:${trimmed_key}'
}

fn WebSocketAffinityPolicy.header_lookup(headers map[string]string, key string) string {
	if key == '' {
		return ''
	}
	if key in headers {
		return headers[key]
	}
	lower_key := key.to_lower()
	for name, value in headers {
		if name.to_lower() == lower_key {
			return value
		}
	}
	return ''
}

fn WebSocketAffinityPolicy.value(frame transport.WorkerWebSocketFrame, config app_config.WebSocketAffinityConfig) string {
	if !config.enabled || WebSocketAffinityPolicy.normalize_scope(config.scope) != 'lane' {
		return ''
	}
	key := config.key.trim_space()
	if key == '' {
		return ''
	}
	return match WebSocketAffinityPolicy.normalize_source(config.source) {
		'app' { '' }
		'header' { WebSocketAffinityPolicy.header_lookup(frame.headers, key).trim_space() }
		'path_param' { '' }
		else { (frame.query[key] or { '' }).trim_space() }
	}
}

fn WebSocketAffinityPolicy.priority_from_string(raw string) int {
	return match raw.trim_space().to_lower() {
		'high' { 100 }
		'low' { -100 }
		else { 0 }
	}
}

fn WebSocketActorPolicy.priority_from_string(raw string) int {
	return WebSocketAffinityPolicy.priority_from_string(raw)
}

fn WebSocketAffinityPolicy.decision_from_app_result(val vjsx.Value) WebSocketAffinityDecision {
	if val.is_undefined() || val.is_null() {
		return WebSocketAffinityDecision{}
	}
	if val.is_string() {
		return WebSocketAffinityDecision{
			key: val.to_string().trim_space()
		}
	}
	key_val := val.get('key')
	priority_val := val.get('priority')
	defer {
		key_val.free()
		priority_val.free()
	}
	mut decision := WebSocketAffinityDecision{}
	if !key_val.is_undefined() && !key_val.is_null() {
		decision.key = key_val.to_string().trim_space()
	}
	if !priority_val.is_undefined() && !priority_val.is_null() {
		if priority_val.is_number() {
			decision.priority = int(priority_val.to_i64())
		} else {
			decision.priority =
				WebSocketAffinityPolicy.priority_from_string(priority_val.to_string())
		}
	}
	return decision
}

fn WebSocketActorPolicy.decision_from_app_result(val vjsx.Value) WebSocketActorDecision {
	if val.is_undefined() || val.is_null() {
		return WebSocketActorDecision{}
	}
	if val.is_string() {
		return WebSocketActorDecision{
			key:     val.to_string().trim_space()
			persist: true
		}
	}
	key_val := val.get('key')
	class_val := val.get('class')
	priority_val := val.get('priority')
	persist_val := val.get('persist')
	defer {
		key_val.free()
		class_val.free()
		priority_val.free()
		persist_val.free()
	}
	mut decision := WebSocketActorDecision{
		persist: true
	}
	if !key_val.is_undefined() && !key_val.is_null() {
		decision.key = key_val.to_string().trim_space()
	}
	if !class_val.is_undefined() && !class_val.is_null() {
		decision.class_name = class_val.to_string().trim_space()
	}
	if !priority_val.is_undefined() && !priority_val.is_null() {
		if priority_val.is_number() {
			decision.priority = int(priority_val.to_i64())
		} else {
			decision.priority = WebSocketActorPolicy.priority_from_string(priority_val.to_string())
		}
	}
	if !persist_val.is_undefined() && !persist_val.is_null() {
		decision.persist = persist_val.to_string().trim_space().to_lower() !in [
			'false',
			'0',
			'no',
			'off',
		]
	}
	return decision
}

fn WebSocketActorPolicy.decision_from_affinity_result(result InProcVjsxLaneAffinityTaskResult) WebSocketActorDecision {
	return result.actor
}

fn WebSocketActorPolicy.value_from_source(frame transport.WorkerWebSocketFrame, source app_config.WebSocketActorSourceConfig) WebSocketActorDecision {
	key_name := source.key.trim_space()
	if key_name == '' {
		return WebSocketActorDecision{}
	}
	value := match WebSocketActorPolicy.normalize_source(source.typ) {
		'header' { WebSocketAffinityPolicy.header_lookup(frame.headers, key_name).trim_space() }
		'metadata' { (frame.metadata[key_name] or { '' }).trim_space() }
		else { (frame.query[key_name] or { '' }).trim_space() }
	}

	if value == '' {
		return WebSocketActorDecision{}
	}
	return WebSocketActorDecision{
		key:        value
		class_name: source.class_name.trim_space()
		persist:    true
	}
}

fn WebSocketAffinityPolicy.should_pin_lane(_frame transport.WorkerWebSocketFrame, affinity_key string) bool {
	key := affinity_key.trim_space()
	if key == '' {
		return false
	}
	return true
}
