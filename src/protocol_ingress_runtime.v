module main

import veb

struct ProtocolIngressRuntime {
	openai OpenaiProtocolIngressPort
	mcp    McpProtocolIngressPort
}

fn (hub ProtocolRuntimeHub) try_route_http(mut app App, mut ctx Context, method string, target string) ?veb.Result {
	req := new_protocol_http_request(ctx, method, target)
	return hub.ingress.try_route_http_request(mut app, mut ctx, req)
}

fn (rt ProtocolIngressRuntime) try_route_http_request(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if result := rt.openai.try_route_http(mut app, mut ctx, req) {
		return result
	}
	if result := rt.mcp.try_route_http(mut app, mut ctx, req) {
		return result
	}
	return none
}
