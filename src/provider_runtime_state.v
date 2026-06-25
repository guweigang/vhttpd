module main

import json
import provider
import upstream
import codex

pub fn (mut app App) provider_runtime_snapshot(name string) ?string {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name {
			json.encode(app.providers.feishu_runtime_snapshot())
		}
		codex_name {
			json.encode(app.providers.admin_codex_snapshot(app.transport.db.enabled))
		}
		db_name {
			app.db_runtime_snapshot()
		}
		else {
			mut spec := app.get_provider_spec(name) or { return none }
			spec.runtime.snapshot(mut spec.lifecycle_ctx)
		}
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_upstream_snapshot(name string, instance string, db_transport_enabled bool) ?upstream.UpstreamSnapshot {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	return match name {
		feishu_name {
			snapshot := hub.feishu_runtime_app_snapshot(instance) or { return none }
			provider.UpstreamRuntimeMapper.from_feishu_snapshot(snapshot)
		}
		codex_name {
			mut resolved_instance := instance.trim_space()
			if resolved_instance == '' {
				resolved_instance = 'main'
			}
			state := hub.codex_runtime_state_view(resolved_instance)
			enabled := hub.provider_runtime_upstream_enabled(codex_name, resolved_instance,
				db_transport_enabled)
			return provider.UpstreamRuntimeMapper.from_codex_state(resolved_instance, state,
				enabled)
		}
		else {
			none
		}
	}
}

pub fn (mut app App) provider_runtime_upstream_snapshot(name string, instance string) ?upstream.UpstreamSnapshot {
	return app.providers.provider_runtime_upstream_snapshot(name, instance,
		app.transport.db.enabled)
}

fn (mut hub ProviderRuntimeHub) provider_runtime_upstream_snapshots(name string, db_transport_enabled bool) []upstream.UpstreamSnapshot {
	mut snapshots := []upstream.UpstreamSnapshot{}
	for instance in hub.provider_runtime_instances(name, db_transport_enabled) {
		if snapshot := hub.provider_runtime_upstream_snapshot(name, instance, db_transport_enabled) {
			snapshots << snapshot
		}
	}
	return snapshots
}

pub fn (mut app App) provider_runtime_upstream_snapshots(name string) []upstream.UpstreamSnapshot {
	return app.providers.provider_runtime_upstream_snapshots(name, app.transport.db.enabled)
}

fn (mut hub ProviderRuntimeHub) provider_runtime_upstream_events(name string, instance_filter string) []upstream.UpstreamEventSnapshot {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	return match name {
		feishu_name {
			provider.UpstreamRuntimeMapper.events_from_feishu_snapshot(hub.feishu_runtime_snapshot(),
				instance_filter)
		}
		codex_name {
			[]upstream.UpstreamEventSnapshot{}
		}
		else {
			[]upstream.UpstreamEventSnapshot{}
		}
	}
}

pub fn (mut app App) provider_runtime_upstream_events(name string, instance_filter string) []upstream.UpstreamEventSnapshot {
	return app.providers.provider_runtime_upstream_events(name, instance_filter)
}

fn (mut hub ProviderRuntimeHub) provider_runtime_metrics(name string, db_transport_enabled bool) provider.ProviderRuntimeMetrics {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	return match name {
		feishu_name {
			connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors :=
				hub.feishu.totals()
			provider.ProviderRuntimeMetrics.from_feishu_totals(connect_attempts, connect_successes,
				received_frames, acked_events, messages_sent, send_errors)
		}
		codex_name {
			mut instances := hub.provider_runtime_instances(codex_name, db_transport_enabled)
			if instances.len == 0 {
				instances = ['main']
			}
			mut states := []codex.RuntimeStateView{cap: instances.len}
			for instance in instances {
				states << hub.codex_runtime_state_view(instance)
			}
			provider.ProviderRuntimeMetrics.from_codex_states(states)
		}
		else {
			provider.ProviderRuntimeMetrics{}
		}
	}
}

pub fn (mut app App) provider_runtime_metrics(name string) provider.ProviderRuntimeMetrics {
	return app.providers.provider_runtime_metrics(name, app.transport.db.enabled)
}
