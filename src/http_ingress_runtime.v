module main

import dispatch
import executor
import log
import time
import upstream.transport
import veb

struct HttpIngressRuntime {}

fn HttpIngressRuntime.route(mut app App, mut ctx Context, method string, path string) veb.Result {
	start_ms := time.now().unix_milli()
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	if method == 'GET' {
		log.info('[http] route proxy_get path=${path} url=${ctx.req.url}')
	} else if method == 'POST' {
		log.info('[http] route proxy_post path=${path} url=${ctx.req.url} body_len=${ctx.req.data.len}')
	}
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, method, target, req_id, trace_id, start_ms) {
		return result
	}
	request_path, _ := transport.normalize_request_target(target)
	normalized_target := transport.normalize_path(request_path)
	if normalized_target == '/mcp' {
		match method {
			'GET' { return app.mcp_get(mut ctx) }
			'POST' { return app.mcp_post(mut ctx) }
			'DELETE' { return app.mcp_delete(mut ctx) }
			else {}
		}
	}
	if !app.has_http_logic_executor() {
		remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
		return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
			target, target, '', remote_addr, req_id, trace_id, start_ms), dispatch.response_outcome(404,
			map[string]string{}, 'Not Found'), none)
	}
	return HttpIngressRuntime.handle(mut app, mut ctx, method, target, '')
}

fn proxy_worker_response(mut app App, mut ctx Context, method string, path string, body_on_head string) veb.Result {
	return HttpIngressRuntime.handle(mut app, mut ctx, method, path, body_on_head)
}

fn HttpIngressRuntime.handle(mut app App, mut ctx Context, method string, path string, body_on_head string) veb.Result {
	start_ms := time.now().unix_milli()
	if is_websocket_upgrade(ctx.req) {
		return proxy_worker_websocket(mut app, mut ctx, method, path)
	}
	apply_data_plane_scheme(mut ctx, app.lifecycle.data_plane_scheme)
	remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)

	request_path, query_string := transport.normalize_request_target(path)
	normalized_target := transport.normalize_path(request_path)
	query := transport.parse_query_map(query_string)
	headers := transport.header_map_from_request(ctx.req)

	if method.to_upper() in ['GET', 'HEAD'] {
		if location := app.pipelines.http_directory_slash_redirect(normalized_target, query_string) {
			log.info('[http] ⇠ directory slash redirect location=${location} trace_id=${trace_id}')
			return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
				path, path, body_on_head, remote_addr, req_id, trace_id, start_ms), dispatch.response_outcome(301, {
				'location': location
			}, 'Redirecting to ${location}'), none)
		}
	}

	// 1. Match the compiled RuntimePlan pipeline for this HTTP exchange.
	matched_rule := app.pipelines.match_http_request(HttpPipelineMatchRequest{
		method:            method
		normalized_target: normalized_target
		query:             query
		headers:           headers
		body:              ctx.req.data
		remote_addr:       remote_addr
		req_id:            req_id
		trace_id:          trace_id
		start_ms:          start_ms
	})

	if rule := matched_rule {
		if result := app.pipelines.try_handle_matched_http(mut app, mut ctx, rule, MatchedHttpPipelineRequest{
			method:            method
			path:              path
			normalized_target: normalized_target
			query:             query
			body_on_head:      body_on_head
			remote_addr:       remote_addr
			req_id:            req_id
			trace_id:          trace_id
			start_ms:          start_ms
		}, headers)
		{
			return result
		}
	}

	dispatch_plan := app.pipelines.http_dispatch_plan(matched_rule, path)
	ingress_req := app.pipelines.http_ingress_request(method, path, dispatch_plan, body_on_head,
		remote_addr, req_id, trace_id, start_ms)
	if cached_hit := app.pipelines.http_response_cache_hit(mut app.transport.cache, dispatch_plan,
		method, ctx.req) {
		return HttpResponseRuntime.cache_hit(mut app, mut ctx, ingress_req, cached_hit.cached,
			cached_hit.rule)
	}

	// 3. 动态切换活动的后端执行器
	mut engine_selection := app.engines.dispatch_selection(dispatch_plan.executor)

	log.info('[http] ⇢ dispatch method=${method.to_upper()} path=${path} target=${dispatch_plan.target} trace_id=${trace_id} request_id=${req_id} pipeline=${dispatch_plan.pipeline_id} body_len=${ctx.req.data.len} executor=${engine_selection.logic_executor.kind()} pool=${engine_selection.pool}')
	if engine_selection.stream_dispatch {
		if engine_selection.pool == 'main' {
			if result := HttpStreamRuntime.via_dispatch(mut app, mut ctx, method, dispatch_plan.target,
				req_id, trace_id, remote_addr)
			{
				return result
			}
		}
	}
	mut facade := app.as_facade()
	mut outcome := engine_selection.logic_executor.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
		method:        method
		path:          dispatch_plan.target
		original_path: path
		req:           ctx.req
		remote_addr:   remote_addr
		trace_id:      trace_id
		request_id:    req_id
	}) or { return HttpResponseRuntime.dispatch_error(mut app, mut ctx, ingress_req, err.msg()) }
	return HttpResponseRuntime.render(mut app, mut ctx, ingress_req, mut outcome, matched_rule)
}

fn apply_data_plane_scheme(mut ctx Context, scheme string) {
	normalized := if scheme.trim_space() == 'https' { 'https' } else { 'http' }
	ctx.req.header.set(.x_forwarded_proto, normalized)
	ctx.req.header.set_custom('X-Scheme', normalized) or {}
}
