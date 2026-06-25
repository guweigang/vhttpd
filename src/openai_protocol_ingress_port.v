module main

import veb

struct OpenaiProtocolIngressPort {}

fn (port OpenaiProtocolIngressPort) try_route_http(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if result := app.openai_try_handle(mut ctx, req.method, req.target, req.request_id,
		req.trace_id, req.start_ms)
	{
		return result
	}
	return none
}
