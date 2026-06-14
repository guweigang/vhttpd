module main

import config
import provider
import json
import upstream

struct ProviderInstanceStaticSpec {
	spec   provider.ProviderInstanceSpec
	source string
}

struct ProviderInstanceRuntimeContext {
	runtime_snapshot_fn fn (string, string) (upstream.UpstreamSnapshot, bool) = unsafe { nil }
	source_fn           fn (string, string) string                = unsafe { nil }
	static_specs_fn     fn () []ProviderInstanceStaticSpec        = unsafe { nil }
	static_spec_fn      fn (string, string) ?provider.ProviderInstanceSpec = unsafe { nil }
	apply_fn            fn (provider.ProviderInstanceSpec) !               = unsafe { nil }
	provider_enabled_fn fn (string) bool = unsafe { nil }
}

struct ProviderInstanceRuntime {}

fn (ctx ProviderInstanceRuntimeContext) runtime_snapshot(provider_name string, instance string) (upstream.UpstreamSnapshot, bool) {
	return ctx.runtime_snapshot_fn(provider_name, instance)
}

fn (ctx ProviderInstanceRuntimeContext) source(provider_name string, instance string) string {
	return ctx.source_fn(provider_name, instance)
}

fn (ctx ProviderInstanceRuntimeContext) static_specs() []ProviderInstanceStaticSpec {
	return ctx.static_specs_fn()
}

fn (ctx ProviderInstanceRuntimeContext) static_spec(provider_name string, instance string) ?provider.ProviderInstanceSpec {
	return ctx.static_spec_fn(provider_name, instance)
}

fn (ctx ProviderInstanceRuntimeContext) apply(spec provider.ProviderInstanceSpec) ! {
	ctx.apply_fn(spec)!
}

fn (ctx ProviderInstanceRuntimeContext) provider_enabled(provider_name string) bool {
	return ctx.provider_enabled_fn(provider_name)
}

fn (mut app App) build_provider_instance_runtime_context() ProviderInstanceRuntimeContext {
	return ProviderInstanceRuntimeContext{
		runtime_snapshot_fn: fn [mut app] (provider_name string, instance string) (upstream.UpstreamSnapshot, bool) {
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
			for name, cfg in app.providers.feishu.static_apps {
				specs << ProviderInstanceStaticSpec{
					source: 'static'
					spec:   provider.ProviderInstanceSpec{
						provider:      'feishu'
						instance:      name
						config_json:   json.encode(cfg)
						desired_state: 'connected'
					}
				}
			}
			return specs
		}
		static_spec_fn:      fn [mut app] (provider_name string, instance string) ?provider.ProviderInstanceSpec {
			if provider_name == 'feishu' {
				if cfg := app.providers.feishu.apps[instance] {
					return provider.ProviderInstanceSpec{
						provider:      'feishu'
						instance:      instance
						config_json:   json.encode(cfg)
						desired_state: 'connected'
					}
				}
			}
			return none
		}
		apply_fn:            fn [mut app] (spec provider.ProviderInstanceSpec) ! {
			match spec.provider {
				'feishu' {
					if spec.config_json.trim_space() == '' {
						return
					}
					cfg := json.decode(config.FeishuAppConfig, spec.config_json) or {
						return error('provider_instance_invalid_feishu_config:${err}')
					}
					app.providers.feishu.apps[spec.instance] = cfg
					app.providers.feishu.ensure(spec.instance)
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
					app.providers.codex.update(spec.instance, rt)
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

fn (mut app App) provider_instance_runtime_snapshot(provider_name string, instance string) (upstream.UpstreamSnapshot, bool) {
	if snapshot := app.provider_runtime_upstream_snapshot(provider_name, instance) {
		return snapshot, true
	}
	return upstream.UpstreamSnapshot{}, false
}

pub fn (mut app App) provider_instance_upsert(spec provider.ProviderInstanceSpec) provider.ProviderInstanceSpec {
	return app.providers.instances.upsert(spec)
}

pub fn (app &App) provider_instance_get(provider_name string, instance string) ?provider.ProviderInstanceSpec {
	return app.providers.instances.get(provider_name, instance)
}

pub fn (app &App) provider_instance_list(provider_name string) []provider.ProviderInstanceSpec {
	return app.providers.instances.list(provider_name)
}

fn ProviderInstanceRuntime.apply(ctx ProviderInstanceRuntimeContext, spec provider.ProviderInstanceSpec) ! {
	ctx.apply(spec)!
}

pub fn (mut app App) provider_instance_apply(spec provider.ProviderInstanceSpec) ! {
	ctx := app.build_provider_instance_runtime_context()
	ProviderInstanceRuntime.apply(ctx, spec)!
}

fn ProviderInstanceRuntime.ensure(mut registry provider.ProviderInstanceRegistry, ctx ProviderInstanceRuntimeContext, provider_name string, instance string) !provider.ProviderInstanceSpec {
	normalized_instance := provider.ProviderInstanceSpec.normalize_instance_name(instance)
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
		return registry.upsert(provider.ProviderInstanceSpec{
			provider:      'codex'
			instance:      'main'
			config_json:   ''
			desired_state: 'connected'
		})
	}
	return error('provider_instance_not_found:${provider_name}/${normalized_instance}')
}

pub fn (mut app App) provider_instance_ensure(provider_name string, instance string) !provider.ProviderInstanceSpec {
	ctx := app.build_provider_instance_runtime_context()
	return ProviderInstanceRuntime.ensure(mut app.providers.instances, ctx, provider_name, instance)
}
