module main

import veb

struct McpProtocolIngressPort {}

fn (port McpProtocolIngressPort) try_route_http(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
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
