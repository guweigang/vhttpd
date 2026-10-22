module main

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

// A directory view contains values only, never a copied hub or its mutexes.
struct ProviderDispatchDirectory {
	instances map[string][]string
	enabled   map[string]bool
	bootstrap map[string]bool
	ready     map[string]bool
	urls      map[string]string
	errors    map[string]string
}

fn (mut hub ProviderRuntimeHub) dispatch_directory(db_transport_enabled bool) ProviderDispatchDirectory {
	hub.codex.mu.@lock()
	defer { hub.codex.mu.unlock() }
	mut instances := map[string][]string{}
	mut enabled := map[string]bool{}
	mut bootstrap := map[string]bool{}
	mut ready := map[string]bool{}
	for name in ['feishu', 'codex', 'ollama', 'db'] {
		instances[name] = hub.provider_runtime_instances(name, db_transport_enabled).clone()
		bootstrap[name] = hub.provider_bootstrap_enabled(name, db_transport_enabled)
		ready[name] = hub.provider_runtime_ready(name, db_transport_enabled)
		for instance in instances[name] {
			enabled['${name}/${instance}'] = hub.provider_runtime_upstream_enabled(name, instance, db_transport_enabled)
		}
	}
	mut urls := map[string]string{}
	mut errors := map[string]string{}
	for instance in instances['codex'] {
		rt := hub.codex_runtime_instance_unlocked(instance)
		urls[instance] = rt.pull_url() or {
			errors[instance] = err.msg()
			''
		}
	}
	return ProviderDispatchDirectory{ instances: instances, enabled: enabled, bootstrap: bootstrap, ready: ready, urls: urls, errors: errors }
}

fn (directory ProviderDispatchDirectory) context(pull_url_fn fn (string, string) !string) provider.RuntimeDispatchContext {
	return provider.RuntimeDispatchContext{
		instances_fn:         fn [directory] (name string) []string {
			return directory.instances[name].clone()
		}
		upstream_enabled_fn:  fn [directory] (name string, instance string) bool {
			return directory.enabled['${name}/${instance}']
		}
		bootstrap_enabled_fn: fn [directory] (name string) bool { return directory.bootstrap[name] }
		ready_fn:             fn [directory] (name string) bool { return directory.ready[name] }
		pull_url_fn:          pull_url_fn
	}
}

fn (mut hub ProviderRuntimeHub) build_runtime_dispatch_context(db_transport_enabled bool, pull_url_fn fn (string, string) !string) provider.RuntimeDispatchContext {
	return hub.dispatch_directory(db_transport_enabled).context(pull_url_fn)
}

// Caller holds App.mu. Codex launch URLs belong to this directory version.
// Feishu endpoint discovery remains an explicit live network action.
fn (mut app App) build_provider_runtime_dispatch_context_unlocked() provider.RuntimeDispatchContext {
	directory := app.providers.dispatch_directory(app.transport.db.enabled)
	return directory.context(fn [mut app, directory] (name string, instance string) !string {
		if name == 'codex' {
			normalized := if instance.trim_space() in ['', 'default'] {
				'main'
			} else {
				instance.trim_space()
			}
			if message := directory.errors[normalized] { return error(message) }
			return directory.urls[normalized] or { return error('provider_instance_not_found:codex/${normalized}') }
		}
		return app.provider_runtime_pull_url(name, instance)
	})
}

fn (mut app App) build_provider_runtime_dispatch_context() provider.RuntimeDispatchContext {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.build_provider_runtime_dispatch_context_unlocked()
}

// build_provider_context constructs a provider.RuntimeContext whose closures
// capture App, bridging provider adapters to the main program.
fn (mut app App) build_provider_context(name string) provider.RuntimeContext {
	db_name := provider.ProviderName.db()
	return provider.RuntimeContext{
		// These closures borrow App-owned subsystem registries. Retiring an adapter
		// cannot pause resources used by a replacement; App shutdown owns their join.
		retired_stop: fn () ! {}
		snapshot:     fn [mut app, name] () string {
			if name in ['feishu', 'codex', 'db'] {
				return app.provider_runtime_snapshot(name) or { '{}' }
			}
			return '{}'
		}

		start: fn [mut app, name, db_name] () ! {
			if !app.websocket.upstream_runs.resume_prefix('${name}/') {
				return error('provider_network_stopping')
			}
			if name == 'feishu' {
				if !app.providers.feishu.background_runs.resume_prefix('') {
					return error('provider_network_stopping')
				}
				ProviderStartupRuntime.start_feishu_background(mut app)
			}
			if name == db_name {
				if app.transport.db.enabled && app.transport.db.socket.trim_space() != '' {
					if !app.db_runtime_server_start(app.transport.db.socket) {
						return error('db_listener_busy')
					}
				}
			}
			return
		}
		stop:  fn [mut app, name, db_name] () ! {
			mut upstream_runs := app.websocket.upstream_runs.request_pause('${name}/')
			if name == 'feishu' {
				mut bridge_runs := app.providers.feishu.background_runs.request_pause('')
				upstream_runs.wait()
				bridge_runs.wait()
			} else {
				upstream_runs.wait()
			}
			if name == db_name {
				app.mu.@lock()
				generation := app.transport.db.request_stop()
				app.mu.unlock()
				if stopped := generation { app.transport.db.listener_owner.wait_stopped(stopped) }
			}
			return
		}
		emit:  fn [mut app] (kind string, fields map[string]string) {
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
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.providers.provider_runtime_upstream_enabled(name, instance, app.transport.db.enabled)
}

pub fn (mut app App) provider_runtime_upstream_provider_names() []string {
	ctx := app.build_provider_runtime_dispatch_context()
	return ctx.upstream_provider_names()
}
