module main

import veb

struct McpProtocolIngressPort {}

fn (port McpProtocolIngressPort) try_route_http(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if req.normalized_target != '/mcp' {
		return none
	}
	match req.method {
		'GET' { return mcp_handle_get_http(mut app, mut ctx) }
		'POST' { return mcp_handle_post_http(mut app, mut ctx) }
		'DELETE' { return mcp_handle_delete_http(mut app, mut ctx) }
		else { return none }
	}
}
