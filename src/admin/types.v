module admin

import json
import os

// ── Worker admin types ──

pub struct WorkerAdminStatus {
pub:
	id                int
	socket            string
	alive             bool
	pid               int
	rss_kb            i64
	draining          bool
	inflight_requests i64
	served_requests   i64
	restart_count     int
	next_retry_ts     i64
}

pub struct WorkerPoolAdminStatus {
pub:
	worker_autostart    bool
	worker_pool_size    int
	worker_rr_index     int
	worker_max_requests int
	worker_sockets      []string
	workers             []WorkerAdminStatus
}

pub struct WorkerAdminErrorResponse {
pub:
	error string
}

pub struct WorkerAdminRestartSingleResponse {
pub:
	ok     bool
	mode   string
	worker WorkerAdminStatus
}

pub struct WorkerAdminRestartAllResponse {
pub:
	ok        bool
	mode      string
	restarted int
}

// ── General admin response types ──

pub struct AdminErrorResponse {
pub:
	error string
}

pub struct AdminRestartSingleResponse {
pub:
	ok     bool
	mode   string
	worker WorkerAdminStatus
}

pub struct AdminRestartAllResponse {
pub:
	ok        bool
	mode      string
	restarted int
	force     bool
}

pub struct AdminFeishuSendResponse {
pub:
	ok         bool
	message_id string @[json: 'message_id']
	error      string
}

// ── Internal admin types ──

pub struct InternalAdminRequest {
pub:
	mode   string
	method string
	path   string
	query  map[string]string
	body   string
}

pub struct InternalAdminResponse {
pub:
	status  int
	headers map[string]string
	body    string
	error   string
}

// ── Query helpers ──

pub fn parse_boolish(raw string) bool {
	return raw.trim_space().to_lower() in ['1', 'true', 'yes', 'on']
}

pub fn query_limit(raw string, default_value int, max_value int) int {
	mut value := raw.trim_space().int()
	if value <= 0 {
		value = default_value
	}
	if value > max_value {
		value = max_value
	}
	return value
}

pub fn query_offset(raw string) int {
	mut value := raw.trim_space().int()
	if value < 0 {
		value = 0
	}
	return value
}

// ── Internal admin socket helpers ──

pub fn default_socket() string {
	return '/tmp/vhttpd_admin_${os.getpid()}.sock'
}

pub fn default_socket_for(label string) string {
	safe_label := sanitize_socket_label(label)
	if safe_label == '' {
		return default_socket()
	}
	return '/tmp/vhttpd_admin_${os.getpid()}_${safe_label}.sock'
}

pub fn sanitize_socket_label(raw string) string {
	if raw.trim_space() == '' {
		return ''
	}
	mut out := []u8{}
	for ch in raw.bytes() {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) || (ch >= `0` && ch <= `9`) {
			out << ch
			continue
		}
		if ch in [`-`, `_`, `.`, `:`] {
			out << `_`
		}
	}
	if out.len == 0 {
		return ''
	}
	return out.bytestr()
}

// ── Path normalization ──

fn normalize(raw string) string {
	if raw.len == 0 {
		return '/'
	}
	if raw.starts_with('/') {
		return raw
	}
	return '/${raw}'
}

pub fn normalize_admin_path(raw string) string {
	mut path := normalize(raw)
	if path == '/admin' {
		return '/'
	}
	if path.starts_with('/admin/') {
		path = path.all_after('/admin')
		if path == '' {
			return '/'
		}
	}
	return path
}

pub fn normalize_gateway_path(raw string) string {
	mut path := normalize(raw)
	if path == '/gateway' {
		return '/'
	}
	if path.starts_with('/gateway/') {
		path = path.all_after('/gateway')
		if path == '' {
			return '/'
		}
	}
	return path
}

// ── Response builders ──

pub fn json_response(body string) InternalAdminResponse {
	return InternalAdminResponse{
		status:  200
		headers: {
			'content-type': 'application/json; charset=utf-8'
		}
		body:    body
	}
}

pub fn error_response(status int, message string) InternalAdminResponse {
	return InternalAdminResponse{
		status:  status
		headers: {
			'content-type': 'application/json; charset=utf-8'
		}
		body:    json.encode({
			'error': message
		})
		error:   message
	}
}

pub fn bad_request(errmsg string) InternalAdminResponse {
	return error_response(400, errmsg)
}
