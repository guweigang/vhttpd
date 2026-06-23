module dispatch

pub struct HttpMatch {
pub:
	methods []string
	hosts   []string
	paths   []string
	query   map[string]string
	headers map[string]string
}

pub fn http_exchange_matches(exchange Exchange, matcher HttpMatch) bool {
	if exchange.kind != .request {
		return false
	}
	request := request_payload(exchange) or { return false }
	if !match_string_list(matcher.methods, request.method, true) {
		return false
	}
	if !match_string_list(matcher.hosts, exchange.headers['host'], true) {
		return false
	}
	if !match_path_list(matcher.paths, request.path) {
		return false
	}
	for key, expected in matcher.query {
		actual := request.query[key] or { return false }
		if !match_value_pattern(expected, actual) {
			return false
		}
	}
	for key, expected in matcher.headers {
		actual := exchange.headers[key.to_lower()] or { return false }
		if !match_value_pattern(expected, actual) {
			return false
		}
	}
	return true
}

pub fn request_payload(exchange Exchange) ?RequestPayload {
	match exchange.payload {
		RequestPayload {
			return exchange.payload
		}
		else {
			return none
		}
	}
}

pub fn match_value_pattern(pattern string, value string) bool {
	if pattern == '*' {
		return value != ''
	}
	return pattern == value
}

pub fn match_path_pattern(pattern string, path string) bool {
	if pattern == '*' {
		return true
	}
	if pattern.starts_with('*') {
		return path.ends_with(pattern.all_after('*'))
	}
	if pattern.ends_with('*') {
		return path.starts_with(pattern.all_before_last('*'))
	}
	return path == pattern
}

fn match_string_list(patterns []string, value string, case_insensitive bool) bool {
	if patterns.len == 0 {
		return true
	}
	needle := if case_insensitive { value.to_upper() } else { value }
	for pattern in patterns {
		clean := pattern.trim_space()
		if clean == '*' {
			return true
		}
		candidate := if case_insensitive { clean.to_upper() } else { clean }
		if candidate == needle {
			return true
		}
	}
	return false
}

fn match_path_list(patterns []string, path string) bool {
	if patterns.len == 0 {
		return true
	}
	for pattern in patterns {
		if match_path_pattern(pattern, path) {
			return true
		}
	}
	return false
}
