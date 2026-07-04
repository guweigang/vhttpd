module runtime_plan

pub struct PlanReplacementDiff {
pub:
	allowed             bool
	unchanged_pipelines []string
	changed_pipelines   []string
	restart_listeners   []string
	drain_engines       []string
	reload_transforms   []string
	reload_providers    []string
	reload_relays       []string
	reasons             []string
}

pub struct PlanReplacementExecutionPlan {
pub:
	allowed  bool
	strategy string
	error    string
	actions  []PlanReplacementAction
	diff     PlanReplacementDiff
}

pub struct PlanReplacementAction {
pub:
	kind    string
	targets []string
}

pub fn diff_runtime_plan_replacement(old RuntimePlan, new RuntimePlan) PlanReplacementDiff {
	changed_listeners := changed_listener_ids(old, new)
	changed_resources := changed_resource_ids(old, new)
	changed_engines := changed_engine_ids(old, new)
	drain_engines := drain_engine_ids_for_replacement(old, new, changed_engines)
	changed_adapters := changed_adapter_ids(old, new)
	changed_transforms := changed_transform_ids(old, new, changed_engines)
	changed_policies := changed_policy_ids(old, new)
	changed_providers := changed_provider_ids(old, new, changed_engines)
	changed_relays := changed_relay_ids(old, new)
	mut unchanged_pipelines := []string{}
	mut changed_pipelines := []string{}
	mut pipeline_ids := pipeline_id_union(old, new)
	for pipeline_id in pipeline_ids {
		if old_pipeline := old.pipeline(pipeline_id) {
			if new_pipeline := new.pipeline(pipeline_id) {
				if pipeline_affected_by_replacement(old_pipeline, new_pipeline, changed_listeners,
					changed_adapters, changed_transforms, changed_policies, changed_relays,
					changed_engines, changed_resources, old, new)
				{
					changed_pipelines << pipeline_id
				} else {
					unchanged_pipelines << pipeline_id
				}
				continue
			}
		}
		changed_pipelines << pipeline_id
	}
	reasons := unsafe_transform_replacement_reasons(old, new, changed_transforms)
	return PlanReplacementDiff{
		allowed:             reasons.len == 0
		unchanged_pipelines: unchanged_pipelines
		changed_pipelines:   changed_pipelines
		restart_listeners:   changed_listeners
		drain_engines:       drain_engines
		reload_transforms:   changed_transforms
		reload_providers:    changed_providers
		reload_relays:       changed_relays
		reasons:             reasons
	}
}

fn drain_engine_ids_for_replacement(old RuntimePlan, new RuntimePlan, changed_engines []string) []string {
	mut adapter_engine_ids := map[string]bool{}
	for _, adapter in old.adapters {
		if engine := adapter.engine {
			if engine.domain == .engine {
				adapter_engine_ids[engine.id] = true
			}
		}
	}
	for _, adapter in new.adapters {
		if engine := adapter.engine {
			if engine.domain == .engine {
				adapter_engine_ids[engine.id] = true
			}
		}
	}
	mut out := []string{}
	for id in changed_engines {
		if adapter_engine_ids[id] {
			out << id
		}
	}
	return out
}

pub fn execution_plan_for_replacement(diff PlanReplacementDiff) PlanReplacementExecutionPlan {
	mut actions := []PlanReplacementAction{}
	if diff.changed_pipelines.len > 0 || diff.reload_transforms.len > 0
		|| diff.reload_providers.len > 0 {
		actions << PlanReplacementAction{
			kind:    'swap_lightweight_runtime'
			targets: map_key_union(map_key_union(diff.changed_pipelines, diff.reload_transforms),
				diff.reload_providers)
		}
	}
	if diff.restart_listeners.len > 0 {
		actions << PlanReplacementAction{
			kind:    'restart_listeners'
			targets: diff.restart_listeners.clone()
		}
	}
	if diff.drain_engines.len > 0 {
		actions << PlanReplacementAction{
			kind:    'drain_engines'
			targets: diff.drain_engines.clone()
		}
	}
	if diff.reload_relays.len > 0 {
		actions << PlanReplacementAction{
			kind:    'reload_relays'
			targets: diff.reload_relays.clone()
		}
	}
	if !diff.allowed {
		return PlanReplacementExecutionPlan{
			allowed:  false
			strategy: 'blocked'
			error:    'runtime_plan_replacement_unsafe'
			actions:  actions
			diff:     diff
		}
	}
	if diff.restart_listeners.len > 0 {
		return PlanReplacementExecutionPlan{
			allowed:  false
			strategy: 'listener_restart_required'
			error:    'runtime_plan_replacement_requires_listener_restart'
			actions:  actions
			diff:     diff
		}
	}
	if diff.drain_engines.len > 0 {
		return PlanReplacementExecutionPlan{
			allowed:  false
			strategy: 'engine_drain_required'
			error:    'runtime_plan_replacement_requires_engine_drain'
			actions:  actions
			diff:     diff
		}
	}
	if diff.reload_relays.len > 0 {
		return PlanReplacementExecutionPlan{
			allowed:  false
			strategy: 'relay_reload_required'
			error:    'runtime_plan_replacement_requires_relay_reload'
			actions:  actions
			diff:     diff
		}
	}
	return PlanReplacementExecutionPlan{
		allowed:  true
		strategy: 'lightweight'
		actions:  actions
		diff:     diff
	}
}

fn pipeline_affected_by_replacement(old_pipeline PipelinePlan, new_pipeline PipelinePlan, changed_listeners []string, changed_adapters []string, changed_transforms []string, changed_policies []string, changed_relays []string, changed_engines []string, changed_resources []string, old RuntimePlan, new RuntimePlan) bool {
	if pipeline_fingerprint(old_pipeline) != pipeline_fingerprint(new_pipeline) {
		return true
	}
	if new_pipeline.ingress.domain == .listener && new_pipeline.ingress.id in changed_listeners {
		return true
	}
	if new_pipeline.ingress.domain == .relay && new_pipeline.ingress.id in changed_relays {
		return true
	}
	if new_pipeline.egress.domain == .adapter && new_pipeline.egress.id in changed_adapters {
		return true
	}
	for transform_ref in new_pipeline.transforms {
		if transform_ref.domain == .transform && transform_ref.id in changed_transforms {
			return true
		}
	}
	for policy_ref in new_pipeline.policies {
		if policy_ref.domain == .policy && policy_ref.id in changed_policies {
			return true
		}
	}
	return pipeline_depends_on_changed_engine_or_resource(new_pipeline, changed_engines,
		changed_resources, old, new)
}

fn pipeline_depends_on_changed_engine_or_resource(pipeline PipelinePlan, changed_engines []string, changed_resources []string, old RuntimePlan, new RuntimePlan) bool {
	mut engine_ids := []string{}
	if pipeline.egress.domain == .adapter {
		if adapter := new.adapters[pipeline.egress.id] {
			if engine := adapter.engine {
				engine_ids << engine.id
			}
		}
	}
	for transform_ref in pipeline.transforms {
		if transform_ref.domain != .transform {
			continue
		}
		if transform := new.transforms[transform_ref.id] {
			if engine := transform.engine {
				engine_ids << engine.id
			}
		}
	}
	for engine_id in engine_ids {
		if engine_id in changed_engines {
			return true
		}
		engine := new.engines[engine_id] or { continue }
		for resource_ref in engine.resources {
			if resource_ref.domain == .resource && resource_ref.id in changed_resources {
				return true
			}
		}
		old_engine := old.engines[engine_id] or { continue }
		for resource_ref in old_engine.resources {
			if resource_ref.domain == .resource && resource_ref.id in changed_resources {
				return true
			}
		}
	}
	return false
}

fn unsafe_transform_replacement_reasons(old RuntimePlan, new RuntimePlan, changed_transforms []string) []string {
	mut reasons := []string{}
	for id in changed_transforms {
		old_transform := old.transforms[id] or { TransformPlan{} }
		new_transform := new.transforms[id] or { TransformPlan{} }
		if transform_hot_switch_allowed(old_transform, new_transform) {
			continue
		}
		reasons << 'stateful_transform_requires_external_state_or_migration:${id}'
	}
	return reasons
}

fn transform_hot_switch_allowed(old TransformPlan, new TransformPlan) bool {
	if !transform_is_stateful(old) && !transform_is_stateful(new) {
		return true
	}
	return transform_state_externalized(new) || transform_state_externalized(old)
}

fn transform_is_stateful(transform TransformPlan) bool {
	return transform.options.bools['stateful'] or { false }
}

fn transform_state_externalized(transform TransformPlan) bool {
	if transform.options.bools['externalized_state'] or { false } {
		return true
	}
	if (transform.options.strings['migration_hook'] or { '' }).trim_space() != '' {
		return true
	}
	return false
}

fn changed_listener_ids(old RuntimePlan, new RuntimePlan) []string {
	mut ids := map_key_union(old.listeners.keys(), new.listeners.keys())
	mut out := []string{}
	for id in ids {
		if listener_fingerprint(old.listeners[id] or { ListenerPlan{} }) != listener_fingerprint(new.listeners[id] or {
			ListenerPlan{}
		}) {
			out << id
		}
	}
	return out
}

fn changed_resource_ids(old RuntimePlan, new RuntimePlan) []string {
	mut ids := map_key_union(old.resources.keys(), new.resources.keys())
	mut out := []string{}
	for id in ids {
		if resource_fingerprint(old.resources[id] or { ResourcePlan{} }) != resource_fingerprint(new.resources[id] or {
			ResourcePlan{}
		}) {
			out << id
		}
	}
	return out
}

fn changed_engine_ids(old RuntimePlan, new RuntimePlan) []string {
	mut ids := map_key_union(old.engines.keys(), new.engines.keys())
	mut out := []string{}
	for id in ids {
		if engine_fingerprint(old.engines[id] or { EnginePlan{} }) != engine_fingerprint(new.engines[id] or {
			EnginePlan{}
		}) {
			out << id
		}
	}
	return out
}

fn changed_adapter_ids(old RuntimePlan, new RuntimePlan) []string {
	mut ids := map_key_union(old.adapters.keys(), new.adapters.keys())
	mut out := []string{}
	for id in ids {
		if adapter_fingerprint(old.adapters[id] or { AdapterPlan{} }) != adapter_fingerprint(new.adapters[id] or {
			AdapterPlan{}
		}) {
			out << id
		}
	}
	return out
}

fn changed_transform_ids(old RuntimePlan, new RuntimePlan, changed_engines []string) []string {
	mut ids := map_key_union(old.transforms.keys(), new.transforms.keys())
	mut out := []string{}
	for id in ids {
		old_transform := old.transforms[id] or { TransformPlan{} }
		new_transform := new.transforms[id] or { TransformPlan{} }
		if transform_fingerprint(old_transform) != transform_fingerprint(new_transform)
			|| optional_ref_engine_changed(old_transform.engine, new_transform.engine, changed_engines) {
			out << id
		}
	}
	return out
}

fn changed_policy_ids(old RuntimePlan, new RuntimePlan) []string {
	mut ids := map_key_union(old.policies.keys(), new.policies.keys())
	mut out := []string{}
	for id in ids {
		if policy_fingerprint(old.policies[id] or { PolicyPlan{} }) != policy_fingerprint(new.policies[id] or {
			PolicyPlan{}
		}) {
			out << id
		}
	}
	return out
}

fn changed_provider_ids(old RuntimePlan, new RuntimePlan, changed_engines []string) []string {
	mut ids := map_key_union(old.providers.keys(), new.providers.keys())
	mut out := []string{}
	for id in ids {
		old_provider := old.providers[id] or { ProviderPlan{} }
		new_provider := new.providers[id] or { ProviderPlan{} }
		if provider_fingerprint(old_provider) != provider_fingerprint(new_provider)
			|| optional_ref_engine_changed(old_provider.engine, new_provider.engine, changed_engines) {
			out << id
		}
	}
	return out
}

fn optional_ref_engine_changed(old_ref ?ResourceRef, new_ref ?ResourceRef, changed_engines []string) bool {
	if old_engine := old_ref {
		if old_engine.domain == .engine && old_engine.id in changed_engines {
			return true
		}
	}
	if new_engine := new_ref {
		if new_engine.domain == .engine && new_engine.id in changed_engines {
			return true
		}
	}
	return false
}

fn changed_relay_ids(old RuntimePlan, new RuntimePlan) []string {
	mut ids := map_key_union(old.relays.keys(), new.relays.keys())
	mut out := []string{}
	for id in ids {
		if relay_fingerprint(old.relays[id] or { RelayPlan{} }) != relay_fingerprint(new.relays[id] or {
			RelayPlan{}
		}) {
			out << id
		}
	}
	return out
}

fn pipeline_id_union(old RuntimePlan, new RuntimePlan) []string {
	mut ids := []string{}
	for pipeline in old.pipelines {
		if pipeline.id !in ids {
			ids << pipeline.id
		}
	}
	for pipeline in new.pipelines {
		if pipeline.id !in ids {
			ids << pipeline.id
		}
	}
	ids.sort()
	return ids
}

fn map_key_union(left []string, right []string) []string {
	mut ids := []string{}
	for id in left {
		if id !in ids {
			ids << id
		}
	}
	for id in right {
		if id !in ids {
			ids << id
		}
	}
	ids.sort()
	return ids
}

fn listener_fingerprint(value ListenerPlan) string {
	return '${value.id}|${value.protocol}|${value.transport}|${value.host}|${value.port}|${tls_fingerprint(value.tls)}'
}

fn resource_fingerprint(value ResourcePlan) string {
	return '${value.id}|${value.category}|${value.kind}|${options_fingerprint(value.options)}'
}

fn engine_fingerprint(value EnginePlan) string {
	return '${value.id}|${value.kind}|${sorted_refs_fingerprint(value.resources)}|${string_list_fingerprint(value.capabilities)}|${options_fingerprint(value.options)}'
}

fn adapter_fingerprint(value AdapterPlan) string {
	return '${value.id}|${value.kind}|${optional_ref_fingerprint(value.engine)}|${optional_ref_fingerprint(value.storage)}|${options_fingerprint(value.options)}'
}

fn transform_fingerprint(value TransformPlan) string {
	return '${value.id}|${value.kind}|${optional_ref_fingerprint(value.engine)}|${value.handler}|${options_fingerprint(value.options)}'
}

fn policy_fingerprint(value PolicyPlan) string {
	return '${value.id}|${value.category}|${value.kind}|${options_fingerprint(value.options)}'
}

fn provider_fingerprint(value ProviderPlan) string {
	return '${value.id}|${value.driver}|${value.protocol}|${value.plugin}|${optional_ref_fingerprint(value.engine)}|${string_map_fingerprint(value.capabilities)}|${options_fingerprint(value.options)}'
}

fn pipeline_fingerprint(value PipelinePlan) string {
	return '${value.id}|${value.group}|${value.ingress.str()}|${match_fingerprint(value.match)}|${refs_fingerprint(value.transforms)}|${refs_fingerprint(value.policies)}|${value.egress.str()}'
}

fn relay_fingerprint(value RelayPlan) string {
	return '${value.id}|${value.mode}|${value.carrier}|${optional_ref_fingerprint(value.ingress)}|${optional_ref_fingerprint(value.auth)}|${options_fingerprint(value.options)}'
}

fn tls_fingerprint(value TlsPlan) string {
	mut certs := []string{}
	for cert in value.certificates {
		certs << '${string_list_fingerprint(cert.hosts)}:${cert.cert}:${cert.cert_key}'
	}
	certs.sort()
	return '${value.enabled}|${value.cert}|${value.cert_key}|${certs.join(',')}'
}

fn match_fingerprint(value MatchPlan) string {
	return '${string_list_fingerprint(value.methods)}|${string_list_fingerprint(value.hosts)}|${string_list_fingerprint(value.paths)}|${value.path_regexp}|${string_map_fingerprint(value.query)}|${string_map_fingerprint(value.headers)}|${string_map_fingerprint(value.metadata)}'
}

fn optional_ref_fingerprint(value ?ResourceRef) string {
	if ref := value {
		return ref.str()
	}
	return ''
}

fn refs_fingerprint(values []ResourceRef) string {
	mut refs := []string{}
	for value in values {
		refs << value.str()
	}
	return refs.join(',')
}

fn sorted_refs_fingerprint(values []ResourceRef) string {
	mut refs := []string{}
	for value in values {
		refs << value.str()
	}
	refs.sort()
	return refs.join(',')
}

fn options_fingerprint(value PlanOptions) string {
	return 's:${string_map_fingerprint(value.strings)}|i:${int_map_fingerprint(value.ints)}|b:${bool_map_fingerprint(value.bools)}|sl:${string_list_map_fingerprint(value.string_lists)}|sm:${nested_string_map_fingerprint(value.string_maps)}|rl:${record_list_map_fingerprint(value.record_lists)}'
}

fn string_list_fingerprint(values []string) string {
	mut out := values.clone()
	out.sort()
	return out.join(',')
}

fn string_map_fingerprint(values map[string]string) string {
	mut keys := values.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		parts << '${key}=${values[key]}'
	}
	return parts.join(',')
}

fn int_map_fingerprint(values map[string]int) string {
	mut keys := values.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		parts << '${key}=${values[key]}'
	}
	return parts.join(',')
}

fn bool_map_fingerprint(values map[string]bool) string {
	mut keys := values.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		parts << '${key}=${values[key]}'
	}
	return parts.join(',')
}

fn string_list_map_fingerprint(values map[string][]string) string {
	mut keys := values.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		parts << '${key}=[${ordered_string_list_fingerprint(values[key])}]'
	}
	return parts.join(',')
}

fn ordered_string_list_fingerprint(values []string) string {
	return values.join(',')
}

fn nested_string_map_fingerprint(values map[string]map[string]string) string {
	mut keys := values.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		parts << '${key}={${string_map_fingerprint(values[key])}}'
	}
	return parts.join(',')
}

fn record_list_map_fingerprint(values map[string][]map[string]string) string {
	mut keys := values.keys()
	keys.sort()
	mut parts := []string{}
	for key in keys {
		mut records := []string{}
		for record in values[key] {
			records << string_map_fingerprint(record)
		}
		records.sort()
		parts << '${key}=[${records.join(';')}]'
	}
	return parts.join(',')
}
