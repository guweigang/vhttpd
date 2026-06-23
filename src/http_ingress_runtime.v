module main

import dispatch
import executor
import log
import os
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
		ctx.res.set_status(.not_found)
		return ctx.text(if method == 'HEAD' { '' } else { 'Not Found' })
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

	if method.to_upper() in ['GET', 'HEAD'] {
		if location := directory_slash_redirect_location(app.http_routing.document_root,
			normalized_target, query_string)
		{
			ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
			ctx.set_custom_header('location', location) or {}
			ctx.res.set_status(.moved_permanently)
			log.info('[http] ⇠ directory slash redirect location=${location} trace_id=${trace_id}')
			return ctx.text(if method.to_upper() == 'HEAD' {
				''
			} else {
				'Redirecting to ${location}'
			})
		}
	}

	// 1. 匹配 Caddy 路由规则
	matched_rule := app.http_routing.match_http_request(method, normalized_target, query)

	if rule := matched_rule {
		headers := transport.header_map_from_request(ctx.req)
		header_name := route_required_headers_failure(rule, headers)
		if header_name != '' {
			log.warn('[http] ⇠ route required header failed method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} header=${header_name}')
			mut terminal_adapter := dispatch.EgressAdapter(dispatch.reject_adapter('route/required_header',
				403, header_name, 'route_required_header'))
			return render_http_terminal_adapter(mut app, mut ctx, method, path, normalized_target,
				query, body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut
				terminal_adapter)
		}
		query_name := route_denied_query_failure(rule, query)
		if query_name != '' {
			log.warn('[http] ⇠ route denied query failed method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} query=${query_name}')
			mut terminal_adapter := dispatch.EgressAdapter(dispatch.reject_adapter('route/denied_query',
				403, query_name, 'route_denied_query'))
			return render_http_terminal_adapter(mut app, mut ctx, method, path, normalized_target,
				query, body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut
				terminal_adapter)
		}
		if rule.max_body_bytes > 0 && ctx.req.data.len > rule.max_body_bytes {
			log.warn('[http] ⇠ route max body exceeded method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} body_len=${ctx.req.data.len} max_body_bytes=${rule.max_body_bytes}')
			mut terminal_adapter := dispatch.EgressAdapter(dispatch.reject_adapter('route/payload_too_large',
				413, 'max_body_bytes', 'payload_too_large'))
			return render_http_terminal_adapter(mut app, mut ctx, method, path, normalized_target,
				query, body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut
				terminal_adapter)
		}
		// 2.1 重定向与直接状态响应 (status > 0)
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
			log.info('[http] ⇠ route terminal status=${rule.status} trace_id=${trace_id}')
			return render_http_terminal_adapter(mut app, mut ctx, method, path, normalized_target,
				query, body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut
				terminal_adapter)
		}

		// 2.2 静态文件高性能直回
		if rule.executor == 'static' {
			if method.to_upper() !in ['GET', 'HEAD'] {
				ctx.res.set_status(.method_not_allowed)
				return ctx.text('Method Not Allowed')
			}
			root_dir := app.http_routing.static_root(rule)
			file_path := os.join_path(root_dir, normalized_target.trim_left('/'))
			if os.exists(file_path) && !os.is_dir(file_path) {
				if rule.cache_control.trim_space() != '' {
					ctx.set_custom_header('cache-control', rule.cache_control) or {}
				}
				apply_route_response_headers(mut ctx, rule)
				log.info('[http] ⇠ route static file=${file_path} trace_id=${trace_id}')
				return ctx.file(file_path)
			}
			log.warn('[http] ⇠ route static file not found path=${file_path} trace_id=${trace_id}')
			ctx.res.set_status(.not_found)
			return ctx.text('Not Found')
		}

		if rule.executor == 'upload' {
			return handle_upload_route(mut app, mut ctx, rule, method, normalized_target, req_id,
				trace_id, start_ms)
		}

		// 2.3 阻断返回
		if rule.executor == 'none' {
			log.info('[http] ⇠ route none (block) trace_id=${trace_id}')
			apply_route_response_headers(mut ctx, rule)
			ctx.res.set_status(.not_found)
			return ctx.text('Not Found')
		}
	}

	mut dispatch_path := path
	if rule := matched_rule {
		dispatch_path = rule.rewrite_target(path)
	}
	ingress_req := HttpIngressRequest{
		method:        method
		path:          path
		dispatch_path: dispatch_path
		body_on_head:  body_on_head
		remote_addr:   remote_addr
		request_id:    req_id
		trace_id:      trace_id
		start_ms:      start_ms
	}
	if rule := matched_rule {
		if rule.response_cache_ttl_ms > 0 && app.transport.cache.enabled
			&& route_response_cache_request_bypass_reason(rule, method, ctx.req) == '' {
			if cached := app.http_routing.response_cache_get(mut app.transport.cache, rule, method,
				dispatch_path)
			{
				return HttpResponseRuntime.cache_hit(mut app, mut ctx, ingress_req, cached, rule)
			}
		}
	}

	// 3. 动态切换活动的后端执行器
	requested_engine := if rule := matched_rule { rule.executor } else { '' }
	mut engine_selection := app.engines.dispatch_selection(requested_engine)

	log.info('[http] ⇢ dispatch method=${method.to_upper()} path=${path} target=${dispatch_path} trace_id=${trace_id} request_id=${req_id} body_len=${ctx.req.data.len} executor=${engine_selection.logic_executor.kind()} pool=${engine_selection.pool}')
	if engine_selection.stream_dispatch {
		if engine_selection.pool == 'main' {
			if result := HttpStreamRuntime.via_dispatch(mut app, mut ctx, method, dispatch_path,
				req_id, trace_id, remote_addr)
			{
				return result
			}
		}
	}
	mut facade := app.as_facade()
	mut outcome := engine_selection.logic_executor.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
		method:        method
		path:          dispatch_path
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

fn apply_worker_headers(mut ctx Context, headers map[string]string) {
	for name, value in headers {
		lower := name.to_lower()
		if lower == 'content-type' || lower == 'content-length' || lower == 'server'
			|| lower == 'x-request-id' {
			continue
		}
		if lower == 'set-cookie' {
			cookies := value.split('\n')
			for cookie in cookies {
				ctx.res.header.add_custom('Set-Cookie', cookie) or {}
			}
		} else {
			ctx.set_custom_header(name, value) or {}
		}
	}
}
