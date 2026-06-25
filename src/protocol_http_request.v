module main

import time
import upstream.transport

struct ProtocolHttpRequest {
	method            string
	target            string
	normalized_target string
	request_id        string
	trace_id          string
	start_ms          i64
}

fn new_protocol_http_request(ctx Context, method string, target string) ProtocolHttpRequest {
	request_path, _ := transport.normalize_request_target(target)
	return ProtocolHttpRequest{
		method:            method
		target:            target
		normalized_target: transport.normalize_path(request_path)
		request_id:        resolve_request_id(ctx, target)
		trace_id:          resolve_trace_id(ctx, target)
		start_ms:          time.now().unix_milli()
	}
}
