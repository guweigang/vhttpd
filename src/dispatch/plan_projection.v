module dispatch

import runtime_plan

pub fn ingress_descriptor_from_listener_plan(listener runtime_plan.ListenerPlan) IngressDescriptor {
	return IngressDescriptor{
		id:           'listener:${listener.id}'
		capabilities: listener_capabilities(listener.protocol)
	}
}

pub fn ingress_descriptors_from_plan(plan runtime_plan.RuntimePlan) map[string]IngressDescriptor {
	mut descriptors := map[string]IngressDescriptor{}
	for id, listener in plan.listeners {
		descriptors['listener:${id}'] = ingress_descriptor_from_listener_plan(listener)
	}
	for id, adapter in adapter_descriptors_from_plan(plan) {
		if adapter.kind == 'event-ingress' {
			descriptors['adapter:${id}'] = IngressDescriptor{
				id:           'adapter:${id}'
				capabilities: adapter.capabilities
			}
		}
	}
	return descriptors
}

pub fn transform_descriptor_from_plan(transform runtime_plan.TransformPlan) TransformDescriptor {
	return TransformDescriptor{
		id:           transform.id
		kind:         transform.kind
		handler:      transform.handler
		capabilities: transform_capabilities(transform.kind)
	}
}

pub fn transform_descriptors_from_plan(plan runtime_plan.RuntimePlan) map[string]TransformDescriptor {
	mut descriptors := map[string]TransformDescriptor{}
	for id, transform in plan.transforms {
		descriptors[id] = transform_descriptor_from_plan(transform)
	}
	return descriptors
}

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

pub fn pipeline_descriptor_from_plan_with_runtime_descriptors(pipeline runtime_plan.PipelinePlan, adapters map[string]AdapterDescriptor, transforms map[string]TransformDescriptor) PipelineDescriptor {
	_ = transforms
	descriptor := pipeline_descriptor_from_plan_with_adapters(pipeline, adapters)
	return PipelineDescriptor{
		...descriptor
	}
}

pub fn pipeline_capability_errors_from_plan(plan runtime_plan.RuntimePlan) []string {
	adapters := adapter_descriptors_from_plan(plan)
	transforms := transform_descriptors_from_plan(plan)
	ingresses := ingress_descriptors_from_plan(plan)
	mut errors := []string{}
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain !in [.listener, .adapter] {
			continue
		}
		ingress := ingresses[pipeline.ingress.str()] or { continue }
		descriptor := pipeline_descriptor_from_plan_with_runtime_descriptors(pipeline, adapters,
			transforms)
		errors << pipeline_capability_errors(descriptor, ingress)
		errors << pipeline_transform_capability_errors(pipeline, ingress, transforms)
	}
	return errors
}

pub fn pipeline_transform_capability_errors(pipeline runtime_plan.PipelinePlan, ingress IngressDescriptor, transforms map[string]TransformDescriptor) []string {
	mut errors := []string{}
	for reference in pipeline.transforms {
		if reference.domain != .transform {
			continue
		}
		transform := transforms[reference.id] or { continue }
		for missing in missing_capabilities(transform.capabilities, ingress.capabilities) {
			errors << 'pipeline_transform_capability_mismatch:${pipeline.id}:${ingress.id}:transform:${reference.id}:${missing}'
		}
	}
	return errors
}

fn transform_capabilities(kind string) Capabilities {
	match kind.trim_space().to_lower() {
		'native', 'vjsx' {
			return Capabilities{
				request_response: true
				events:           true
			}
		}
		else {
			return Capabilities{
				request_response: true
			}
		}
	}
}

fn listener_capabilities(protocol string) Capabilities {
	match protocol.trim_space().to_lower() {
		'', 'http', 'https' {
			return Capabilities{
				request_response: true
				events:           true
				stream_output:    true
			}
		}
		'websocket', 'ws', 'wss' {
			return Capabilities{
				sessions:     true
				full_duplex:  true
				multiplexing: true
			}
		}
		'mcp' {
			return Capabilities{
				request_response: true
				stream_output:    true
				sessions:         true
			}
		}
		else {
			return Capabilities{
				request_response: true
			}
		}
	}
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
