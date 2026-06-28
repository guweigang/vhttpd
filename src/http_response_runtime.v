module main

import dispatch
import executor
import log
import net.http
import relay
import time
import upstream.transport
import veb
import ws

struct HttpIngressRequest {
	method        string
	path          string
	dispatch_path string
	body_on_head  string
	remote_addr   string
	request_id    string
	trace_id      string
	start_ms      i64
pub mut:
	pipeline_id string
	ingress_id  string
}

struct HttpResponseRuntime {}

fn HttpResponseRuntime.cache_hit(mut app App, mut ctx Context, req HttpIngressRequest, hit HttpResponseCacheHit) veb.Result {
	log.info('[http] ⇠ route response cache hit method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id}')
	mut headers := {
		'content-type':   hit.cached.content_type
		'x-vhttpd-cache': 'hit'
	}
	if hit.cached.cache_control != '' {
		headers['cache-control'] = hit.cached.cache_control
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, req, dispatch.outcome_with_metadata(dispatch.response_outcome(hit.cached.status,
		headers, hit.cached.body), {
		'cache': 'hit'
	}), hit.rule)
}

fn HttpResponseRuntime.dispatch_error(mut app App, mut ctx Context, req HttpIngressRequest, err_msg string) veb.Result {
	status, error_class := transport.classify_worker_backend_error(err_msg)
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, req, dispatch.delivery_failure_outcome(status,
		err_msg, error_class), none)
}

fn HttpResponseRuntime.delivery_outcome(mut app App, mut ctx Context, req HttpIngressRequest, outcome dispatch.DeliveryOutcome, matched_rule ?RuntimeRouteRule) veb.Result {
	if outcome.kind == .file {
		return HttpResponseRuntime.file_outcome(mut app, mut ctx, req, outcome, matched_rule)
	}
	if outcome.kind == .relay_delivery {
		projected := app.dispatch_relay_delivery(outcome)
		return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, req, projected, matched_rule)
	}
	status := if outcome.status > 0 { outcome.status } else { 200 }
	error_class := outcome.error_class
	mut log_line := '[http] ⇠ delivery outcome method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} status=${status} kind=${outcome.kind} duration_ms=${time.now().unix_milli() - req.start_ms}'
	if outcome.error != '' {
		log_line += ' error=${outcome.error}'
	}
	if outcome.kind == .failure {
		log.error(log_line)
	} else {
		log.info(log_line)
	}
	mut event_fields := {
		'method':      req.method.to_upper()
		'path':        transport.normalize_path(req.path)
		'status':      '${status}'
		'request_id':  req.request_id
		'trace_id':    req.trace_id
		'duration_ms': '${time.now().unix_milli() - req.start_ms}'
	}
	if req.pipeline_id != '' {
		event_fields['pipeline'] = req.pipeline_id
	}
	if req.ingress_id != '' {
		event_fields['ingress'] = req.ingress_id
	}
	if rule := matched_rule {
		if rule.policy_refs.len > 0 {
			event_fields['policies'] = rule.policy_refs.join(',')
		}
	}
	if error_class != '' {
		event_fields['error_class'] = error_class
	}
	if outcome.error != '' {
		event_fields['error'] = outcome.error
	}
	for key, value in outcome.metadata {
		if key != '' && value != '' {
			event_fields[key] = value
		}
	}
	app.emit('http.request', event_fields)
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	if req.pipeline_id != '' {
		ctx.set_custom_header('x-vhttpd-pipeline', req.pipeline_id) or {}
	}
	if error_class != '' {
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
	}
	apply_delivery_headers(mut ctx, outcome.headers)
	if rule := matched_rule {
		apply_route_response_headers(mut ctx, rule)
	}
	ctx.res.set_status(http.status_from_int(status))
	if ctype := outcome.headers['content-type'] {
		if ctype != '' {
			ctx.set_content_type(ctype)
		}
	}
	body := if req.method.to_upper() == 'HEAD' || status in [204, 304] {
		''
	} else if outcome.body != '' {
		outcome.body
	} else {
		req.body_on_head
	}
	return ctx.text(body)
}

fn (mut app App) dispatch_relay_delivery(outcome dispatch.DeliveryOutcome) dispatch.DeliveryOutcome {
	outbound := app.relay.prepare_outbound_delivery(outcome)
	if outbound.action != .ready {
		return relay_delivery_http_outcome(outbound)
	}
	if outbound.completion.mode != 'accepted' {
		return relay_delivery_completion_policy_http_outcome(outbound)
	}
	mut carrier := ws.new_relay_carrier(app.build_websocket_runtime_context(), outbound.carrier_id)
	send_result := relay.send_to_carrier(mut carrier, outbound)
	return relay_delivery_send_http_outcome(outbound, send_result)
}

fn relay_delivery_http_outcome(outbound relay.OutboundOutcome) dispatch.DeliveryOutcome {
	if outbound.action == .rejected {
		return dispatch.delivery_failure_outcome(500, outbound.error, 'relay_delivery_projection')
	}
	if outbound.action == .ready {
		return dispatch.accepted_event_outcome(outbound.fields)
	}
	return dispatch.outcome_with_metadata(dispatch.delivery_failure_outcome(503, outbound.error,
		'relay_carrier_unavailable'), outbound.fields)
}

fn relay_delivery_completion_policy_http_outcome(outbound relay.OutboundOutcome) dispatch.DeliveryOutcome {
	mut fields := outbound.fields.clone()
	fields['supported_completion_mode'] = 'accepted'
	err := 'relay_completion_policy_unsupported:http:${outbound.completion.mode}'
	return dispatch.outcome_with_metadata(dispatch.delivery_failure_outcome(501, err,
		'relay_completion_policy_unsupported'), fields)
}

fn relay_delivery_send_http_outcome(outbound relay.OutboundOutcome, send_result relay.CarrierSendResult) dispatch.DeliveryOutcome {
	completion := relay.response_completion_sent(outbound, send_result)
	return relay.response_completion_delivery_outcome(completion)
}

fn HttpResponseRuntime.file_outcome(mut app App, mut ctx Context, req HttpIngressRequest, outcome dispatch.DeliveryOutcome, matched_rule ?RuntimeRouteRule) veb.Result {
	log.info('[http] ⇠ delivery file method=${req.method.to_upper()} path=${req.path} file=${outcome.path} trace_id=${req.trace_id} request_id=${req.request_id} duration_ms=${time.now().unix_milli() - req.start_ms}')
	mut event_fields := {
		'method':      req.method.to_upper()
		'path':        transport.normalize_path(req.path)
		'status':      '200'
		'request_id':  req.request_id
		'trace_id':    req.trace_id
		'duration_ms': '${time.now().unix_milli() - req.start_ms}'
	}
	if req.pipeline_id != '' {
		event_fields['pipeline'] = req.pipeline_id
	}
	if req.ingress_id != '' {
		event_fields['ingress'] = req.ingress_id
	}
	if rule := matched_rule {
		if rule.policy_refs.len > 0 {
			event_fields['policies'] = rule.policy_refs.join(',')
		}
	}
	app.emit('http.request', event_fields)
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	if req.pipeline_id != '' {
		ctx.set_custom_header('x-vhttpd-pipeline', req.pipeline_id) or {}
	}
	apply_delivery_headers(mut ctx, outcome.headers)
	if ctype := outcome.headers['content-type'] {
		if ctype != '' {
			ctx.set_content_type(ctype)
		}
	}
	if rule := matched_rule {
		apply_route_response_headers(mut ctx, rule)
	}
	return ctx.file(outcome.path)
}

fn HttpResponseRuntime.render(mut app App, mut ctx Context, req HttpIngressRequest, mut outcome executor.HttpLogicDispatchOutcome, dispatch_plan HttpPipelineDispatchPlan) veb.Result {
	if outcome.kind == .stream {
		return HttpResponseRuntime.stream(mut app, mut ctx, req, mut outcome)
	}
	if outcome.kind == .upstream_plan {
		return HttpResponseRuntime.upstream_plan(mut app, mut ctx, req, outcome)
	}
	return HttpResponseRuntime.normal(mut app, mut ctx, req, outcome, dispatch_plan)
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
	return UpstreamRuntimeContext.execute_plan(upstream_runtime, mut app, mut ctx,
		outcome.upstream_plan, req.method, req.path, req.request_id, req.trace_id, req.start_ms)
}

fn HttpResponseRuntime.normal(mut app App, mut ctx Context, req HttpIngressRequest, outcome executor.HttpLogicDispatchOutcome, dispatch_plan HttpPipelineDispatchPlan) veb.Result {
	delivery := worker_response_delivery_outcome(outcome.response)
	log.info('[http] ⇠ dispatch response method=${req.method.to_upper()} path=${req.path} trace_id=${req.trace_id} request_id=${req.request_id} status=${delivery.status} body_len=${delivery.body.len} duration_ms=${time.now().unix_milli() - req.start_ms}')
	mut cache_result := ''
	mut cache_reason := ''
	cache_store := app.pipelines.http_response_cache_store(mut app.transport.cache, dispatch_plan,
		req.method, ctx.req, delivery)
	cache_result = cache_store.result
	cache_reason = cache_store.reason
	mut event_fields := {
		'method':       req.method.to_upper()
		'path':         transport.normalize_path(req.path)
		'status':       '${delivery.status}'
		'request_id':   req.request_id
		'trace_id':     req.trace_id
		'duration_ms':  '${time.now().unix_milli() - req.start_ms}'
		'cache':        cache_result
		'cache_reason': cache_reason
	}
	if req.pipeline_id != '' {
		event_fields['pipeline'] = req.pipeline_id
	}
	if req.ingress_id != '' {
		event_fields['ingress'] = req.ingress_id
	}
	if rule := dispatch_plan.rule {
		if rule.policy_refs.len > 0 {
			event_fields['policies'] = rule.policy_refs.join(',')
		}
	}
	app.emit('http.request', event_fields)
	return HttpResponseRuntime.response_outcome(mut ctx, req, delivery, dispatch_plan,
		cache_result, cache_reason)
}

fn worker_response_delivery_outcome(resp transport.WorkerResponse) dispatch.DeliveryOutcome {
	return dispatch.response_outcome(resp.status, resp.headers, resp.body)
}

fn HttpResponseRuntime.response_outcome(mut ctx Context, req HttpIngressRequest, outcome dispatch.DeliveryOutcome, dispatch_plan HttpPipelineDispatchPlan, cache_result string, cache_reason string) veb.Result {
	status := if outcome.status > 0 { outcome.status } else { 200 }
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	if req.pipeline_id != '' {
		ctx.set_custom_header('x-vhttpd-pipeline', req.pipeline_id) or {}
	}
	if cache_result != '' {
		ctx.set_custom_header('x-vhttpd-cache', cache_result) or {}
	}
	if cache_reason != '' {
		ctx.set_custom_header('x-vhttpd-cache-reason', cache_reason) or {}
	}
	ctx.res.set_status(http.status_from_int(status))
	apply_delivery_headers(mut ctx, outcome.headers)
	if rule := dispatch_plan.rule {
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

fn apply_delivery_headers(mut ctx Context, headers map[string]string) {
	for name, value in headers {
		lower := name.to_lower()
		if value == '' || lower == 'content-type' || lower == 'content-length' || lower == 'server' {
			continue
		}
		if lower == 'set-cookie' {
			for cookie in delivery_set_cookie_values(value) {
				ctx.res.header.add_custom('Set-Cookie', cookie) or {}
			}
		} else {
			ctx.set_custom_header(name, value) or {}
		}
	}
}

fn delivery_set_cookie_values(value string) []string {
	mut cookies := []string{}
	for cookie in value.split('\n') {
		clean := cookie.trim_space()
		if clean != '' {
			cookies << clean
		}
	}
	return cookies
}
