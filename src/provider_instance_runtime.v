module main

import provider
import json2 as json
import upstream

struct ProviderInstanceStaticSpec {
	spec   provider.ProviderInstanceSpec
	source string
}

struct ProviderInstanceRuntimeContext {
	runtime_snapshot_fn fn (string, string) (upstream.UpstreamSnapshot, bool) @[required]
	source_fn           fn (string, string) string                         @[required]
	static_specs_fn     fn () []ProviderInstanceStaticSpec                 @[required]
	static_spec_fn      fn (string, string) ?provider.ProviderInstanceSpec @[required]
	apply_fn            fn (provider.ProviderInstanceSpec) !               @[required]
	provider_enabled_fn fn (string) bool @[required]
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

fn (mut app App) build_provider_instance_runtime_context_unlocked() ProviderInstanceRuntimeContext {
	return ProviderInstanceRuntimeContext{
		runtime_snapshot_fn: fn [mut app] (provider_name string, instance string) (upstream.UpstreamSnapshot, bool) {
			if snap := app.providers.provider_runtime_upstream_snapshot(provider_name, instance, app.transport.db.enabled) {
				return snap, true
			}
			return upstream.UpstreamSnapshot{}, false
		}
		source_fn:           fn [mut app] (provider_name string, instance string) string {
			return match provider_name {
				'feishu' { app.providers.feishu_runtime_app_source(instance) }
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
						config_json:   json.encode(cfg, escape_unicode: true, time_as_unix: true)
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
						config_json:   json.encode(cfg, escape_unicode: true, time_as_unix: true)
						desired_state: 'connected'
					}
				}
			}
			return none
		}
		apply_fn:            fn [mut app] (spec provider.ProviderInstanceSpec) ! {
			app.provider_instance_apply(spec)!
		}

		provider_enabled_fn: fn [mut app] (provider_name string) bool {
			return app.providers.provider_enabled(provider_name, app.providers.provider_bootstrap_enabled(provider_name, app.transport.db.enabled))
		}
	}
}

fn (mut app App) provider_instance_runtime_snapshot(provider_name string, instance string) (upstream.UpstreamSnapshot, bool) {
	if snapshot := app.provider_runtime_upstream_snapshot(provider_name, instance) {
		return snapshot, true
	}
	return upstream.UpstreamSnapshot{}, false
}

fn (mut hub ProviderRuntimeHub) provider_instance_upsert(spec provider.ProviderInstanceSpec) provider.ProviderInstanceSpec {
	return hub.instances.upsert(spec)
}

fn (hub ProviderRuntimeHub) provider_instance_get(provider_name string, instance string) ?provider.ProviderInstanceSpec {
	return hub.instances.get(provider_name, instance)
}

fn (hub ProviderRuntimeHub) provider_instance_list(provider_name string) []provider.ProviderInstanceSpec {
	return hub.instances.list(provider_name)
}

pub fn (mut app App) provider_instance_upsert(spec provider.ProviderInstanceSpec) provider.ProviderInstanceSpec {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.providers.provider_instance_upsert(spec)
}

pub fn (app &App) provider_instance_get(provider_name string, instance string) ?provider.ProviderInstanceSpec {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.providers.provider_instance_get(provider_name, instance)
}

pub fn (app &App) provider_instance_list(provider_name string) []provider.ProviderInstanceSpec {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.providers.provider_instance_list(provider_name)
}

fn ProviderInstanceRuntime.apply(ctx ProviderInstanceRuntimeContext, spec provider.ProviderInstanceSpec) ! {
	ctx.apply(spec)!
}

pub fn (mut app App) provider_instance_apply(spec provider.ProviderInstanceSpec) ! {
	prepared := prepare_provider_instance(spec)!
	if !app.lifecycle.shutdown.begin_start() { return error('provider_instance_app_stopping') }
	defer { app.lifecycle.shutdown.end_start() }
	app.mu.@lock()
	app.apply_provider_instance_unlocked(prepared)
	app.mu.unlock()
	app.start_provider_instance(prepared)
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
	if !app.lifecycle.shutdown.begin_start() { return error('provider_instance_app_stopping') }
	defer { app.lifecycle.shutdown.end_start() }
	app.mu.@lock()
	spec := app.ensure_provider_instance_unlocked(provider_name, instance) or {
		app.mu.unlock()
		return err
	}
	app.mu.unlock()
	// Resolving a run always uses current configuration after publication.
	_ = app.ensure_websocket_upstream_provider_running(spec.provider, spec.instance)
	return spec
}

fn (mut app App) ensure_provider_instance_unlocked(provider_name string, instance string) !provider.ProviderInstanceSpec {
	name := provider_name.trim_space()
	normalized := provider.ProviderInstanceSpec.normalize_instance_name(instance)
	if spec := app.providers.provider_instance_get(name, normalized) {
		if prepared := prepare_provider_instance(spec) {
			app.apply_provider_instance_unlocked(prepared)
		}
		return spec
	}
	ctx := app.build_provider_instance_runtime_context_unlocked()
	if spec := ctx.static_spec(name, normalized) {
		prepared := prepare_provider_instance(spec)!
		app.apply_provider_instance_unlocked(prepared)
		return app.providers.provider_instance_upsert(spec)
	}
	if name == 'codex' && normalized == 'main' && ctx.provider_enabled(name) {
		return app.providers.provider_instance_upsert(provider.ProviderInstanceSpec{ provider: name, instance: normalized, desired_state: 'connected' })
	}
	return error('provider_instance_not_found:${name}/${normalized}')
}
