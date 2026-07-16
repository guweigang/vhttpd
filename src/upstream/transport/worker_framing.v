module transport

import json
import net.http
import net.unix
import net.urllib

// ── Frame I/O ──

pub fn write_frame(mut conn unix.StreamConn, payload string) ! {
	WorkerFrameCodec.write(mut conn, payload)!
}

pub fn WorkerFrameCodec.write(mut conn unix.StreamConn, payload string) ! {
	size := payload.len
	header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff),
		u8(size & 0xff)]
	conn.write_ptr(&header[0], 4)!
	conn.write_string(payload)!
}

pub fn read_exact(mut conn unix.StreamConn, size int) ![]u8 {
	return WorkerFrameCodec.read_exact(mut conn, size)!
}

pub fn WorkerFrameCodec.read_exact(mut conn unix.StreamConn, size int) ![]u8 {
	mut out := []u8{len: size}
	mut read := 0
	for read < size {
		n := conn.read(mut out[read..])!
		if n <= 0 {
			return error('unexpected EOF')
		}
		read += n
	}
	return out
}

pub fn read_frame(mut conn unix.StreamConn) !string {
	return WorkerFrameCodec.read(mut conn)!
}

pub fn WorkerFrameCodec.read(mut conn unix.StreamConn) !string {
	body := WorkerFrameCodec.read_bytes(mut conn)!
	return body.bytestr()
}

pub fn read_frame_bytes(mut conn unix.StreamConn) ![]u8 {
	return WorkerFrameCodec.read_bytes(mut conn)!
}

pub fn WorkerFrameCodec.read_bytes(mut conn unix.StreamConn) ![]u8 {
	header := WorkerFrameCodec.read_exact(mut conn, 4)!
	size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
	size := int(size_u32)
	if size <= 0 || size > 16 * 1024 * 1024 {
		return error('invalid frame size ${size}')
	}
	return WorkerFrameCodec.read_exact(mut conn, size)!
}

// ── URL / HTTP helpers ──

pub fn normalize_path(path string) string {
	return WorkerHttpRequestCodec.normalize_path(path)
}

pub fn WorkerHttpRequestCodec.normalize_path(path string) string {
	if path.len == 0 {
		return '/'
	}
	if path.starts_with('/') {
		return path
	}
	return '/${path}'
}

pub fn normalize_request_target(raw_path string) (string, string) {
	return WorkerHttpRequestCodec.normalize_request_target(raw_path)
}

pub fn WorkerHttpRequestCodec.normalize_request_target(raw_path string) (string, string) {
	path := WorkerHttpRequestCodec.normalize_path(raw_path)
	if !path.contains('?') {
		return path, ''
	}
	base := WorkerHttpRequestCodec.normalize_path(path.all_before('?'))
	query := path.all_after('?')
	return base, query
}

pub fn parse_query_map(query_str string) map[string]string {
	return WorkerHttpRequestCodec.parse_query_map(query_str)
}

pub fn WorkerHttpRequestCodec.parse_query_map(query_str string) map[string]string {
	mut out := map[string]string{}
	if query_str == '' {
		return out
	}
	values := urllib.parse_query(query_str) or { return out }
	for key, entries in values.to_map() {
		if entries.len == 0 {
			out[key] = ''
			continue
		}
		out[key] = entries[0]
	}
	return out
}

pub fn header_map_from_request(req http.Request) map[string]string {
	return WorkerHttpRequestCodec.header_map_from_request(req)
}

pub fn WorkerHttpRequestCodec.header_map_from_request(req http.Request) map[string]string {
	mut out := map[string]string{}
	for key in req.header.keys() {
		values := req.header.custom_values(key)
		if values.len == 0 {
			continue
		}
		lower_key := key.to_lower()
		if lower_key == 'cookie' {
			out[lower_key] = values.join('; ')
		} else {
			out[lower_key] = values.join(', ')
		}
	}
	return out
}

pub fn cookie_map_from_request(req http.Request) map[string]string {
	return WorkerHttpRequestCodec.cookie_map_from_request(req)
}

pub fn WorkerHttpRequestCodec.cookie_map_from_request(req http.Request) map[string]string {
	mut out := map[string]string{}
	for cookie in http.read_cookies(req.header, '') {
		out[cookie.name] = cookie.value
	}
	return out
}

pub fn server_map_from_request(req http.Request, remote_addr string) map[string]string {
	return WorkerHttpRequestCodec.server_map_from_request(req, remote_addr)
}

pub fn WorkerHttpRequestCodec.server_map_from_request(req http.Request, remote_addr string) map[string]string {
	mut host := req.host
	mut port := ''
	if host == '' {
		host = req.header.get(.host) or { '' }
	}
	if host != '' {
		host, port = urllib.split_host_port(host)
	}
	return {
		'host':        host
		'port':        port
		'remote_addr': remote_addr
		'method':      req.method.str()
		'url':         req.url
	}
}

// ── Worker request encoding ──

pub fn encode_worker_request(method string, path string, req http.Request, remote_addr string, trace_id string, req_id string) string {
	return WorkerHttpRequestCodec.encode_request(method, path, req, remote_addr, trace_id, req_id)
}

pub fn WorkerHttpRequestCodec.encode_request(method string, path string, req http.Request, remote_addr string, trace_id string, req_id string) string {
	normalized_path, query_string := WorkerHttpRequestCodec.normalize_request_target(path)
	query := WorkerHttpRequestCodec.parse_query_map(query_string)
	mut headers := WorkerHttpRequestCodec.header_map_from_request(req)
	if headers['x-request-id'] == '' {
		headers['x-request-id'] = req_id
	}
	headers['x-vhttpd-trace-id'] = trace_id
	cookies := WorkerHttpRequestCodec.cookie_map_from_request(req)
	server := WorkerHttpRequestCodec.server_map_from_request(req, remote_addr)
	host := server['host'] or { req.host }
	port := server['port'] or { '' }
	scheme := req.header.get(.x_forwarded_proto) or { 'http' }
	return json.encode(WorkerRequestPayload{
		id:               trace_id
		method:           method.to_upper()
		path:             normalized_path
		body:             req.data
		scheme:           scheme
		host:             host
		port:             port
		protocol_version: req.version.str().trim_left('HTTP/')
		remote_addr:      remote_addr
		query:            query
		headers:          headers
		cookies:          cookies
		attributes:       map[string]string{}
		server:           server
		uploaded_files:   []string{}
	})
}

// ── Stream / Upstream plan decoding ──

pub fn try_decode_stream_start(raw string) ?WorkerStreamFrame {
	return WorkerStreamFrame.try_decode_start(raw)
}

pub fn WorkerStreamFrame.try_decode_start(raw string) ?WorkerStreamFrame {
	frame := json.decode(WorkerStreamFrame, raw) or { return none }
	if frame.mode == 'stream' && frame.event == 'start' {
		return frame
	}
	return none
}

pub fn try_decode_upstream_plan(raw string) ?WorkerUpstreamPlanFrame {
	return WorkerUpstreamPlanFrame.try_decode_start(raw)
}

pub fn WorkerUpstreamPlanFrame.try_decode_start(raw string) ?WorkerUpstreamPlanFrame {
	frame := json.decode(WorkerUpstreamPlanFrame, raw) or { return none }
	if ((frame.mode == 'stream' && frame.strategy == 'upstream_plan')
		|| frame.mode == 'upstream_plan') && frame.event == 'start' {
		return frame
	}
	return none
}
