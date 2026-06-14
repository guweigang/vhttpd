module main

import provider

fn ProviderInstanceRuntime.admin_snapshots(registry provider.ProviderInstanceRegistry, ctx ProviderInstanceRuntimeContext, provider_filter string) []provider.AdminProviderInstanceSnapshot {
	filter := provider_filter.trim_space()
	mut out := []provider.AdminProviderInstanceSnapshot{}
	for _, spec in registry.specs {
		if filter != '' && spec.provider != filter {
			continue
		}
		upstream_snap, upstream_ok := ctx.runtime_snapshot(spec.provider, spec.instance)
		out << provider.AdminProviderInstanceSnapshot{
			provider:           spec.provider
			instance:           spec.instance
			source:             ctx.source(spec.provider, spec.instance)
			stored:             true
			runtime_configured: upstream_ok && upstream_snap.configured
			runtime_connected:  upstream_ok && upstream_snap.connected
			runtime_url:        if upstream_ok { upstream_snap.url } else { '' }
			config_present:     spec.config_json.trim_space() != ''
			config_fields:      spec.config_fields()
			desired_state:      spec.desired_state
			created_at:         spec.created_at
			updated_at:         spec.updated_at
		}
	}
	for static_item in ctx.static_specs() {
		spec := static_item.spec
		if filter != '' && spec.provider != filter {
			continue
		}
		if registry.get(spec.provider, spec.instance) != none {
			continue
		}
		upstream_snap, upstream_ok := ctx.runtime_snapshot(spec.provider, spec.instance)
		out << provider.AdminProviderInstanceSnapshot{
			provider:           spec.provider
			instance:           spec.instance
			source:             static_item.source
			stored:             false
			runtime_configured: upstream_ok && upstream_snap.configured
			runtime_connected:  upstream_ok && upstream_snap.connected
			runtime_url:        if upstream_ok { upstream_snap.url } else { '' }
			config_present:     spec.config_json.trim_space() != ''
			config_fields:      spec.config_fields()
			desired_state:      spec.desired_state_or_default()
			created_at:         0
			updated_at:         0
		}
	}
	out.sort_with_compare(fn (a &provider.AdminProviderInstanceSnapshot, b &provider.AdminProviderInstanceSnapshot) int {
		left := provider.ProviderInstanceSpec.key_for(a.provider, a.instance)
		right := provider.ProviderInstanceSpec.key_for(b.provider, b.instance)
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

pub fn (mut app App) admin_provider_instance_snapshots(provider_filter string) []provider.AdminProviderInstanceSnapshot {
	ctx := app.build_provider_instance_runtime_context()
	return ProviderInstanceRuntime.admin_snapshots(app.providers.instances, ctx, provider_filter)
}
