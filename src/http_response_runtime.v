module main

import dispatch
import executor
import log
import net.http
import time
import upstream.transport
import veb

struct HttpIngressRequest {
	method        string
	path          string
	dispatch_path string
	body_on_head  string
	remote_addr   string
	request_id    string
	trace_id      string
	start_ms      i64
}

struct HttpResponseRuntime {}

fn HttpResponseRuntime.cache_hit(mut app App, mut ctx Context, req HttpIngressRequest, cached EdgeCachedHttpResponse, rule RuntimeRouteRule) veb.Result {
	log.info('[http] ⇠ route response cache hit method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id}')
	app.emit('http.request', {
		'method':      req.method.to_upper()
		'path':        transport.normalize_path(req.path)
		'status':      '${cached.status}'
		'request_id':  req.request_id
		'trace_id':    req.trace_id
		'duration_ms': '${time.now().unix_milli() - req.start_ms}'
		'cache':       'hit'
	})
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	ctx.set_custom_header('x-vhttpd-cache', 'hit') or {}
	if cached.cache_control != '' {
		ctx.set_custom_header('cache-control', cached.cache_control) or {}
	}
	apply_route_response_headers(mut ctx, rule)
	ctx.res.set_status(http.status_from_int(cached.status))
	ctx.set_content_type(cached.content_type)
	return ctx.text(if req.method.to_upper() == 'HEAD' { '' } else { cached.body })
}

fn HttpResponseRuntime.dispatch_error(mut app App, mut ctx Context, req HttpIngressRequest, err_msg string) veb.Result {
	status, error_class := transport.classify_worker_backend_error(err_msg)
	log.error('[http] ⇠ dispatch error method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} status=${status} duration_ms=${time.now().unix_milli() - req.start_ms} error=${err_msg}')
	app.emit('http.request', {
		'method':      req.method.to_upper()
		'path':        transport.normalize_path(req.path)
		'status':      '${status}'
		'request_id':  req.request_id
		'trace_id':    req.trace_id
		'duration_ms': '${time.now().unix_milli() - req.start_ms}'
		'error_class': error_class
		'error':       err_msg
	})
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(req.body_on_head)
}

fn HttpResponseRuntime.delivery_outcome(mut app App, mut ctx Context, req HttpIngressRequest, outcome dispatch.DeliveryOutcome, matched_rule ?RuntimeRouteRule) veb.Result {
	if outcome.kind == .file {
		return HttpResponseRuntime.file_outcome(mut app, mut ctx, req, outcome, matched_rule)
	}
	status := if outcome.status > 0 { outcome.status } else { 200 }
	error_class := outcome.error_class
	log.info('[http] ⇠ delivery outcome method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} status=${status} kind=${outcome.kind} duration_ms=${time.now().unix_milli() - req.start_ms}')
	mut event_fields := {
		'method':      req.method.to_upper()
		'path':        transport.normalize_path(req.path)
		'status':      '${status}'
		'request_id':  req.request_id
		'trace_id':    req.trace_id
		'duration_ms': '${time.now().unix_milli() - req.start_ms}'
	}
	if error_class != '' {
		event_fields['error_class'] = error_class
	}
	if outcome.error != '' {
		event_fields['error'] = outcome.error
	}
	app.emit('http.request', event_fields)
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	if error_class != '' {
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
	}
	for name, value in outcome.headers {
		if value == '' {
			continue
		}
		if name.to_lower() == 'content-type' {
			ctx.set_content_type(value)
		} else {
			ctx.set_custom_header(name, value) or {}
		}
	}
	if rule := matched_rule {
		apply_route_response_headers(mut ctx, rule)
	}
	ctx.res.set_status(http.status_from_int(status))
	body := if req.method.to_upper() == 'HEAD' || status in [204, 304] {
		''
	} else if outcome.body != '' {
		outcome.body
	} else {
		req.body_on_head
	}
	return ctx.text(body)
}

fn HttpResponseRuntime.file_outcome(mut app App, mut ctx Context, req HttpIngressRequest, outcome dispatch.DeliveryOutcome, matched_rule ?RuntimeRouteRule) veb.Result {
	log.info('[http] ⇠ delivery file method=${req.method.to_upper()} path=${req.path} file=${outcome.path} trace_id=${req.trace_id} request_id=${req.request_id} duration_ms=${time.now().unix_milli() - req.start_ms}')
	app.emit('http.request', {
		'method':      req.method.to_upper()
		'path':        transport.normalize_path(req.path)
		'status':      '200'
		'request_id':  req.request_id
		'trace_id':    req.trace_id
		'duration_ms': '${time.now().unix_milli() - req.start_ms}'
	})
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	for name, value in outcome.headers {
		if value == '' {
			continue
		}
		ctx.set_custom_header(name, value) or {}
	}
	if rule := matched_rule {
		apply_route_response_headers(mut ctx, rule)
	}
	return ctx.file(outcome.path)
}

fn HttpResponseRuntime.render(mut app App, mut ctx Context, req HttpIngressRequest, mut outcome executor.HttpLogicDispatchOutcome, matched_rule ?RuntimeRouteRule) veb.Result {
	if outcome.kind == .stream {
		return HttpResponseRuntime.stream(mut app, mut ctx, req, mut outcome)
	}
	if outcome.kind == .upstream_plan {
		return HttpResponseRuntime.upstream_plan(mut app, mut ctx, req, outcome)
	}
	return HttpResponseRuntime.normal(mut app, mut ctx, req, outcome, matched_rule)
}

fn HttpResponseRuntime.stream(mut app App, mut ctx Context, req HttpIngressRequest, mut outcome executor.HttpLogicDispatchOutcome) veb.Result {
	log.info('[http] ⇠ dispatch stream method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} socket=${outcome.socket_path} duration_ms=${time.now().unix_milli() - req.start_ms}')
	mut conn := outcome.conn
	selected_socket := outcome.socket_path
	start := outcome.stream_start
	defer {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
	}
	if (start.stream_type == 'sse' || start.content_type.starts_with('text/event-stream'))
		&& req.method.to_upper() != 'HEAD' {
		return HttpStreamRuntime.via_sse(mut app, mut ctx, mut conn, start, req.method, req.path,
			req.request_id, req.trace_id, req.start_ms)
	}
	return HttpStreamRuntime.via_passthrough(mut app, mut ctx, mut conn, start, req.method,
		req.path, req.request_id, req.trace_id, req.start_ms)
}

fn HttpResponseRuntime.upstream_plan(mut app App, mut ctx Context, req HttpIngressRequest, outcome executor.HttpLogicDispatchOutcome) veb.Result {
	log.info('[http] ⇠ dispatch upstream_plan method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} duration_ms=${time.now().unix_milli() - req.start_ms}')
	upstream_runtime := app.build_upstream_runtime_context()
	return UpstreamRuntimeContext.execute_plan(upstream_runtime, mut ctx, outcome.upstream_plan,
		req.method, req.path, req.request_id, req.trace_id, req.start_ms)
}

fn HttpResponseRuntime.normal(mut app App, mut ctx Context, req HttpIngressRequest, outcome executor.HttpLogicDispatchOutcome, matched_rule ?RuntimeRouteRule) veb.Result {
	resp := outcome.response
	delivery := worker_response_delivery_outcome(resp)
	log.info('[http] ⇠ dispatch response method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} status=${resp.status} body_len=${resp.body.len} duration_ms=${time.now().unix_milli() - req.start_ms}')
	mut cache_result := ''
	mut cache_reason := ''
	if rule := matched_rule {
		if rule.response_cache_ttl_ms > 0 {
			request_bypass_reason := if app.transport.cache.enabled {
				route_response_cache_request_bypass_reason(rule, req.method, ctx.req)
			} else {
				'cache_disabled'
			}
			if request_bypass_reason != '' {
				cache_result = 'bypass'
				cache_reason = request_bypass_reason
			} else {
				store_bypass_reason := route_response_cache_store_bypass_reason(resp)
				if store_bypass_reason != '' {
					cache_result = 'bypass'
					cache_reason = store_bypass_reason
				} else {
					ctype := delivery.headers['content-type'] or { 'text/plain; charset=utf-8' }
					cache_control := delivery.headers['cache-control'] or { rule.cache_control }
					app.http_routing.response_cache_set(mut app.transport.cache, rule, req.method,
						req.dispatch_path, EdgeCachedHttpResponse{
						status:        delivery.status
						content_type:  ctype
						cache_control: cache_control
						body:          delivery.body
					})
					cache_result = 'store'
				}
			}
		}
	}
	app.emit('http.request', {
		'method':       req.method.to_upper()
		'path':         transport.normalize_path(req.path)
		'status':       '${resp.status}'
		'request_id':   req.request_id
		'trace_id':     req.trace_id
		'duration_ms':  '${time.now().unix_milli() - req.start_ms}'
		'cache':        cache_result
		'cache_reason': cache_reason
	})
	return HttpResponseRuntime.worker_response_outcome(mut ctx, req, delivery, matched_rule,
		cache_result, cache_reason)
}

fn worker_response_delivery_outcome(resp transport.WorkerResponse) dispatch.DeliveryOutcome {
	return dispatch.response_outcome(resp.status, resp.headers, resp.body)
}

fn HttpResponseRuntime.worker_response_outcome(mut ctx Context, req HttpIngressRequest, outcome dispatch.DeliveryOutcome, matched_rule ?RuntimeRouteRule, cache_result string, cache_reason string) veb.Result {
	status := if outcome.status > 0 { outcome.status } else { 200 }
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	if cache_result != '' {
		ctx.set_custom_header('x-vhttpd-cache', cache_result) or {}
	}
	if cache_reason != '' {
		ctx.set_custom_header('x-vhttpd-cache-reason', cache_reason) or {}
	}
	ctx.res.set_status(http.status_from_int(status))
	apply_worker_headers(mut ctx, outcome.headers)
	if rule := matched_rule {
		apply_route_response_headers(mut ctx, rule)
		if rule.cache_control.trim_space() != ''
			&& !route_response_headers_have(outcome.headers, 'cache-control') {
			ctx.set_custom_header('cache-control', rule.cache_control) or {}
		}
	}
	ctype := outcome.headers['content-type'] or { 'text/plain; charset=utf-8' }
	ctx.set_content_type(ctype)
	return ctx.text(if req.body_on_head == '' && req.method.to_upper() == 'HEAD' {
		''
	} else {
		outcome.body
	})
}
