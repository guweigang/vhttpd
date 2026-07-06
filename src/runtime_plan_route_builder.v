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
		if route.match_path_regexps.len > 0 {
			mut compiled := []regex.RE{}
			mut ok := true
			for pattern in route.match_path_regexps {
				compiled << (regex.regex_opt(pattern) or {
					ok = false
					break
				})
			}
			if !ok {
				continue
			}
			route.res = compiled
		} else if route.match_path_regexp != '' {
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
		for reference in pipeline.transforms {
			if reference.id !in plan.transforms {
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'runtime_route_missing_transform'
					path:     'pipelines.${pipeline.id}.transforms'
					message:  'pipeline ${pipeline.id} references missing transform ${reference.str()}'
				}
			}
		}
		for reference in pipeline.policies {
			if reference.id !in plan.policies {
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'runtime_route_missing_policy'
					path:     'pipelines.${pipeline.id}.policies'
					message:  'pipeline ${pipeline.id} references missing policy ${reference.str()}'
				}
			}
		}
		if diagnostic := runtime_route_projection_preflight_diagnostic(plan, pipeline) {
			diagnostics << diagnostic
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
		for idx, pattern in route.match_path_regexps {
			regex.regex_opt(pattern) or {
				diagnostic_path := if idx == 0 && pipeline.match.path_regexp == pattern {
					'pipelines.${pipeline.id}.match.path_regexp'
				} else {
					'pipelines.${pipeline.id}.match.path_regexps.${idx}'
				}
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'runtime_route_invalid_path_regexp'
					path:     diagnostic_path
					message:  'pipeline ${pipeline.id} has invalid path regexp: ${err.msg()}'
				}
			}
		}
		if route.match_path_regexps.len == 0 && route.match_path_regexp != '' {
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

fn runtime_route_projection_preflight_diagnostic(plan runtime_plan.RuntimePlan, pipeline runtime_plan.PipelinePlan) ?runtime_plan.PlanDiagnostic {
	if pipeline.egress.domain == .terminal {
		return none
	}
	if pipeline.egress.domain != .adapter {
		return runtime_plan.PlanDiagnostic{
			severity: 'error'
			code:     'runtime_route_unsupported_egress'
			path:     'pipelines.${pipeline.id}.egress'
			message:  'pipeline ${pipeline.id} cannot be projected to an HTTP runtime route from egress ${pipeline.egress.str()}'
		}
	}
	adapter := plan.adapters[pipeline.egress.id] or {
		return runtime_plan.PlanDiagnostic{
			severity: 'error'
			code:     'runtime_route_missing_adapter'
			path:     'pipelines.${pipeline.id}.egress'
			message:  'pipeline ${pipeline.id} references missing adapter ${pipeline.egress.str()}'
		}
	}
	if adapter.kind !in ['http-handler', 'static', 'upload', 'fixed-response', 'relay-delivery',
		'provider-action', 'mcp', 'openai'] {
		return runtime_plan.PlanDiagnostic{
			severity: 'warning'
			code:     'runtime_route_unsupported_adapter'
			path:     'adapters.${adapter.id}'
			message:  'adapter ${adapter.id} with kind ${adapter.kind} cannot be projected to an HTTP runtime route'
		}
	}
	return none
}

fn runtime_route_from_pipeline(plan runtime_plan.RuntimePlan, pipeline runtime_plan.PipelinePlan) ?RuntimeRouteRule {
	mut route := RuntimeRouteRule{
		pipeline_id:        pipeline.id
		pipeline_group:     pipeline.group
		ingress_id:         pipeline.ingress.str()
		egress_ref:         pipeline.egress.str()
		policy_refs:        pipeline.policies.map(it.str())
		transform_refs:     pipeline.transforms.map(it.str())
		match_method:       pipeline.match.methods.clone()
		match_host:         pipeline.match.hosts.clone()
		match_path:         pipeline.match.paths.clone()
		match_path_regexp:  pipeline.match.path_regexp
		match_path_regexps: pipeline.match.path_regexps.clone()
		match_headers:      pipeline.match.headers.clone()
		match_query:        pipeline.match.query.clone()
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
			route.engine_id = runtime_engine_id(plan, adapter)
		}
		'static' {
			route.executor = 'static'
			route.root = adapter.options.strings['root']
			route.upload_dir = adapter.options.strings['legacy_upload_dir']
			if plan.source.compatibility {
				route.on_completed = legacy_completion_handler_from_plan(plan,
					adapter.options.strings['completed_pipeline'])
			}
		}
		'upload' {
			route.executor = 'upload'
			route.upload_dir = adapter.options.strings['root']
			if route.max_body_bytes == 0 {
				route.max_body_bytes = adapter.options.ints['max_body_bytes']
			}
			completed_pipeline := adapter.options.strings['completed_pipeline']
			if plan.source.compatibility {
				route.on_completed = legacy_completion_handler_from_plan(plan, completed_pipeline)
			}
			route.upload_completed_transform_refs = completed_transform_refs_from_plan(plan,
				completed_pipeline)
			route.upload_completed_pipeline_id = completed_pipeline_id_from_plan(completed_pipeline)
			route.upload_completed_ingress_ref = completed_ingress_ref_from_plan(plan,
				completed_pipeline)
			route.upload_completed_engine_ids = completed_engine_ids_from_plan(plan,
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
		'provider-action' {
			route.executor = 'provider-action'
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

fn completed_pipeline_id_from_plan(pipeline_ref string) string {
	ref := runtime_plan.parse_ref(pipeline_ref) or { return '' }
	if ref.domain != .pipeline {
		return ''
	}
	return ref.id
}

fn completed_ingress_ref_from_plan(plan runtime_plan.RuntimePlan, pipeline_ref string) string {
	ref := runtime_plan.parse_ref(pipeline_ref) or { return '' }
	if ref.domain != .pipeline {
		return ''
	}
	pipeline := plan.pipeline(ref.id) or { return '' }
	return pipeline.ingress.str()
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

fn runtime_engine_id(plan runtime_plan.RuntimePlan, adapter runtime_plan.AdapterPlan) string {
	engine_ref := adapter.engine or { return '' }
	if engine_ref.id !in plan.engines {
		return ''
	}
	if plan.source.compatibility {
		return ''
	}
	return engine_ref.id
}

fn completed_engine_ids_from_plan(plan runtime_plan.RuntimePlan, pipeline_ref string) []string {
	ref := runtime_plan.parse_ref(pipeline_ref) or { return []string{} }
	if ref.domain != .pipeline {
		return []string{}
	}
	pipeline := plan.pipeline(ref.id) or { return []string{} }
	mut ids := []string{}
	for transform_ref in pipeline.transforms {
		transform := plan.transforms[transform_ref.id] or { continue }
		engine_ref := transform.engine or { continue }
		if engine_ref.domain != .engine || engine_ref.id !in plan.engines {
			continue
		}
		if engine_ref.id !in ids {
			ids << engine_ref.id
		}
	}
	return ids
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
