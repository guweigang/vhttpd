module main

import dispatch
import upstream.transport
import veb

fn mcp_http_ingress_request(method string, path string, remote_addr string, req_id string, trace_id string, start_ms i64) HttpIngressRequest {
	return HttpIngressRequest{
		method:        method
		path:          '/mcp'
		dispatch_path: transport.normalize_path(path)
		remote_addr:   remote_addr
		request_id:    req_id
		trace_id:      trace_id
		start_ms:      start_ms
	}
}

fn mcp_json_response(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64, status int, body string, error_class string, metadata map[string]string) veb.Result {
	mut headers := {
		'content-type': 'application/json; charset=utf-8'
	}
	mut event_metadata := {
		'response_mode': 'mcp'
	}
	if error_class != '' {
		headers['x-vhttpd-error-class'] = error_class
		event_metadata['error_class'] = error_class
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, mcp_http_ingress_request(method,
		path, ctx.ip(), req_id, trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status,
		headers, body), event_metadata), none)
}
