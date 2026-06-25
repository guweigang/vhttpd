module main

import upstream.transport
import veb

struct ProtocolIngressRuntime {}

fn ProtocolIngressRuntime.try_route_http(mut app App, mut ctx Context, method string, target string) ?veb.Result {
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
