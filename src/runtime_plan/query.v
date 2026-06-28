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
			if plan.listener_has_relay_delivery_target(listener_id, relay_id) && listener_id !in owners {
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
		return plan.engines[engine_ref.id] or { continue }
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
