module main

import cachex
import dispatch
import worker

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

fn (rt PipelineRuntime) http_listener_id() string {
	return rt.http.listener_id
}

fn (rt PipelineRuntime) http_document_root() string {
	return rt.http.document_root
}

fn (rt PipelineRuntime) match_http_exchange(exchange dispatch.Exchange) ?RuntimeRouteRule {
	return rt.http.match_compiled_http_exchange(exchange)
}

fn (rt PipelineRuntime) http_static_root(rule RuntimeRouteRule) string {
	return rt.http.static_root(rule)
}

fn (rt PipelineRuntime) http_response_cache_get(mut cache cachex.Runtime, rule RuntimeRouteRule, method string, target string) ?EdgeCachedHttpResponse {
	return rt.http.response_cache_get(mut cache, rule, method, target)
}

fn (rt PipelineRuntime) http_response_cache_set(mut cache cachex.Runtime, rule RuntimeRouteRule, method string, target string, cached EdgeCachedHttpResponse) {
	rt.http.response_cache_set(mut cache, rule, method, target, cached)
}
