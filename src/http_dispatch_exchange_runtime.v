module main

import dispatch
import upstream.transport
import veb

fn http_exchange_from_context(ctx Context, method string, normalized_target string, query map[string]string, remote_addr string, request_id string, trace_id string, ingress string, pipeline string) dispatch.Exchange {
	return dispatch.http_request_exchange(dispatch.HttpIngressRequest{
		method:      method
		path:        normalized_target
		query:       query.clone()
		headers:     transport.header_map_from_request(ctx.req)
		body:        ctx.req.data
		remote_addr: remote_addr
		request_id:  request_id
		trace_id:    trace_id
		ingress:     ingress
		pipeline:    pipeline
	})
}

fn noop_dispatch_services(trace_id string) dispatch.RuntimeServices {
	return dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: trace_id
	})
}

fn http_ingress_request(method string, path string, dispatch_path string, body_on_head string, remote_addr string, request_id string, trace_id string, start_ms i64) HttpIngressRequest {
	return HttpIngressRequest{
		method:        method
		path:          path
		dispatch_path: dispatch_path
		body_on_head:  body_on_head
		remote_addr:   remote_addr
		request_id:    request_id
		trace_id:      trace_id
		start_ms:      start_ms
	}
}

fn render_http_terminal_adapter(mut app App, mut ctx Context, method string, path string, normalized_target string, query map[string]string, body_on_head string, remote_addr string, request_id string, trace_id string, start_ms i64, matched_rule ?RuntimeRouteRule, mut adapter dispatch.EgressAdapter) veb.Result {
	exchange := http_exchange_from_context(ctx, method, normalized_target, query, remote_addr,
		request_id, trace_id, '', '')
	mut services := noop_dispatch_services(trace_id)
	outcome := adapter.deliver(mut services, exchange) or {
		return HttpResponseRuntime.dispatch_error(mut app, mut ctx, http_ingress_request(method,
			path, path, body_on_head, remote_addr, request_id, trace_id, start_ms), err.msg())
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, body_on_head, remote_addr, request_id, trace_id, start_ms), outcome,
		matched_rule)
}
