module main

import config
import provider
import json

type ProviderInstanceSpec = provider.ProviderInstanceSpec
type ProviderInstanceRegistry = provider.ProviderInstanceRegistry
type AdminProviderInstanceSnapshot = provider.AdminProviderInstanceSnapshot

struct ProviderInstanceStaticSpec {
	spec   ProviderInstanceSpec
	source string
}

struct ProviderInstanceRuntimeContext {
	runtime_snapshot_fn fn (string, string) (WebSocketUpstreamSnapshot, bool) = unsafe { nil }
	source_fn           fn (string, string) string                = unsafe { nil }
	static_specs_fn     fn () []ProviderInstanceStaticSpec        = unsafe { nil }
	static_spec_fn      fn (string, string) ?ProviderInstanceSpec = unsafe { nil }
	apply_fn            fn (ProviderInstanceSpec) !               = unsafe { nil }
	provider_enabled_fn fn (string) bool = unsafe { nil }
}

struct ProviderInstanceRuntime {}

fn (ctx ProviderInstanceRuntimeContext) runtime_snapshot(provider_name string, instance string) (WebSocketUpstreamSnapshot, bool) {
	return ctx.runtime_snapshot_fn(provider_name, instance)
}

fn (ctx ProviderInstanceRuntimeContext) source(provider_name string, instance string) string {
	return ctx.source_fn(provider_name, instance)
}

fn (ctx ProviderInstanceRuntimeContext) static_specs() []ProviderInstanceStaticSpec {
	return ctx.static_specs_fn()
}

fn (ctx ProviderInstanceRuntimeContext) static_spec(provider_name string, instance string) ?ProviderInstanceSpec {
	return ctx.static_spec_fn(provider_name, instance)
}

fn (ctx ProviderInstanceRuntimeContext) apply(spec ProviderInstanceSpec) ! {
	ctx.apply_fn(spec)!
}

fn (ctx ProviderInstanceRuntimeContext) provider_enabled(provider_name string) bool {
	return ctx.provider_enabled_fn(provider_name)
}

fn (mut app App) build_provider_instance_runtime_context() ProviderInstanceRuntimeContext {
	return ProviderInstanceRuntimeContext{
		runtime_snapshot_fn: fn [mut app] (provider_name string, instance string) (WebSocketUpstreamSnapshot, bool) {
			return app.provider_instance_runtime_snapshot(provider_name, instance)
		}
		source_fn:           fn [mut app] (provider_name string, instance string) string {
			return match provider_name {
				'feishu' { app.feishu_runtime_app_source(instance) }
				'codex' { 'dynamic' }
				else { 'dynamic' }
			}
		}
		static_specs_fn:     fn [mut app] () []ProviderInstanceStaticSpec {
			mut specs := []ProviderInstanceStaticSpec{}
			for name, cfg in app.feishu.static_apps {
				specs << ProviderInstanceStaticSpec{
					source: 'static'
					spec:   ProviderInstanceSpec{
						provider:      'feishu'
						instance:      name
						config_json:   json.encode(cfg)
						desired_state: 'connected'
					}
				}
			}
			return specs
		}
		static_spec_fn:      fn [mut app] (provider_name string, instance string) ?ProviderInstanceSpec {
			if provider_name == 'feishu' {
				if cfg := app.feishu.apps[instance] {
					return ProviderInstanceSpec{
						provider:      'feishu'
						instance:      instance
						config_json:   json.encode(cfg)
						desired_state: 'connected'
					}
				}
			}
			return none
		}
		apply_fn:            fn [mut app] (spec ProviderInstanceSpec) ! {
			match spec.provider {
				'feishu' {
					if spec.config_json.trim_space() == '' {
						return
					}
					cfg := json.decode(config.FeishuAppConfig, spec.config_json) or {
						return error('provider_instance_invalid_feishu_config:${err}')
					}
					app.feishu.apps[spec.instance] = cfg
					app.feishu_runtime_ensure(spec.instance)
					_ = app.ensure_websocket_upstream_provider_running('feishu', spec.instance)
				}
				'codex' {
					if spec.config_json.trim_space() == '' {
						return
					}
					cfg := json.decode(config.CodexConfig, spec.config_json) or {
						return error('provider_instance_invalid_codex_config:${err}')
					}
					mut rt := app.codex_runtime_ensure_instance(spec.instance)
					if cfg.url.trim_space() != '' {
						rt.url = cfg.url
					}
					if cfg.model.trim_space() != '' {
						rt.model = cfg.model
					}
					if cfg.effort.trim_space() != '' {
						rt.effort = cfg.effort
					}
					if cfg.cwd.trim_space() != '' {
						rt.cwd = cfg.cwd
					}
					if cfg.approval_policy.trim_space() != '' {
						rt.approval_policy = cfg.approval_policy
					}
					if cfg.sandbox.trim_space() != '' {
						rt.sandbox = cfg.sandbox
					}
					if cfg.reconnect_delay_ms > 0 {
						rt.reconnect_delay_ms = cfg.reconnect_delay_ms
					}
					if cfg.flush_interval_ms > 0 {
						rt.flush_interval_ms = cfg.flush_interval_ms
					}
					app.codex_runtime_update(spec.instance, rt)
					_ = app.ensure_websocket_upstream_provider_running('codex', spec.instance)
				}
				else {}
			}
		}
		provider_enabled_fn: fn [mut app] (provider_name string) bool {
			return app.provider_enabled(provider_name)
		}
	}
}

fn (mut app App) provider_instance_runtime_snapshot(provider_name string, instance string) (WebSocketUpstreamSnapshot, bool) {
	if snapshot := app.provider_runtime_upstream_snapshot(provider_name, instance) {
		return snapshot, true
	}
	return WebSocketUpstreamSnapshot{}, false
}

pub fn (mut app App) provider_instance_upsert(spec ProviderInstanceSpec) ProviderInstanceSpec {
	return app.provider_instances.upsert(spec)
}

pub fn (app &App) provider_instance_get(provider_name string, instance string) ?ProviderInstanceSpec {
	return app.provider_instances.get(provider_name, instance)
}

pub fn (app &App) provider_instance_list(provider_name string) []ProviderInstanceSpec {
	return app.provider_instances.list(provider_name)
}

fn ProviderInstanceRuntime.admin_snapshots(registry ProviderInstanceRegistry, ctx ProviderInstanceRuntimeContext, provider_filter string) []AdminProviderInstanceSnapshot {
	filter := provider_filter.trim_space()
	mut out := []AdminProviderInstanceSnapshot{}
	for _, spec in registry.specs {
		if filter != '' && spec.provider != filter {
			continue
		}
		upstream, upstream_ok := ctx.runtime_snapshot(spec.provider, spec.instance)
		out << AdminProviderInstanceSnapshot{
			provider:           spec.provider
			instance:           spec.instance
			source:             ctx.source(spec.provider, spec.instance)
			stored:             true
			runtime_configured: upstream_ok && upstream.configured
			runtime_connected:  upstream_ok && upstream.connected
			runtime_url:        if upstream_ok { upstream.url } else { '' }
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
		upstream, upstream_ok := ctx.runtime_snapshot(spec.provider, spec.instance)
		out << AdminProviderInstanceSnapshot{
			provider:           spec.provider
			instance:           spec.instance
			source:             static_item.source
			stored:             false
			runtime_configured: upstream_ok && upstream.configured
			runtime_connected:  upstream_ok && upstream.connected
			runtime_url:        if upstream_ok { upstream.url } else { '' }
			config_present:     spec.config_json.trim_space() != ''
			config_fields:      spec.config_fields()
			desired_state:      spec.desired_state_or_default()
			created_at:         0
			updated_at:         0
		}
	}
	out.sort_with_compare(fn (a &AdminProviderInstanceSnapshot, b &AdminProviderInstanceSnapshot) int {
		left := ProviderInstanceSpec.key_for(a.provider, a.instance)
		right := ProviderInstanceSpec.key_for(b.provider, b.instance)
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

pub fn (mut app App) admin_provider_instance_snapshots(provider_filter string) []AdminProviderInstanceSnapshot {
	ctx := app.build_provider_instance_runtime_context()
	return ProviderInstanceRuntime.admin_snapshots(app.provider_instances, ctx, provider_filter)
}

fn ProviderInstanceRuntime.apply(ctx ProviderInstanceRuntimeContext, spec ProviderInstanceSpec) ! {
	ctx.apply(spec)!
}

pub fn (mut app App) provider_instance_apply(spec ProviderInstanceSpec) ! {
	ctx := app.build_provider_instance_runtime_context()
	ProviderInstanceRuntime.apply(ctx, spec)!
}

fn ProviderInstanceRuntime.ensure(mut registry ProviderInstanceRegistry, ctx ProviderInstanceRuntimeContext, provider_name string, instance string) !ProviderInstanceSpec {
	normalized_instance := ProviderInstanceSpec.normalize_instance_name(instance)
	if spec := registry.get(provider_name, normalized_instance) {
		if provider_name in ['codex', 'feishu'] {
			ProviderInstanceRuntime.apply(ctx, spec) or {}
		}
		return spec
	}
	if static_spec := ctx.static_spec(provider_name, normalized_instance) {
		spec := registry.upsert(static_spec)
		ProviderInstanceRuntime.apply(ctx, spec) or {}
		return spec
	}
	if provider_name == 'codex' && normalized_instance == 'main' && ctx.provider_enabled('codex') {
		return registry.upsert(ProviderInstanceSpec{
			provider:      'codex'
			instance:      'main'
			config_json:   ''
			desired_state: 'connected'
		})
	}
	return error('provider_instance_not_found:${provider_name}/${normalized_instance}')
}

pub fn (mut app App) provider_instance_ensure(provider_name string, instance string) !ProviderInstanceSpec {
	ctx := app.build_provider_instance_runtime_context()
	return ProviderInstanceRuntime.ensure(mut app.provider_instances, ctx, provider_name, instance)
}
