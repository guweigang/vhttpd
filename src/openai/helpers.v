module openai

import net.http
import x.json2

// ── String & URL Helpers ──

// hex_chunk_size parses a hex chunk size from a raw string, used for transfer-encoding: chunked.
pub fn hex_chunk_size(raw string) ?int {
	hex_part := raw.all_before(';').trim_space()
	if hex_part == '' {
		return none
	}
	mut size := 0
	for ch in hex_part {
		mut value := -1
		if ch >= `0` && ch <= `9` {
			value = int(ch - `0`)
		} else if ch >= `a` && ch <= `f` {
			value = 10 + int(ch - `a`)
		} else if ch >= `A` && ch <= `F` {
			value = 10 + int(ch - `A`)
		} else {
			return none
		}
		size = (size * 16) + value
	}
	return size
}

// ── JSON Extraction ──

pub fn is_stream_request(body string) bool {
	parsed := json2.decode[json2.Any](body) or { return false }
	root := parsed.as_map()
	stream_any := root['stream'] or { return false }
	return stream_any.bool()
}

pub fn request_model(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	return (root['model'] or { json2.Any('') }).str()
}

pub fn response_id_from_body(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	if (root['object'] or { json2.Any('') }).str() != 'response' {
		return ''
	}
	return (root['id'] or { json2.Any('') }).str().trim_space()
}

pub fn response_status_from_body(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	return (root['status'] or { json2.Any('') }).str()
}

pub fn response_id_from_relative(relative string) string {
	path := relative.all_before('?')
	prefix := '/responses/'
	if !path.starts_with(prefix) {
		return ''
	}
	rest := path[prefix.len..]
	if rest.trim_space() == '' {
		return ''
	}
	return rest.split('/')[0].trim_space()
}

pub fn replace_model_in_body(body string, upstream_model string) string {
	if upstream_model.trim_space() == '' {
		return body
	}
	parsed := json2.decode[json2.Any](body) or { return body }
	mut root := parsed.as_map()
	root['model'] = json2.Any(upstream_model)
	return json2.Any(root).json_str()
}

pub fn json_string_field(obj map[string]json2.Any, key string, default_val string) string {
	value := obj[key] or { return default_val }
	text := value.str()
	if text == '' {
		return default_val
	}
	return text
}

pub fn json_string_map_field(obj map[string]json2.Any, key string) map[string]string {
	mut out := map[string]string{}
	value := obj[key] or { return out }
	for name, item in value.as_map() {
		out[name] = item.str()
	}
	return out
}

pub fn plugin_not_handled(raw string) bool {
	parsed := json2.decode[json2.Any](raw) or { return false }
	root := parsed.as_map()
	for key in ['not_handled', 'notHandled'] {
		value := root[key] or { continue }
		if value.bool() {
			return true
		}
	}
	return false
}

// ── HTTP Helpers ──

pub fn response_content_type(header http.Header, fallback string) string {
	return header.get(.content_type) or { fallback }
}

// ── Plan Validation ──

pub fn plan_error(code string, message string) IError {
	return error('${code}:${message}')
}

pub fn plan_error_code(err_msg string) string {
	if err_msg.starts_with('openai_plugin_plan_') && err_msg.contains(':') {
		return err_msg.all_before(':')
	}
	if err_msg.starts_with('openai_plugin_') && err_msg.contains(':') {
		return err_msg.all_before(':')
	}
	if err_msg.starts_with('unknown backend ') {
		return 'openai_plugin_plan_unknown_backend'
	}
	return 'model_not_found'
}

pub fn plan_error_message(err_msg string) string {
	if (err_msg.starts_with('openai_plugin_plan_') || err_msg.starts_with('openai_plugin_'))
		&& err_msg.contains(':') {
		return err_msg.all_after(':')
	}
	return err_msg
}

pub fn validate_plan_method(raw string) !string {
	method := raw.trim_space().to_upper()
	if method == '' {
		return 'POST'
	}
	if method in ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'] {
		return method
	}
	return plan_error('openai_plugin_plan_invalid_method', 'unsupported upstream method ${method}')
}

pub fn validate_plan_path(raw string) !string {
	path := raw.trim_space()
	if path == '' {
		return '/chat/completions'
	}
	if !path.starts_with('/') {
		return plan_error('openai_plugin_plan_invalid_path', 'upstream path must start with /')
	}
	if path.contains('\r') || path.contains('\n') {
		return plan_error('openai_plugin_plan_invalid_path', 'upstream path must not contain newlines')
	}
	return path
}

pub fn validate_stream_mode(raw string) !string {
	mode := raw.trim_space()
	if mode == '' {
		return 'passthrough'
	}
	if mode in ['passthrough', 'mapped', 'executor'] {
		return mode
	}
	return plan_error('openai_plugin_plan_unsupported_stream_mode', 'unsupported stream_mode ${mode}')
}

pub fn validate_response_codec(raw string, stream_mode string) !string {
	codec := raw.trim_space()
	if codec == '' {
		return if stream_mode == 'mapped' { 'ndjson' } else { 'sse' }
	}
	if codec in ['sse', 'json', 'ndjson', 'text'] {
		return codec
	}
	return plan_error('openai_plugin_plan_unsupported_response_codec', 'unsupported response_codec ${codec}')
}

pub fn validate_output_protocol(raw string, stream_mode string) !string {
	protocol := raw.trim_space()
	if protocol == '' {
		return 'openai.chat.completion'
	}
	if stream_mode == 'mapped' && protocol != 'openai.chat.completion' {
		return plan_error('openai_plugin_plan_unsupported_output_protocol', 'unsupported output_protocol ${protocol}')
	}
	return protocol
}

pub fn validate_mapper(raw string) !string {
	mapper := raw.trim_space()
	if mapper == '' {
		return 'builtin'
	}
	if mapper in ['builtin', 'plugin'] {
		return mapper
	}
	return plan_error('openai_plugin_plan_unsupported_mapper', 'unsupported mapper ${mapper}')
}

pub fn sanitize_plan_headers(headers map[string]string) map[string]string {
	mut out := map[string]string{}
	for name, value in headers {
		lower := name.trim_space().to_lower()
		if lower == ''
			|| lower in ['connection', 'content-length', 'transfer-encoding', 'host', 'server', 'upgrade', 'proxy-connection', 'keep-alive', 'te', 'trailer'] {
			continue
		}
		if lower.contains('\r') || lower.contains('\n') || value.contains('\r')
			|| value.contains('\n') {
			continue
		}
		out[name] = value
	}
	return out
}
