module main

import time
import upstream.transport

struct ProtocolHttpRequest {
	method            string
	target            string
	normalized_target string
	query             map[string]string
	headers           map[string]string
	body              string
	request_id        string
	trace_id          string
	start_ms          i64
}

fn new_protocol_http_request(ctx Context, method string, target string) ProtocolHttpRequest {
	request_path, query_string := transport.normalize_request_target(target)
	return ProtocolHttpRequest{
		method:            method
		target:            target
		normalized_target: transport.normalize_path(request_path)
		query:             transport.parse_query_map(query_string)
		headers:           transport.header_map_from_request(ctx.req)
		body:              ctx.req.data
		request_id:        resolve_request_id(ctx, target)
		trace_id:          resolve_trace_id(ctx, target)
		start_ms:          time.now().unix_milli()
	}
}
