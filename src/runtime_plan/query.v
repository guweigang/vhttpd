module runtime_plan

pub fn listener_id_or_default(listener_id string) string {
	return if listener_id.trim_space() == '' { 'default' } else { listener_id }
}

pub fn (plan RuntimePlan) listener_pipelines(listener_id string) []PipelinePlan {
	target_listener_id := listener_id_or_default(listener_id)
	mut pipelines := []PipelinePlan{}
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain == .listener && pipeline.ingress.id == target_listener_id {
			pipelines << pipeline
		}
	}
	return pipelines
}

pub fn (plan RuntimePlan) listener_adapter(listener_id string, kind string) ?AdapterPlan {
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind == kind {
			return adapter
		}
	}
	return none
}

pub fn (plan RuntimePlan) listener_fallback_engine(listener_id string) ?EnginePlan {
	for pipeline in plan.listener_pipelines(listener_id) {
		if !pipeline.id.ends_with('_fallback') || pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { return none }
		engine_ref := adapter.engine or { return none }
		if engine_ref.domain != .engine {
			return none
		}
		return plan.engines[engine_ref.id] or { return none }
	}
	return none
}

pub fn (plan RuntimePlan) listener_resource(listener_id string, category string) ?ResourcePlan {
	engine := plan.listener_fallback_engine(listener_id) or { return none }
	for reference in engine.resources {
		if reference.domain != .resource {
			continue
		}
		resource := plan.resources[reference.id] or { continue }
		if resource.category == category {
			return resource
		}
	}
	return none
}

pub fn (plan RuntimePlan) listener_named_engine(listener_id string, executor_name string) ?EnginePlan {
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		engine_ref := adapter.engine or { continue }
		if engine_ref.domain != .engine || !engine_ref.id.ends_with('/${executor_name}') {
			continue
		}
		return plan.engines[engine_ref.id] or { continue }
	}
	for _, transform in plan.transforms {
		engine_ref := transform.engine or { continue }
		if engine_ref.domain != .engine || !engine_ref.id.ends_with('/${executor_name}') {
			continue
		}
		return plan.engines[engine_ref.id] or { continue }
	}
	return none
}
