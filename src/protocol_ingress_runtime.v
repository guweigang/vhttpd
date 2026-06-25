module main

import upstream.transport
import time
import veb

struct ProtocolIngressRuntime {}

fn (hub ProtocolRuntimeHub) try_route_http(mut app App, mut ctx Context, method string, target string) ?veb.Result {
	return hub.ingress.try_route_http(mut app, mut ctx, method, target)
}

fn (rt ProtocolIngressRuntime) try_route_http(mut app App, mut ctx Context, method string, target string) ?veb.Result {
	if result := rt.try_route_openai(mut app, mut ctx, method, target) {
		return result
	}
	if result := rt.try_route_mcp(mut app, mut ctx, method, target) {
		return result
	}
	return none
}

fn (rt ProtocolIngressRuntime) try_route_openai(mut app App, mut ctx Context, method string, target string) ?veb.Result {
	start_ms := time.now().unix_milli()
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, method, target, req_id, trace_id, start_ms) {
		return result
	}
	return none
}

fn (rt ProtocolIngressRuntime) try_route_mcp(mut app App, mut ctx Context, method string, target string) ?veb.Result {
	request_path, _ := transport.normalize_request_target(target)
	normalized_target := transport.normalize_path(request_path)
	if normalized_target != '/mcp' {
		return none
	}
	match method {
		'GET' { return app.mcp_get(mut ctx) }
		'POST' { return app.mcp_post(mut ctx) }
		'DELETE' { return app.mcp_delete(mut ctx) }
		else { return none }
	}
}
