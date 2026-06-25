module main

import dispatch
import log
import os
import veb

struct MatchedHttpPipelineRequest {
	method            string
	path              string
	normalized_target string
	query             map[string]string
	body_on_head      string
	remote_addr       string
	req_id            string
	trace_id          string
	start_ms          i64
}

struct HttpPipelineRuntime {}

fn HttpPipelineRuntime.try_handle_matched_pipeline(mut app App, mut ctx Context, rule RuntimeRouteRule, req MatchedHttpPipelineRequest, headers map[string]string) ?veb.Result {
	header_name := route_required_headers_failure(rule, headers)
	if header_name != '' {
		log.warn('[http] ⇠ pipeline required header failed method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.req_id} pipeline=${rule.pipeline_id} header=${header_name}')
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.reject_adapter('route/required_header',
			403, header_name, 'route_required_header'))
		return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
			req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
			req.trace_id, req.start_ms, rule, mut terminal_adapter)
	}
	query_name := route_denied_query_failure(rule, req.query)
	if query_name != '' {
		log.warn('[http] ⇠ pipeline denied query failed method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.req_id} pipeline=${rule.pipeline_id} query=${query_name}')
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.reject_adapter('route/denied_query',
			403, query_name, 'route_denied_query'))
		return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
			req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
			req.trace_id, req.start_ms, rule, mut terminal_adapter)
	}
	if rule.max_body_bytes > 0 && ctx.req.data.len > rule.max_body_bytes {
		log.warn('[http] ⇠ pipeline max body exceeded method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.req_id} pipeline=${rule.pipeline_id} body_len=${ctx.req.data.len} max_body_bytes=${rule.max_body_bytes}')
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.reject_adapter('route/payload_too_large',
			413, 'max_body_bytes', 'payload_too_large'))
		return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
			req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
			req.trace_id, req.start_ms, rule, mut terminal_adapter)
	}
	if rule.status > 0 {
		mut outcome_headers := map[string]string{}
		if rule.location != '' {
			outcome_headers['location'] = rule.location
		}
		terminal_body := if rule.status in [301, 302, 307, 308] && rule.body == '' {
			'Redirecting...'
		} else {
			rule.body
		}
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/status',
			rule.status, outcome_headers, terminal_body))
		log.info('[http] ⇠ pipeline terminal status=${rule.status} trace_id=${req.trace_id} pipeline=${rule.pipeline_id}')
		return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
			req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
			req.trace_id, req.start_ms, rule, mut terminal_adapter)
	}
	if rule.executor == 'static' {
		if req.method.to_upper() !in ['GET', 'HEAD'] {
			mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/static_method',
				405, map[string]string{}, 'Method Not Allowed'))
			return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
				req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
				req.trace_id, req.start_ms, rule, mut terminal_adapter)
		}
		root_dir := app.http_routing.static_root(rule)
		file_path := os.join_path(root_dir, req.normalized_target.trim_left('/'))
		if os.exists(file_path) && !os.is_dir(file_path) {
			mut file_headers := map[string]string{}
			if rule.cache_control.trim_space() != '' {
				file_headers['cache-control'] = rule.cache_control
			}
			log.info('[http] ⇠ pipeline static file=${file_path} trace_id=${req.trace_id} pipeline=${rule.pipeline_id}')
			outcome := dispatch.file_outcome(file_path, file_headers)
			return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request_for_rule(req.method,
				req.path, req.path, req.body_on_head, req.remote_addr, req.req_id, req.trace_id,
				req.start_ms, rule), outcome, rule)
		}
		log.warn('[http] ⇠ pipeline static file not found path=${file_path} trace_id=${req.trace_id} pipeline=${rule.pipeline_id}')
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/static_not_found',
			404, map[string]string{}, 'Not Found'))
		return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
			req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
			req.trace_id, req.start_ms, rule, mut terminal_adapter)
	}
	if rule.executor == 'upload' {
		return handle_upload_route(mut app, mut ctx, rule, req.method, req.normalized_target,
			req.req_id, req.trace_id, req.start_ms, req.query, req.body_on_head, req.remote_addr)
	}
	if rule.executor == 'none' {
		log.info('[http] ⇠ pipeline none (block) trace_id=${req.trace_id} pipeline=${rule.pipeline_id}')
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/none',
			404, map[string]string{}, 'Not Found'))
		return render_http_terminal_adapter(mut app, mut ctx, req.method, req.path,
			req.normalized_target, req.query, req.body_on_head, req.remote_addr, req.req_id,
			req.trace_id, req.start_ms, rule, mut terminal_adapter)
	}
	return none
}
