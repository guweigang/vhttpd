module provider

import time

// instance_upsert creates or updates a provider instance spec in the store.
pub fn instance_upsert(mut specs map[string]ProviderInstanceSpec, spec ProviderInstanceSpec) ProviderInstanceSpec {
	key := instance_key(spec.provider, spec.instance)
	now_ms := time.now().unix_milli()
	existing := specs[key] or { ProviderInstanceSpec{} }
	next := ProviderInstanceSpec{
		provider:      spec.provider.trim_space()
		instance:      normalize_instance_name(spec.instance)
		config_json:   spec.config_json
		desired_state: if spec.desired_state.trim_space() == '' {
			'connected'
		} else {
			spec.desired_state.trim_space()
		}
		created_at: if existing.created_at > 0 { existing.created_at } else { now_ms }
		updated_at: now_ms
	}
	specs[key] = next
	return next
}

// instance_get retrieves a provider instance spec by name.
pub fn instance_get(specs map[string]ProviderInstanceSpec, provider_name string, instance string) ?ProviderInstanceSpec {
	key := instance_key(provider_name, instance)
	if key !in specs {
		return none
	}
	return specs[key]
}

// instance_list returns provider instance specs, optionally filtered by provider name.
pub fn instance_list(specs map[string]ProviderInstanceSpec, provider_name string) []ProviderInstanceSpec {
	mut out := []ProviderInstanceSpec{}
	for _, spec in specs {
		if provider_name.trim_space() != '' && spec.provider != provider_name.trim_space() {
			continue
		}
		out << spec
	}
	out.sort_with_compare(fn (a &ProviderInstanceSpec, b &ProviderInstanceSpec) int {
		left := '${a.provider}/${a.instance}'
		right := '${b.provider}/${b.instance}'
		if left < right {
			return -1
		}
		if left > right {
			return 1
		}
		return 0
	})
	return out
}
