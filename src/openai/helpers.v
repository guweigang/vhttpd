module openai

import net.http
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
