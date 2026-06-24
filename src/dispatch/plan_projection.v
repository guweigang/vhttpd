module dispatch

import runtime_plan

pub fn pipeline_descriptor_from_plan(pipeline runtime_plan.PipelinePlan) PipelineDescriptor {
	return PipelineDescriptor{
		id:         pipeline.id
		group:      pipeline.group
		ingress:    pipeline.ingress.str()
		transforms: pipeline.transforms.map(it.str())
		policies:   pipeline.policies.map(it.str())
		egress:     pipeline.egress.str()
	}
}

pub fn pipeline_descriptor_from_plan_with_adapters(pipeline runtime_plan.PipelinePlan, adapters map[string]AdapterDescriptor) PipelineDescriptor {
	mut descriptor := pipeline_descriptor_from_plan(pipeline)
	if adapter := adapters[pipeline.egress.id] {
		descriptor = PipelineDescriptor{
			...descriptor
			required: adapter.capabilities
		}
	}
	return descriptor
}

pub fn http_match_from_plan(pipeline runtime_plan.PipelinePlan) HttpMatch {
	return HttpMatch{
		methods: pipeline.match.methods.clone()
		hosts:   pipeline.match.hosts.clone()
		paths:   pipeline.match.paths.clone()
		query:   pipeline.match.query.clone()
		headers: pipeline.match.headers.clone()
	}
}

pub fn listener_pipeline_descriptors(plan runtime_plan.RuntimePlan, listener_id string) []PipelineDescriptor {
	return plan.listener_pipelines(listener_id).map(pipeline_descriptor_from_plan(it))
}

pub fn listener_pipeline_descriptors_with_adapters(plan runtime_plan.RuntimePlan, listener_id string, adapters map[string]AdapterDescriptor) []PipelineDescriptor {
	return plan.listener_pipelines(listener_id).map(pipeline_descriptor_from_plan_with_adapters(it,
		adapters))
}

pub fn match_basic_http_pipeline(plan runtime_plan.RuntimePlan, listener_id string, exchange Exchange) ?PipelineDescriptor {
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.match.path_regexp.trim_space() != '' {
			continue
		}
		matcher := http_match_from_plan(pipeline)
		if http_exchange_matches(exchange, matcher) {
			return pipeline_descriptor_from_plan(pipeline)
		}
	}
	return none
}

pub fn match_basic_http_pipeline_with_adapters(plan runtime_plan.RuntimePlan, listener_id string, exchange Exchange, adapters map[string]AdapterDescriptor) ?PipelineDescriptor {
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.match.path_regexp.trim_space() != '' {
			continue
		}
		matcher := http_match_from_plan(pipeline)
		if http_exchange_matches(exchange, matcher) {
			return pipeline_descriptor_from_plan_with_adapters(pipeline, adapters)
		}
	}
	return none
}
