module main

import json
import provider

struct AdminProviderInstanceUpsertRequest {
	provider      string
	instance      string
	config_json   string @[json: 'config_json']
	desired_state string @[json: 'desired_state']
}

struct AdminProviderInstanceUpsertResponse {
	ok       bool
	status   string
	snapshot provider.AdminProviderInstanceSnapshot
}

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

fn (mut app App) admin_provider_instance_snapshot(provider_name string, instance string) ?provider.AdminProviderInstanceSnapshot {
	normalized_provider := provider_name.trim_space()
	normalized_instance := provider.ProviderInstanceSpec.normalize_instance_name(instance)
	for snapshot in app.admin_provider_instance_snapshots(normalized_provider) {
		if snapshot.provider == normalized_provider && snapshot.instance == normalized_instance {
			return snapshot
		}
	}
	return none
}

fn (mut app App) admin_provider_instance_upsert_from_body(raw string) !AdminProviderInstanceUpsertResponse {
	req := json.decode(AdminProviderInstanceUpsertRequest, raw) or {
		return error('invalid_json')
	}
	normalized_provider := req.provider.trim_space()
	if normalized_provider == '' {
		return error('missing_provider')
	}
	spec := provider.ProviderInstanceSpec{
		provider:      normalized_provider
		instance:      req.instance
		config_json:   req.config_json
		desired_state: req.desired_state
	}
	mut validation_specs := map[string]provider.ProviderInstanceSpec{}
	applied_spec := provider.ProviderInstanceStore.upsert(mut validation_specs, spec)
	app.provider_instance_apply(applied_spec)!
	stored_spec := app.provider_instance_upsert(applied_spec)
	snapshot := app.admin_provider_instance_snapshot(stored_spec.provider, stored_spec.instance) or {
		return error('provider_instance_snapshot_missing:${stored_spec.provider}/${stored_spec.instance}')
	}
	return AdminProviderInstanceUpsertResponse{
		ok:       true
		status:   'upserted'
		snapshot: snapshot
	}
}
