module openai

import config
import json
import net.http
import os
import x.json2

// ── JSON Extraction ──

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

// ── HTTP Helpers ──

pub fn response_content_type(header http.Header, fallback string) string {
	return header.get(.content_type) or { fallback }
}

pub fn OpenAIHttp.response_content_type(header http.Header, fallback string) string {
	return response_content_type(header, fallback)
}

// ── Error Helpers ──

pub fn error_body_json(code string, message string, typ string) string {
	return json.encode(OpenAIErrorResponse{
		error: OpenAIErrorBody{
			message: message
			typ:     typ
			code:    code
		}
	})
}

pub fn OpenAIErrorResponse.body_json(code string, message string, typ string) string {
	return error_body_json(code, message, typ)
}

pub fn upstream_error_from_body(body string, fallback_code string, fallback_message string) (string, string, string) {
	parsed := json2.decode[json2.Any](body) or {
		trimmed := body.trim_space()
		return fallback_code, if trimmed == '' {
			fallback_message
		} else {
			trimmed
		}, 'server_error'
	}
	root := parsed.as_map()
	if error_any := root['error'] {
		error_obj := error_any.as_map()
		message := (error_obj['message'] or { json2.Any(fallback_message) }).str()
		code := (error_obj['code'] or { json2.Any(fallback_code) }).str()
		typ := (error_obj['type'] or { json2.Any('server_error') }).str()
		return if code == '' { fallback_code } else { code }, if message == '' {
			fallback_message
		} else {
			message
		}, if typ == '' {
			'server_error'
		} else {
			typ
		}
	}
	message := (root['message'] or { json2.Any(fallback_message) }).str()
	code := (root['code'] or { json2.Any(fallback_code) }).str()
	typ := (root['type'] or { json2.Any('server_error') }).str()
	return if code == '' { fallback_code } else { code }, if message == '' {
		fallback_message
	} else {
		message
	}, if typ == '' {
		'server_error'
	} else {
		typ
	}
}

pub fn OpenAIErrorParser.upstream_error_from_body(body string, fallback_code string, fallback_message string) (string, string, string) {
	return upstream_error_from_body(body, fallback_code, fallback_message)
}

// ── URL / Auth / HTTP Method ──

pub fn build_upstream_url(base_url string, relative string) string {
	mut base := base_url.trim_space()
	for base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return '${base}${relative}'
}

pub fn OpenAIBackendAccess.upstream_url(base_url string, relative string) string {
	return build_upstream_url(base_url, relative)
}

pub fn backend_auth_key(backend config.OpenAIBackendConfig) string {
	if backend.api_key.trim_space() != '' {
		return backend.api_key.trim_space()
	}
	if backend.api_key_env.trim_space() != '' {
		return os.getenv(backend.api_key_env.trim_space())
	}
	return ''
}

pub fn OpenAIBackendAccess.auth_key(backend config.OpenAIBackendConfig) string {
	return backend_auth_key(backend)
}

pub fn http_method(raw string, fallback string) http.Method {
	return match raw.trim_space().to_upper() {
		'GET' {
			.get
		}
		'PUT' {
			.put
		}
		'PATCH' {
			.patch
		}
		'DELETE' {
			.delete
		}
		'HEAD' {
			.head
		}
		else {
			match fallback.trim_space().to_upper() {
				'HEAD' { .head }
				else { .post }
			}
		}
	}
}

pub fn OpenAIHttp.method(raw string, fallback string) http.Method {
	return http_method(raw, fallback)
}

// ── Usage / JSON Utilities ──

pub fn int_field(obj map[string]json2.Any, key string) int {
	value := obj[key] or { return 0 }
	return value.int()
}

pub fn usage_from_map(root map[string]json2.Any) map[string]int {
	if usage_any := root['usage'] {
		usage := usage_any.as_map()
		prompt := int_field(usage, 'prompt_tokens')
		completion := int_field(usage, 'completion_tokens')
		total_raw := int_field(usage, 'total_tokens')
		total := if total_raw > 0 { total_raw } else { prompt + completion }
		if prompt > 0 || completion > 0 || total > 0 {
			return {
				'prompt_tokens':     prompt
				'completion_tokens': completion
				'total_tokens':      total
			}
		}
	}
	prompt := int_field(root, 'prompt_tokens') + int_field(root, 'prompt_eval_count')
	completion := int_field(root, 'completion_tokens') + int_field(root, 'eval_count')
	total_raw := int_field(root, 'total_tokens')
	total := if total_raw > 0 { total_raw } else { prompt + completion }
	if prompt > 0 || completion > 0 || total > 0 {
		return {
			'prompt_tokens':     prompt
			'completion_tokens': completion
			'total_tokens':      total
		}
	}
	return map[string]int{}
}

pub fn merge_usage(mut acc map[string]int, usage map[string]int) {
	for key, value in usage {
		if value > 0 {
			acc[key] = value
		}
	}
}

pub fn OpenAIUsage.merge(mut acc map[string]int, usage map[string]int) {
	merge_usage(mut acc, usage)
}

pub fn usage_json_obj(usage map[string]int) map[string]json2.Any {
	return {
		'prompt_tokens':     json2.Any(usage['prompt_tokens'])
		'completion_tokens': json2.Any(usage['completion_tokens'])
		'total_tokens':      json2.Any(usage['total_tokens'])
	}
}

pub fn OpenAIUsage.json_obj(usage map[string]int) map[string]json2.Any {
	return usage_json_obj(usage)
}
