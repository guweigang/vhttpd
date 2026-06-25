module main

import cachex
import dispatch
import net.http
import worker

struct HttpPipelineMatchRequest {
	method            string
	normalized_target string
	query             map[string]string
	headers           map[string]string
	body              string
	remote_addr       string
	req_id            string
	trace_id          string
	start_ms          i64
}

struct PipelineRuntime {
mut:
	http HttpRoutingRuntime
}

fn PipelineRuntime.new(listener_id string, routes []RuntimeRouteRule, assets_root string, worker_root string, primary_env map[string]string, additional_workers map[string]&worker.WorkerState) PipelineRuntime {
	return PipelineRuntime{
		http: HttpRoutingRuntime.new(listener_id, routes, assets_root, worker_root, primary_env,
			additional_workers)
	}
}

fn (rt PipelineRuntime) http_document_root() string {
	return rt.http.document_root
}

fn (rt PipelineRuntime) match_http_request(req HttpPipelineMatchRequest) ?RuntimeRouteRule {
	exchange := dispatch.http_request_exchange(dispatch.HttpIngressRequest{
		method:        req.method
		path:          req.normalized_target
		query:         req.query
		headers:       req.headers
		body:          req.body
		remote_addr:   req.remote_addr
		request_id:    req.req_id
		trace_id:      req.trace_id
		exchange_id:   req.req_id
		ingress:       'listener:${rt.http.listener_id}'
		created_at_ms: req.start_ms
	})
	return rt.http.match_compiled_http_exchange(exchange)
}

fn (rt PipelineRuntime) http_static_root(rule RuntimeRouteRule) string {
	return rt.http.static_root(rule)
}

fn (rt PipelineRuntime) http_dispatch_target(rule ?RuntimeRouteRule, original_target string) string {
	if matched := rule {
		return matched.rewrite_target(original_target)
	}
	return original_target
}

fn (rt PipelineRuntime) http_response_cache_hit(mut cache cachex.Runtime, rule RuntimeRouteRule, method string, target string, req http.Request) ?EdgeCachedHttpResponse {
	if route_response_cache_request_bypass_reason(rule, method, req) != '' {
		return none
	}
	return rt.http.response_cache_get(mut cache, rule, method, target)
}

fn (rt PipelineRuntime) http_response_cache_set(mut cache cachex.Runtime, rule RuntimeRouteRule, method string, target string, cached EdgeCachedHttpResponse) {
	rt.http.response_cache_set(mut cache, rule, method, target, cached)
}
