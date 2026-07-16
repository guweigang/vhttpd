module main

import cachex
import dispatch
import executor
import net.http
import relay
import runtime_plan
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

struct HttpResponseCacheStoreResult {
	result string
	reason string
}

struct HttpPipelineDispatchPlan {
	rule        ?RuntimeRouteRule
	target      string
	executor    string
	pipeline_id string
}

struct HttpResponseCacheHit {
	rule   RuntimeRouteRule
	cached EdgeCachedHttpResponse
}

struct PipelineRuntime {
mut:
	http  HttpRoutingRuntime
	relay RelayPipelineRuntime
}

struct RelayPipelineRuntime {
	descriptors map[string][]dispatch.PipelineDescriptor
}

fn PipelineRuntime.new(plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, assets_root string, worker_root string, primary_env map[string]string, additional_workers map[string]&worker.WorkerState) PipelineRuntime {
	return PipelineRuntime{
		http:  HttpRoutingRuntime.new(listener_id, routes, assets_root, worker_root, primary_env,
			additional_workers)
		relay: RelayPipelineRuntime.new(plan)
	}
}

fn RelayPipelineRuntime.new(plan runtime_plan.RuntimePlan) RelayPipelineRuntime {
	adapters := dispatch.adapter_descriptors_from_plan(plan)
	transforms := dispatch.transform_descriptors_from_plan(plan)
	mut descriptors := map[string][]dispatch.PipelineDescriptor{}
	mut relay_ids := plan.relays.keys()
	relay_ids.sort()
	for relay_id in relay_ids {
		mut relay_descriptors := []dispatch.PipelineDescriptor{}
		for pipeline in plan.relay_pipelines(relay_id) {
			relay_descriptors << dispatch.pipeline_descriptor_from_plan_with_runtime_descriptors(pipeline,
				adapters, transforms)
		}
		descriptors[relay_id] = relay_descriptors
	}
	return RelayPipelineRuntime{
		descriptors: descriptors
	}
}

fn (rt RelayPipelineRuntime) pipeline_descriptors(relay_id string) []dispatch.PipelineDescriptor {
	return (rt.descriptors[relay_id] or { []dispatch.PipelineDescriptor{} }).clone()
}

fn (rt RelayPipelineRuntime) ingress_exchanges(relay_id string, carrier_id string, frame relay.WireFrame, created_at_ms i64) []dispatch.Exchange {
	mut exchanges := []dispatch.Exchange{}
	for descriptor in rt.pipeline_descriptors(relay_id) {
		req := relay.relay_ingress_request_from_frame(relay_id, carrier_id, frame, descriptor.id,
			created_at_ms)
		exchanges << dispatch.relay_ingress_exchange(req)
	}
	return exchanges
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

fn (rt PipelineRuntime) has_protocol_http_override(req ProtocolHttpRequest) bool {
	rule := rt.match_http_request(HttpPipelineMatchRequest{
		method:            req.method
		normalized_target: req.normalized_target
		query:             req.query
		headers:           req.headers
		body:              req.body
		remote_addr:       ''
		req_id:            req.request_id
		trace_id:          req.trace_id
		start_ms:          req.start_ms
	}) or { return false }
	return rule.executor !in ['mcp', 'openai']
}

fn (rt PipelineRuntime) http_directory_slash_redirect(normalized_target string, query_string string) ?string {
	return directory_slash_redirect_location(rt.http.document_root, normalized_target, query_string)
}

fn (rt PipelineRuntime) http_static_root(rule RuntimeRouteRule) string {
	return rt.http.static_root(rule)
}

fn (rt PipelineRuntime) http_dispatch_plan(rule ?RuntimeRouteRule, original_target string) HttpPipelineDispatchPlan {
	if matched := rule {
		return HttpPipelineDispatchPlan{
			rule:        matched
			target:      matched.rewrite_target(original_target)
			executor:    matched.dispatch_executor()
			pipeline_id: matched.pipeline_id
		}
	}
	return HttpPipelineDispatchPlan{
		target: original_target
	}
}

fn (rule RuntimeRouteRule) dispatch_executor() string {
	if rule.engine_id != '' {
		return rule.engine_id
	}
	return rule.executor
}

fn (rt PipelineRuntime) http_ingress_request(method string, path string, plan HttpPipelineDispatchPlan, body_on_head string, remote_addr string, request_id string, trace_id string, start_ms i64) HttpIngressRequest {
	mut req := http_ingress_request(method, path, plan.target, body_on_head, remote_addr,
		request_id, trace_id, start_ms)
	if rule := plan.rule {
		req.pipeline_id = rule.pipeline_id
		req.ingress_id = rule.ingress_id
	}
	return req
}

fn (rt PipelineRuntime) http_logic_dispatch_request(method string, original_path string, plan HttpPipelineDispatchPlan, req http.Request, remote_addr string, trace_id string, request_id string) executor.HttpLogicDispatchRequest {
	return executor.HttpLogicDispatchRequest{
		method:        method
		path:          plan.target
		original_path: original_path
		req:           req
		remote_addr:   remote_addr
		trace_id:      trace_id
		request_id:    request_id
	}
}

fn (rt PipelineRuntime) http_response_cache_hit(mut cache cachex.Runtime, plan HttpPipelineDispatchPlan, method string, req http.Request) ?HttpResponseCacheHit {
	rule := plan.rule or { return none }
	if rule.response_cache_ttl_ms <= 0 || !cache.enabled {
		return none
	}
	if route_response_cache_request_bypass_reason(rule, method, req) != '' {
		return none
	}
	cached := rt.http.response_cache_get(mut cache, rule, method, plan.target) or { return none }
	return HttpResponseCacheHit{
		rule:   rule
		cached: cached
	}
}

fn (rt PipelineRuntime) http_response_cache_store(mut cache cachex.Runtime, plan HttpPipelineDispatchPlan, method string, req http.Request, outcome dispatch.DeliveryOutcome) HttpResponseCacheStoreResult {
	rule := plan.rule or { return HttpResponseCacheStoreResult{} }
	if rule.response_cache_ttl_ms <= 0 {
		return HttpResponseCacheStoreResult{}
	}
	request_bypass_reason := if cache.enabled {
		route_response_cache_request_bypass_reason(rule, method, req)
	} else {
		'cache_disabled'
	}
	if request_bypass_reason != '' {
		return HttpResponseCacheStoreResult{
			result: 'bypass'
			reason: request_bypass_reason
		}
	}
	store_bypass_reason := route_response_cache_store_bypass_reason_for_outcome(outcome)
	if store_bypass_reason != '' {
		return HttpResponseCacheStoreResult{
			result: 'bypass'
			reason: store_bypass_reason
		}
	}
	ctype := outcome.headers['content-type'] or { 'text/plain; charset=utf-8' }
	cache_control := outcome.headers['cache-control'] or { rule.cache_control }
	rt.http.response_cache_set(mut cache, rule, method, plan.target, EdgeCachedHttpResponse{
		status:        outcome.status
		content_type:  ctype
		cache_control: cache_control
		body:          outcome.body
	})
	return HttpResponseCacheStoreResult{
		result: 'store'
	}
}
