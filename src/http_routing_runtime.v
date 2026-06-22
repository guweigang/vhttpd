module main

import cachex
import json
import net.http
import os
import regex
import upstream.transport
import worker

pub struct RuntimeRouteRule {
pub mut:
	match_method                 []string
	match_path                   []string
	match_path_regexp            string
	match_query                  map[string]string
	re                           regex.RE
	executor                     string
	rewrite                      string
	rewrite_strip_prefix         string
	root                         string
	cache_control                string
	response_cache_ttl_ms        int
	cache_bypass_cookie_patterns []string
	cache_ignore_cookie_patterns []string
	response_headers             map[string]string
	max_body_bytes               int
	required_headers             map[string]string
	denied_query_patterns        map[string]string
	upload_dir                   string
	on_completed                 string
	status                       int
	location                     string
	body                         string
}

struct EdgeCachedHttpResponse {
pub:
	status        int
	content_type  string
	cache_control string
	body          string
}

struct HttpRoutingRuntime {
pub:
	rules         []RuntimeRouteRule
	document_root string
	assets_root   string
	worker_root   string
}

fn HttpRoutingRuntime.new(rules []RuntimeRouteRule, assets_root string, worker_root string, primary_env map[string]string, additional_workers map[string]&worker.WorkerState) HttpRoutingRuntime {
	return HttpRoutingRuntime{
		rules:         rules
		document_root: http_routing_document_root(assets_root, primary_env, additional_workers)
		assets_root:   assets_root
		worker_root:   worker_root
	}
}

fn http_routing_document_root(assets_root string, primary_env map[string]string, additional_workers map[string]&worker.WorkerState) string {
	if assets_root != '' {
		return assets_root
	}
	for key in ['DOCUMENT_ROOT', 'VPHP_WP_ROOT'] {
		if root := primary_env[key] {
			if root != '' {
				return root
			}
		}
	}
	for _, state in additional_workers {
		for key in ['DOCUMENT_ROOT', 'VPHP_WP_ROOT'] {
			if root := state.worker_backend.env[key] {
				if root != '' {
					return root
				}
			}
		}
	}
	return ''
}

fn (rt HttpRoutingRuntime) match_http_request(method string, path string, query map[string]string) ?RuntimeRouteRule {
	for rule in rt.rules {
		if rule.matches_http_request(method, path, query) {
			return rule
		}
	}
	return none
}

fn (rt HttpRoutingRuntime) static_root(rule RuntimeRouteRule) string {
	if rule.root != '' {
		return rule.root
	}
	if rt.assets_root != '' {
		return rt.assets_root
	}
	return rt.worker_root
}

fn (rt HttpRoutingRuntime) response_cache_get(mut cache cachex.Runtime, rule RuntimeRouteRule, method string, target string) ?EdgeCachedHttpResponse {
	if rule.response_cache_ttl_ms <= 0 || !cache.enabled {
		return none
	}
	key := route_response_cache_key(method, target)
	raw := cache.get_value('edge.response', key) or { return none }
	return json.decode(EdgeCachedHttpResponse, raw) or { none }
}

fn (rt HttpRoutingRuntime) response_cache_set(mut cache cachex.Runtime, rule RuntimeRouteRule, method string, target string, cached EdgeCachedHttpResponse) {
	if rule.response_cache_ttl_ms <= 0 || !cache.enabled {
		return
	}
	key := route_response_cache_key(method, target)
	cache.set_value('edge.response', key, json.encode(cached), i64(rule.response_cache_ttl_ms))
}

fn match_path(pattern string, path string) bool {
	if pattern == '*' {
		return true
	}
	if pattern.starts_with('*') {
		suffix := pattern.all_after('*')
		return path.ends_with(suffix)
	}
	if pattern.ends_with('*') {
		prefix := pattern.all_before_last('*')
		return path.starts_with(prefix)
	}
	return path == pattern
}

fn match_query(pattern string, value string) bool {
	if pattern == '*' {
		return value != ''
	}
	return value == pattern
}

fn (r RuntimeRouteRule) matches(path string) bool {
	return r.matches_request(path, map[string]string{})
}

fn (r RuntimeRouteRule) matches_request(path string, query map[string]string) bool {
	return r.matches_http_request('', path, query)
}

fn (r RuntimeRouteRule) matches_http_request(method string, path string, query map[string]string) bool {
	if r.match_method.len > 0 {
		upper_method := method.to_upper()
		mut method_matched := false
		for item in r.match_method {
			clean := item.trim_space().to_upper()
			if clean == '*' || clean == upper_method {
				method_matched = true
				break
			}
		}
		if !method_matched {
			return false
		}
	}
	mut path_matched := false
	if r.match_path_regexp != '' {
		mut re_mutable := r.re
		start, _ := re_mutable.find(path)
		if start >= 0 {
			path_matched = true
		}
	}
	if !path_matched && r.match_path.len > 0 {
		for p in r.match_path {
			if match_path(p, path) {
				path_matched = true
				break
			}
		}
	}
	if !path_matched {
		return false
	}
	for key, expected in r.match_query {
		actual := query[key] or { return false }
		if !match_query(expected, actual) {
			return false
		}
	}
	return true
}

fn (r RuntimeRouteRule) rewrite_target(original_target string) string {
	if r.rewrite == '' {
		return original_target
	}
	request_path, query_string := transport.normalize_request_target(original_target)
	normalized_path := transport.normalize_path(request_path)
	mut remainder := normalized_path
	if r.rewrite_strip_prefix != '' && normalized_path.starts_with(r.rewrite_strip_prefix) {
		remainder = normalized_path[r.rewrite_strip_prefix.len..]
		if remainder == '' {
			remainder = '/'
		}
	}
	if !remainder.starts_with('/') {
		remainder = '/' + remainder
	}
	mut target := r.rewrite
	target = target.replace('$path_remainder', remainder)
	target = target.replace('$path', normalized_path)
	if target.contains('$query') {
		target = target.replace('$query', query_string)
	} else if query_string != '' {
		sep := if target.contains('?') { '&' } else { '?' }
		target += sep + query_string
	}
	return target
}

fn directory_slash_redirect_location(document_root string, normalized_path string, query_string string) ?string {
	if document_root == '' || normalized_path == '/' || normalized_path.ends_with('/') {
		return none
	}
	file_path := os.join_path(document_root, normalized_path.trim_left('/'))
	if !os.is_dir(file_path) {
		return none
	}
	mut location := normalized_path + '/'
	if query_string != '' {
		location += '?' + query_string
	}
	return location
}

fn route_response_cache_key(method string, target string) string {
	request_path, query_string := transport.normalize_request_target(target)
	normalized_path := transport.normalize_path(request_path)
	if query_string == '' {
		return '${method.to_upper()}:${normalized_path}'
	}
	return '${method.to_upper()}:${normalized_path}?${query_string}'
}

fn route_response_cache_cookie_pattern_matches(name string, pattern string) bool {
	clean_name := name.trim_space()
	clean_pattern := pattern.trim_space()
	if clean_pattern == '' {
		return false
	}
	if clean_pattern == '*' {
		return true
	}
	if !clean_pattern.contains('*') {
		return clean_name == clean_pattern
	}
	parts := clean_pattern.split('*')
	mut pos := 0
	if !clean_pattern.starts_with('*') {
		prefix := parts[0]
		if !clean_name.starts_with(prefix) {
			return false
		}
		pos = prefix.len
	}
	for idx, part in parts {
		if part == '' {
			continue
		}
		if idx == 0 && !clean_pattern.starts_with('*') {
			continue
		}
		found := clean_name[pos..].index(part) or { return false }
		pos += found + part.len
	}
	if !clean_pattern.ends_with('*') {
		suffix := parts[parts.len - 1]
		return clean_name.ends_with(suffix)
	}
	return true
}

fn route_response_cache_cookie_list_bypass_reason(cookie_header string, bypass_patterns []string, ignore_patterns []string) string {
	if cookie_header.trim_space() == '' {
		return ''
	}
	if bypass_patterns.len == 0 && ignore_patterns.len == 0 {
		return 'cookie'
	}
	for raw in cookie_header.split(';') {
		name := raw.all_before('=').trim_space()
		if name == '' {
			continue
		}
		mut ignored := false
		for pattern in ignore_patterns {
			if route_response_cache_cookie_pattern_matches(name, pattern) {
				ignored = true
				break
			}
		}
		if ignored {
			continue
		}
		for pattern in bypass_patterns {
			if route_response_cache_cookie_pattern_matches(name, pattern) {
				return 'cookie:${name}'
			}
		}
		return 'cookie:${name}'
	}
	return ''
}

fn route_response_cache_request_bypass_reason(rule RuntimeRouteRule, method string, req http.Request) string {
	if method.to_upper() !in ['GET', 'HEAD'] {
		return 'method'
	}
	headers := transport.header_map_from_request(req)
	if headers['authorization'] != '' {
		return 'authorization'
	}
	if headers['cookie'] != '' {
		return route_response_cache_cookie_list_bypass_reason(headers['cookie'],
			rule.cache_bypass_cookie_patterns, rule.cache_ignore_cookie_patterns)
	}
	return ''
}

fn route_response_cache_store_bypass_reason(resp transport.WorkerResponse) string {
	if resp.status != 200 {
		return 'status'
	}
	for name, value in resp.headers {
		lower := name.to_lower()
		if lower == 'set-cookie' {
			return 'set_cookie'
		}
		if lower == 'cache-control' {
			clean := value.to_lower()
			if clean.contains('no-store') {
				return 'no_store'
			}
			if clean.contains('no-cache') {
				return 'no_cache'
			}
			if clean.contains('private') {
				return 'private'
			}
			for directive in clean.split(',') {
				trimmed := directive.trim_space()
				if trimmed in ['max-age=0', 's-maxage=0'] {
					return trimmed.replace('-', '_').replace('=', '_')
				}
			}
		}
	}
	return ''
}

fn route_response_headers_have(headers map[string]string, name string) bool {
	expected := name.to_lower()
	for header_name, _ in headers {
		if header_name.to_lower() == expected {
			return true
		}
	}
	return false
}

fn apply_route_response_headers(mut ctx Context, rule RuntimeRouteRule) {
	for name, value in rule.response_headers {
		if name.trim_space() == '' {
			continue
		}
		ctx.set_custom_header(name, value) or {}
	}
}

fn route_required_headers_failure(rule RuntimeRouteRule, headers map[string]string) string {
	for name, expected in rule.required_headers {
		actual := headers[name.to_lower()] or { return name }
		if expected.trim_space() != '' && !match_query(expected, actual) {
			return name
		}
	}
	return ''
}

fn route_denied_query_failure(rule RuntimeRouteRule, query map[string]string) string {
	for name, pattern in rule.denied_query_patterns {
		actual := query[name] or { continue }
		if pattern.trim_space() == '' || match_query(pattern, actual) {
			return name
		}
	}
	return ''
}
