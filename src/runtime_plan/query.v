module runtime_plan

pub fn listener_id_or_default(listener_id string) string {
	return if listener_id.trim_space() == '' { 'default' } else { listener_id }
}

pub fn (plan RuntimePlan) first_listener_id_or_default() string {
	if 'default' in plan.listeners {
		return 'default'
	}
	mut ids := plan.listeners.keys()
	ids.sort()
	if ids.len == 0 {
		return 'default'
	}
	return ids[0]
}

pub fn (plan RuntimePlan) listener_or_default(listener_id string) ?ListenerPlan {
	target_listener_id := if listener_id.trim_space() == '' {
		plan.first_listener_id_or_default()
	} else {
		listener_id
	}
	return plan.listeners[target_listener_id] or { none }
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

pub fn (plan RuntimePlan) relay_pipelines(relay_id string) []PipelinePlan {
	target_relay_id := relay_id.trim_space()
	mut pipelines := []PipelinePlan{}
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain == .relay && pipeline.ingress.id == target_relay_id {
			pipelines << pipeline
		}
	}
	return pipelines
}

pub fn (plan RuntimePlan) relay_ids_for_listener(listener_id string) []string {
	target_listener_id := listener_id.trim_space()
	mut ids := []string{}
	for relay_id, relay in plan.relays {
		ingress := relay.ingress or { continue }
		if ingress.domain == .listener && ingress.id == target_listener_id {
			ids << relay_id
		}
	}
	ids.sort()
	return ids
}

pub fn (plan RuntimePlan) listener_relay_delivery_target_ids(listener_id string) []string {
	mut ids := []string{}
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind != 'relay-delivery' {
			continue
		}
		target := adapter.options.strings['target']
		reference := parse_ref(target) or { continue }
		if reference.domain != .relay || reference.id !in plan.relays {
			continue
		}
		if reference.id !in ids {
			ids << reference.id
		}
	}
	ids.sort()
	return ids
}

pub fn (plan RuntimePlan) listener_has_relay_delivery_target(listener_id string, relay_id string) bool {
	target := 'relay:${relay_id.trim_space()}'
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind == 'relay-delivery' && adapter.options.strings['target'] == target {
			return true
		}
	}
	return false
}

pub fn (plan RuntimePlan) relay_delivery_owner_listener_ids(websocket_listener_id string) []string {
	mut owners := []string{}
	for relay_id in plan.relay_ids_for_listener(websocket_listener_id) {
		mut listener_ids := plan.listeners.keys()
		listener_ids.sort()
		for listener_id in listener_ids {
			listener := plan.listeners[listener_id]
			if listener.protocol.trim_space().to_lower() == 'websocket' {
				continue
			}
			if plan.listener_has_relay_delivery_target(listener_id, relay_id)
				&& listener_id !in owners {
				owners << listener_id
			}
		}
	}
	return owners
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

pub fn (plan RuntimePlan) first_adapter_by_kind(kind string) ?AdapterPlan {
	mut ids := plan.adapters.keys()
	ids.sort()
	for id in ids {
		adapter := plan.adapters[id]
		if adapter.kind == kind {
			return adapter
		}
	}
	return none
}

pub fn (plan RuntimePlan) first_relay_by_carrier(carrier string) ?RelayPlan {
	mut ids := plan.relays.keys()
	ids.sort()
	for id in ids {
		relay := plan.relays[id]
		if relay.carrier == carrier {
			return relay
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
	engines := plan.listener_http_handler_engines(listener_id)
	for engine in engines {
		if engine_id_matches_executor_name(engine.id, 'default') {
			return engine
		}
	}
	for engine in engines {
		if engine.kind.trim_space().to_lower().replace('_', '-') != 'php-cgi' {
			return engine
		}
	}
	if engines.len > 0 {
		return engines[0]
	}
	return none
}

fn (plan RuntimePlan) listener_http_handler_engines(listener_id string) []EnginePlan {
	mut engines := []EnginePlan{}
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind != 'http-handler' {
			continue
		}
		engine_ref := adapter.engine or { continue }
		if engine_ref.domain != .engine {
			continue
		}
		engine := plan.engines[engine_ref.id] or { continue }
		if !engines.any(it.id == engine.id) {
			engines << engine
		}
	}
	return engines
}

pub fn (plan RuntimePlan) listener_resource(listener_id string, category string) ?ResourcePlan {
	mut engines := []EnginePlan{}
	if engine := plan.listener_fallback_engine(listener_id) {
		engines << engine
	}
	for engine in plan.listener_http_handler_engines(listener_id) {
		if !engines.any(it.id == engine.id) {
			engines << engine
		}
	}
	for engine in engines {
		for reference in engine.resources {
			if reference.domain != .resource {
				continue
			}
			resource := plan.resources[reference.id] or { continue }
			if resource.category == category {
				return resource
			}
		}
	}
	return none
}

pub fn (plan RuntimePlan) listener_named_engine(listener_id string, executor_name string) ?EnginePlan {
	normalized_executor := executor_name.trim_space()
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		engine_ref := adapter.engine or { continue }
		if engine_ref.domain != .engine
			|| !engine_id_matches_executor_name(engine_ref.id, normalized_executor) {
			continue
		}
		return plan.engines[engine_ref.id] or { continue }
	}
	for transform in plan.listener_transform_plans(listener_id) {
		engine_ref := transform.engine or { continue }
		if engine_ref.domain != .engine
			|| !engine_id_matches_executor_name(engine_ref.id, normalized_executor) {
			continue
		}
		return plan.engines[engine_ref.id] or { continue }
	}
	if plan.source.compatibility {
		for _, transform in plan.transforms {
			engine_ref := transform.engine or { continue }
			if engine_ref.domain != .engine
				|| !engine_id_matches_executor_name(engine_ref.id, normalized_executor) {
				continue
			}
			return plan.engines[engine_ref.id] or { continue }
		}
	}
	return none
}

fn (plan RuntimePlan) listener_transform_plans(listener_id string) []TransformPlan {
	mut transforms := []TransformPlan{}
	mut seen := map[string]bool{}
	for pipeline in plan.listener_pipelines(listener_id) {
		plan.append_pipeline_transform_plans(pipeline, mut transforms, mut seen)
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		completed_pipeline := adapter.options.strings['completed_pipeline']
		reference := parse_ref(completed_pipeline) or { continue }
		if reference.domain != .pipeline {
			continue
		}
		event_pipeline := plan.pipeline(reference.id) or { continue }
		plan.append_pipeline_transform_plans(event_pipeline, mut transforms, mut seen)
	}
	return transforms
}

fn (plan RuntimePlan) append_pipeline_transform_plans(pipeline PipelinePlan, mut transforms []TransformPlan, mut seen map[string]bool) {
	for reference in pipeline.transforms {
		if reference.domain != .transform || seen[reference.id] {
			continue
		}
		transform := plan.transforms[reference.id] or { continue }
		seen[reference.id] = true
		transforms << transform
	}
}

fn engine_id_matches_executor_name(engine_id string, executor_name string) bool {
	if executor_name == '' {
		return false
	}
	return engine_id == executor_name || engine_id.ends_with('/${executor_name}')
}
