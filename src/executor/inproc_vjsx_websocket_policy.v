module executor

import config as app_config
import upstream.transport
import vjsx

struct WebSocketAffinityPolicy {}

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

fn WebSocketAffinityPolicy.should_pin_lane(_frame transport.WorkerWebSocketFrame, affinity_key string) bool {
	key := affinity_key.trim_space()
	if key == '' {
		return false
	}
	return true
}
