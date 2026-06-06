module provider

import time

pub fn ProviderInstanceStore.upsert(mut specs map[string]ProviderInstanceSpec, spec ProviderInstanceSpec) ProviderInstanceSpec {
	key := spec.key()
	now_ms := time.now().unix_milli()
	existing := specs[key] or { ProviderInstanceSpec{} }
	next := ProviderInstanceSpec{
		provider:      spec.normalized_provider()
		instance:      spec.normalized_instance()
		config_json:   spec.config_json
		desired_state: spec.desired_state_or_default()
		created_at:    if existing.created_at > 0 { existing.created_at } else { now_ms }
		updated_at:    now_ms
	}
	specs[key] = next
	return next
}

// upsert creates or updates a provider instance spec in the registry.
pub fn (mut registry ProviderInstanceRegistry) upsert(spec ProviderInstanceSpec) ProviderInstanceSpec {
	return ProviderInstanceStore.upsert(mut registry.specs, spec)
}

pub fn ProviderInstanceStore.get(specs map[string]ProviderInstanceSpec, provider_name string, instance string) ?ProviderInstanceSpec {
	key := ProviderInstanceSpec.key_for(provider_name, instance)
	if key !in specs {
		return none
	}
	return specs[key]
}

// get retrieves a provider instance spec by name.
pub fn (registry ProviderInstanceRegistry) get(provider_name string, instance string) ?ProviderInstanceSpec {
	return ProviderInstanceStore.get(registry.specs, provider_name, instance)
}

pub fn ProviderInstanceStore.list(specs map[string]ProviderInstanceSpec, provider_name string) []ProviderInstanceSpec {
	filter_provider := provider_name.trim_space()
	mut out := []ProviderInstanceSpec{}
	for _, spec in specs {
		if filter_provider != '' && spec.provider != filter_provider {
			continue
		}
		out << spec
	}
	out.sort_with_compare(fn (a &ProviderInstanceSpec, b &ProviderInstanceSpec) int {
		left := a.key()
		right := b.key()
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

// list returns provider instance specs, optionally filtered by provider name.
pub fn (registry ProviderInstanceRegistry) list(provider_name string) []ProviderInstanceSpec {
	return ProviderInstanceStore.list(registry.specs, provider_name)
}
