module main

import upstream.transport
import time
import veb

struct ProtocolHttpRequest {
	method            string
	target            string
	normalized_target string
	request_id        string
	trace_id          string
	start_ms          i64
}

struct ProtocolIngressRuntime {}

fn (hub ProtocolRuntimeHub) try_route_http(mut app App, mut ctx Context, method string, target string) ?veb.Result {
	req := new_protocol_http_request(ctx, method, target)
	return hub.ingress.try_route_http_request(mut app, mut ctx, req)
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

fn (rt ProtocolIngressRuntime) try_route_http_request(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if result := rt.try_route_openai(mut app, mut ctx, req) {
		return result
	}
	if result := rt.try_route_mcp(mut app, mut ctx, req) {
		return result
	}
	return none
}

fn (rt ProtocolIngressRuntime) try_route_openai(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if result := app.openai_try_handle(mut ctx, req.method, req.target, req.request_id,
		req.trace_id, req.start_ms)
	{
		return result
	}
	return none
}

fn (rt ProtocolIngressRuntime) try_route_mcp(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if req.normalized_target != '/mcp' {
		return none
	}
	match req.method {
		'GET' { return app.mcp_get(mut ctx) }
		'POST' { return app.mcp_post(mut ctx) }
		'DELETE' { return app.mcp_delete(mut ctx) }
		else { return none }
	}
}
