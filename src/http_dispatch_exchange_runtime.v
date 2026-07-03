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

fn app_dispatch_services(mut app App, trace_id string) dispatch.RuntimeServices {
	return dispatch.RuntimeServices(AppDispatchServices{
		app:   &app
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

fn http_ingress_request_for_rule(method string, path string, dispatch_path string, body_on_head string, remote_addr string, request_id string, trace_id string, start_ms i64, matched_rule ?RuntimeRouteRule) HttpIngressRequest {
	mut req := http_ingress_request(method, path, dispatch_path, body_on_head, remote_addr,
		request_id, trace_id, start_ms)
	if rule := matched_rule {
		req.pipeline_id = rule.pipeline_id
		req.ingress_id = rule.ingress_id
	}
	return req
}

fn render_http_terminal_adapter(mut app App, mut ctx Context, method string, path string, normalized_target string, query map[string]string, body_on_head string, remote_addr string, request_id string, trace_id string, start_ms i64, matched_rule ?RuntimeRouteRule, mut adapter dispatch.EgressAdapter) veb.Result {
	exchange := http_exchange_from_context(ctx, method, normalized_target, query, remote_addr,
		request_id, trace_id, if rule := matched_rule { rule.ingress_id } else { '' }, if rule := matched_rule {
		rule.pipeline_id
	} else {
		''
	})
	mut services := noop_dispatch_services(trace_id)
	outcome := adapter.deliver(mut services, exchange) or {
		return HttpResponseRuntime.dispatch_error(mut app, mut ctx, http_ingress_request_for_rule(method,
			path, path, body_on_head, remote_addr, request_id, trace_id, start_ms, matched_rule),
			err.msg())
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request_for_rule(method,
		path, path, body_on_head, remote_addr, request_id, trace_id, start_ms, matched_rule),
		outcome, matched_rule)
}

fn run_http_route_transforms(mut app App, mut ctx Context, rule RuntimeRouteRule, req MatchedHttpPipelineRequest) ?veb.Result {
	if rule.transform_refs.len == 0 {
		return none
	}
	mut exchange := http_exchange_from_context(ctx, req.method, req.normalized_target, req.query,
		req.remote_addr, req.req_id, req.trace_id, rule.ingress_id, rule.pipeline_id)
	mut services := app_dispatch_services(mut app, req.trace_id)
	result := app.run_transform_refs(rule.transform_refs, mut services, mut exchange) or {
		return HttpResponseRuntime.dispatch_error(mut app, mut ctx, http_ingress_request_for_rule(req.method,
			req.path, req.path, req.body_on_head, req.remote_addr, req.req_id, req.trace_id,
			req.start_ms, rule), err.msg())
	}
	if !result.halted {
		return none
	}
	mut terminal_adapter := http_transform_action_terminal_adapter(result.action, result.transform)
	return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path, req.normalized_target,
		req.query, req.body_on_head, req.remote_addr, req.req_id, req.trace_id, req.start_ms,
		rule, mut terminal_adapter)
}

fn http_transform_action_terminal_adapter(action dispatch.TransformAction, transform_id string) dispatch.EgressAdapter {
	match action.kind {
		.respond {
			return dispatch.EgressAdapter(dispatch.fixed_response_adapter('transform/${transform_id}',
				if action.status > 0 { action.status } else { 200 }, map[string]string{},
				''))
		}
		.reject {
			return dispatch.EgressAdapter(dispatch.reject_adapter('transform/${transform_id}',
				if action.status > 0 { action.status } else { 403 }, action.error, action.error_class))
		}
		.drop {
			return dispatch.EgressAdapter(dispatch.fixed_response_adapter('transform/${transform_id}',
				204, map[string]string{}, ''))
		}
		.forward, .fanout {
			return dispatch.EgressAdapter(dispatch.reject_adapter('transform/${transform_id}',
				if action.status > 0 { action.status } else { 501 },
				'http transform action unsupported: ${action.kind}', 'http_transform_action_unsupported'))
		}
		.continue_pipeline {
			return dispatch.EgressAdapter(dispatch.fixed_response_adapter('transform/${transform_id}',
				200, map[string]string{}, ''))
		}
	}
}
