module main

import json
import provider

fn (mut app App) build_provider_runtime_dispatch_context() provider.RuntimeDispatchContext {
	return provider.RuntimeDispatchContext{
		instances_fn:         fn [mut app] (name string) []string {
			return app.provider_runtime_instances(name)
		}
		upstream_enabled_fn:  fn [mut app] (name string, instance string) bool {
			return app.provider_runtime_upstream_enabled(name, instance)
		}
		bootstrap_enabled_fn: fn [mut app] (name string) bool {
			return app.provider_bootstrap_enabled(name)
		}
		ready_fn:             fn [mut app] (name string) bool {
			return app.provider_runtime_ready(name)
		}
		pull_url_fn:          fn [mut app] (name string, instance string) !string {
			return app.provider_runtime_pull_url(name, instance)
		}
	}
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
				feishu_name { json.encode(app.feishu_runtime_snapshot()) }
				codex_name { json.encode(app.admin_codex_snapshot()) }
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
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.is_upstream_enabled(name, instance)
}

pub fn (mut app App) provider_runtime_upstream_provider_names() []string {
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.upstream_provider_names()
}
