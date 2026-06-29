module main

import regex
import runtime_plan

fn runtime_routes_from_plan(plan runtime_plan.RuntimePlan, listener_id string) []RuntimeRouteRule {
	mut routes := []RuntimeRouteRule{}
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain != .listener || pipeline.ingress.id != listener_id {
			continue
		}
		if pipeline.id.ends_with('_fallback') || pipeline.id.ends_with('_assets') {
			continue
		}
		mut route := runtime_route_from_pipeline(plan, pipeline) or { continue }
		if route.executor in ['mcp', 'openai'] {
			continue
		}
		if route.match_path_regexp != '' {
			route.re = regex.regex_opt(route.match_path_regexp) or { continue }
		}
		routes << route
	}
	return routes
}

fn runtime_route_projection_diagnostics(plan runtime_plan.RuntimePlan, listener_id string) []runtime_plan.PlanDiagnostic {
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain != .listener || pipeline.ingress.id != listener_id {
			continue
		}
		if pipeline.id.ends_with('_fallback') || pipeline.id.ends_with('_assets') {
			continue
		}
		route := runtime_route_from_pipeline(plan, pipeline) or {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'warning'
				code:     'runtime_route_projection_failed'
				path:     'pipelines.${pipeline.id}'
				message:  'pipeline ${pipeline.id} cannot be projected to an HTTP runtime route'
			}
			continue
		}
		if route.executor in ['mcp', 'openai'] {
			continue
		}
		if route.match_path_regexp != '' {
			regex.regex_opt(route.match_path_regexp) or {
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'runtime_route_invalid_path_regexp'
					path:     'pipelines.${pipeline.id}.match.path_regexp'
					message:  'pipeline ${pipeline.id} has invalid path regexp: ${err.msg()}'
				}
			}
		}
	}
	return diagnostics
}

fn runtime_route_from_pipeline(plan runtime_plan.RuntimePlan, pipeline runtime_plan.PipelinePlan) ?RuntimeRouteRule {
	mut route := RuntimeRouteRule{
		pipeline_id:       pipeline.id
		pipeline_group:    pipeline.group
		ingress_id:        pipeline.ingress.str()
		egress_ref:        pipeline.egress.str()
		policy_refs:       pipeline.policies.map(it.str())
		transform_refs:    pipeline.transforms.map(it.str())
		match_method:      pipeline.match.methods.clone()
		match_host:        pipeline.match.hosts.clone()
		match_path:        pipeline.match.paths.clone()
		match_path_regexp: pipeline.match.path_regexp
		match_headers:     pipeline.match.headers.clone()
		match_query:       pipeline.match.query.clone()
	}
	for reference in pipeline.transforms {
		transform := plan.transforms[reference.id] or { continue }
		if transform.handler == 'http.rewrite' {
			route.rewrite = transform.options.strings['target']
			route.rewrite_strip_prefix = transform.options.strings['strip_prefix']
		}
	}
	for reference in pipeline.policies {
		policy := plan.policies[reference.id] or { continue }
		match policy.category {
			'cache' {
				route.cache_control = policy.options.strings['cache_control']
				route.response_cache_ttl_ms = policy.options.ints['ttl_ms']
				route.cache_bypass_cookie_patterns =
					policy.options.string_lists['bypass_cookie_patterns'].clone()
				route.cache_ignore_cookie_patterns =
					policy.options.string_lists['ignore_cookie_patterns'].clone()
			}
			'limits' {
				route.max_body_bytes = policy.options.ints['max_body_bytes']
			}
			'security' {
				route.required_headers = policy.options.string_maps['required_headers'].clone()
				route.denied_query_patterns =
					policy.options.string_maps['denied_query_patterns'].clone()
			}
			'response' {
				route.response_headers = policy.options.string_maps['headers'].clone()
			}
			else {}
		}
	}
	if pipeline.egress.domain == .terminal {
		route.executor = 'none'
		return route
	}
	if pipeline.egress.domain != .adapter {
		return none
	}
	adapter := plan.adapters[pipeline.egress.id] or { return none }
	match adapter.kind {
		'http-handler' {
			route.executor = runtime_executor_name(plan, adapter)
		}
		'static' {
			route.executor = 'static'
			route.root = adapter.options.strings['root']
			route.upload_dir = adapter.options.strings['legacy_upload_dir']
			route.on_completed = legacy_completion_handler_from_plan(plan,
				adapter.options.strings['completed_pipeline'])
		}
		'upload' {
			route.executor = 'upload'
			route.upload_dir = adapter.options.strings['root']
			if route.max_body_bytes == 0 {
				route.max_body_bytes = adapter.options.ints['max_body_bytes']
			}
			completed_pipeline := adapter.options.strings['completed_pipeline']
			route.on_completed = legacy_completion_handler_from_plan(plan, completed_pipeline)
			route.upload_completed_transform_refs = completed_transform_refs_from_plan(plan,
				completed_pipeline)
		}
		'fixed-response' {
			route.executor = 'none'
			route.status = adapter.options.strings['status'].int()
			route.location = adapter.options.strings['location']
			route.body = adapter.options.strings['body']
		}
		'relay-delivery' {
			route.executor = 'relay-delivery'
		}
		'mcp', 'openai' {
			route.executor = adapter.kind
		}
		else {
			return none
		}
	}

	return route
}

fn completed_transform_refs_from_plan(plan runtime_plan.RuntimePlan, pipeline_ref string) []string {
	ref := runtime_plan.parse_ref(pipeline_ref) or { return []string{} }
	if ref.domain != .pipeline {
		return []string{}
	}
	pipeline := plan.pipeline(ref.id) or { return []string{} }
	return pipeline.transforms.map(it.str())
}

fn runtime_executor_name(plan runtime_plan.RuntimePlan, adapter runtime_plan.AdapterPlan) string {
	engine_ref := adapter.engine or { return '' }
	if engine_ref.id !in plan.engines {
		return ''
	}
	if engine_ref.id.ends_with('/default') {
		return ''
	}
	return engine_ref.id.all_after_last('/')
}

fn legacy_completion_handler_from_plan(plan runtime_plan.RuntimePlan, value string) string {
	if value.trim_space() == '' {
		return ''
	}
	reference := runtime_plan.parse_ref(value) or { return value }
	if reference.domain != .pipeline {
		return value
	}
	pipeline := plan.pipeline(reference.id) or { return value }
	if pipeline.transforms.len == 0 {
		return value
	}
	transform := plan.transforms[pipeline.transforms[0].id] or { return value }
	if transform.handler == '' {
		return value
	}
	return '${transform.kind}:${transform.handler}'
}
