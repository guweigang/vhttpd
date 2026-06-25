module main

import json
import provider

fn (hub ProviderRuntimeHub) provider_runtime_upstream_enabled(name string, instance string, db_transport_enabled bool) bool {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	return match name {
		feishu_name {
			hub.provider_runtime_ready(name, db_transport_enabled)
				&& instance in hub.provider_runtime_instances(name, db_transport_enabled)
		}
		codex_name {
			instance in hub.provider_runtime_instances(name, db_transport_enabled)
		}
		ollama_name {
			hub.provider_runtime_ready(name, db_transport_enabled)
				&& instance in hub.provider_runtime_instances(name, db_transport_enabled)
		}
		else {
			false
		}
	}
}

fn (mut hub ProviderRuntimeHub) build_runtime_dispatch_context(db_transport_enabled bool, pull_url_fn fn (string, string) !string) provider.RuntimeDispatchContext {
	return provider.RuntimeDispatchContext{
		instances_fn:         fn [hub, db_transport_enabled] (name string) []string {
			return hub.provider_runtime_instances(name, db_transport_enabled)
		}
		upstream_enabled_fn:  fn [hub, db_transport_enabled] (name string, instance string) bool {
			return hub.provider_runtime_upstream_enabled(name, instance, db_transport_enabled)
		}
		bootstrap_enabled_fn: fn [hub, db_transport_enabled] (name string) bool {
			return hub.provider_bootstrap_enabled(name, db_transport_enabled)
		}
		ready_fn:             fn [hub, db_transport_enabled] (name string) bool {
			return hub.provider_runtime_ready(name, db_transport_enabled)
		}
		pull_url_fn:          pull_url_fn
	}
}

fn (mut app App) build_provider_runtime_dispatch_context() provider.RuntimeDispatchContext {
	pull_url_fn := fn [mut app] (name string, instance string) !string {
		return app.provider_runtime_pull_url(name, instance)
	}
	return app.providers.build_runtime_dispatch_context(app.transport.db.enabled, pull_url_fn)
}

// build_provider_context constructs a provider.RuntimeContext whose closures
// capture App, bridging provider adapters to the main program.
fn (mut app App) build_provider_context(name string) provider.RuntimeContext {
	db_name := provider.ProviderName.db()
	return provider.RuntimeContext{
		snapshot: fn [mut app, name] () string {
			feishu_name := provider.ProviderName.feishu()
			codex_name := provider.ProviderName.codex()
			db_name := provider.ProviderName.db()
			return match name {
				feishu_name { json.encode(app.providers.feishu_runtime_snapshot()) }
				codex_name { json.encode(app.providers.admin_codex_snapshot(app.transport.db.enabled)) }
				db_name { app.db_runtime_snapshot() }
				else { '{}' }
			}
		}
		start:    fn [mut app, name, db_name] () ! {
			if name == db_name {
				if app.transport.db.enabled && app.transport.db.socket.trim_space() != '' {
					go app.db_runtime_server_run(app.transport.db.socket)
				}
			}
			return
		}
		stop:     fn [mut app, name, db_name] () ! {
			if name == db_name {
				app.mu.@lock()
				mut listener := app.transport.db.request_stop()
				app.mu.unlock()
				if !isnil(listener) {
					listener.close() or {}
				}
			}
			return
		}
		emit:     fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
	}
}

pub fn (mut app App) provider_runtime_capabilities() map[string]bool {
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.capabilities()
}

pub fn (mut app App) provider_runtime_gateway_count() int {
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.gateway_count()
}

pub fn (mut app App) provider_runtime_upstream_launches() []provider.ProviderRuntimeUpstreamLaunch {
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.upstream_launches()
}

pub fn (mut app App) provider_runtime_upstream_enabled(name string, instance string) bool {
	return app.providers.provider_runtime_upstream_enabled(name, instance, app.transport.db.enabled)
}

pub fn (mut app App) provider_runtime_upstream_provider_names() []string {
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.upstream_provider_names()
}
