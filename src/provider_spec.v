module main

import provider
import command

// ProviderRuntime represents optional provider-owned runtime lifecycle hooks.
pub interface ProviderRuntime {
mut:
	start(mut ctx provider.RuntimeContext) !
	stop(mut ctx provider.RuntimeContext) !
	snapshot(mut ctx provider.RuntimeContext) string
}

pub struct ProviderHost {
pub mut:
	registry map[string]Provider
	specs    map[string]ProviderSpec
}

// ProviderSpec explicitly models the relationship: provider + handler + runtime.
pub struct ProviderSpec {
pub:
	name             string
	enabled          bool
	has_handler      bool
	has_runtime      bool
	runtime_driver   string = 'native'
	command_matchers []command.CommandMatcher
	route_kind       command.ProviderRouteKind
pub mut:
	provider      Provider
	handler       provider.ProviderCommandHandler
	runtime       ProviderRuntime
	lifecycle_ctx provider.RuntimeContext
}

fn (host ProviderHost) admin_specs_snapshot() []provider.AdminProviderSpecSnapshot {
	names := host.names()
	mut out := []provider.AdminProviderSpecSnapshot{cap: names.len}
	for name in names {
		spec := host.specs[name] or { continue }
		mut matcher_rows := []string{}
		for matcher in spec.command_matchers {
			matcher_rows << '${matcher.kind.str()}:${matcher.value}'
		}
		out << provider.AdminProviderSpecSnapshot{
			name:             spec.name
			enabled:          spec.enabled
			has_handler:      spec.has_handler
			has_runtime:      spec.has_runtime
			runtime_driver:   if spec.runtime_driver.trim_space() == '' {
				'native'
			} else {
				spec.runtime_driver
			}
			command_matchers: matcher_rows
			route_kind:       spec.route_kind.snapshot_value()
		}
	}
	return out
}

fn (host ProviderHost) specs_copy() []ProviderSpec {
	names := host.names()
	mut specs := []ProviderSpec{cap: names.len}
	for name in names {
		spec := host.specs[name] or { continue }
		specs << ProviderSpec{
			name:             spec.name
			enabled:          spec.enabled
			has_handler:      spec.has_handler
			has_runtime:      spec.has_runtime
			runtime_driver:   if spec.runtime_driver.trim_space() == '' {
				'native'
			} else {
				spec.runtime_driver
			}
			command_matchers: spec.command_matchers.clone()
			route_kind:       spec.route_kind
			provider:         spec.provider
			handler:          spec.handler
			runtime:          spec.runtime
			lifecycle_ctx:    spec.lifecycle_ctx
		}
	}
	return specs
}

fn (hub ProviderRuntimeHub) admin_specs_snapshot() []provider.AdminProviderSpecSnapshot {
	return hub.registry.admin_specs_snapshot()
}

fn (hub ProviderRuntimeHub) provider_specs_copy() []ProviderSpec {
	return hub.registry.specs_copy()
}

fn add_provider_runtime_name(mut names []string, mut seen map[string]bool, name string) {
	trimmed := name.trim_space()
	if trimmed == '' || seen[trimmed] {
		return
	}
	seen[trimmed] = true
	names << trimmed
}

fn (hub ProviderRuntimeHub) configured_provider_runtime_names() []string {
	mut names := []string{}
	mut seen := map[string]bool{}
	for name, _ in hub.runtime_drivers {
		add_provider_runtime_name(mut names, mut seen, name)
	}
	for name, _ in hub.runtime_protocols {
		add_provider_runtime_name(mut names, mut seen, name)
	}
	for name, _ in hub.runtime_plugins {
		add_provider_runtime_name(mut names, mut seen, name)
	}
	for name, _ in hub.runtime_capabilities {
		add_provider_runtime_name(mut names, mut seen, name)
	}
	for name, _ in hub.runtime_hooks {
		add_provider_runtime_name(mut names, mut seen, name)
	}
	for name, _ in hub.runtime_options {
		add_provider_runtime_name(mut names, mut seen, name)
	}
	names.sort()
	return names
}

pub fn (mut app App) admin_provider_specs_snapshot() []provider.AdminProviderSpecSnapshot {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.admin_specs_snapshot()
}

pub fn (mut app App) provider_specs_copy() []ProviderSpec {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.provider_specs_copy()
}

pub fn (mut app App) admin_provider_runtimes_snapshot() []provider.AdminProviderRuntimeSnapshot {
	mut specs := app.provider_specs_copy()
	configured_names := app.providers.configured_provider_runtime_names()
	mut snapshots := []provider.AdminProviderRuntimeSnapshot{cap: specs.len + configured_names.len}
	mut seen := map[string]bool{}
	for mut spec in specs {
		mut snapshot := '{}'
		if spec.has_runtime {
			snapshot = spec.runtime.snapshot(mut spec.lifecycle_ctx)
		}
		seen[spec.name] = true
		snapshots << provider.AdminProviderRuntimeSnapshot{
			name:           spec.name
			enabled:        spec.enabled
			runtime_driver: app.providers.provider_runtime_driver(spec.name)
			protocol:       app.providers.provider_runtime_protocol(spec.name)
			plugin:         app.providers.provider_runtime_plugin(spec.name)
			capabilities:   app.providers.runtime_capabilities[spec.name] or {
				map[string]string{}
			}
			hooks:          app.providers.runtime_hooks[spec.name] or {
				map[string]string{}
			}
			snapshot:       snapshot
		}
	}
	for name in configured_names {
		if seen[name] {
			continue
		}
		snapshots << provider.AdminProviderRuntimeSnapshot{
			name:           name
			enabled:        true
			runtime_driver: app.providers.provider_runtime_driver(name)
			protocol:       app.providers.provider_runtime_protocol(name)
			plugin:         app.providers.provider_runtime_plugin(name)
			capabilities:   app.providers.runtime_capabilities[name] or {
				map[string]string{}
			}
			hooks:          app.providers.runtime_hooks[name] or {
				map[string]string{}
			}
			snapshot:       '{}'
		}
	}
	return snapshots
}

pub struct NoopProviderRuntime {}

pub fn (mut r NoopProviderRuntime) start(mut ctx provider.RuntimeContext) ! {
	_ = ctx
	return
}

pub fn (mut r NoopProviderRuntime) stop(mut ctx provider.RuntimeContext) ! {
	_ = ctx
	return
}

pub fn (mut r NoopProviderRuntime) snapshot(mut ctx provider.RuntimeContext) string {
	_ = ctx
	return '{}'
}

// Adapter for existing Provider interface so runtime hooks can remain optional.
pub struct ProviderRuntimeAdapter {
pub mut:
	provider Provider
	ctx      provider.RuntimeContext
}

pub fn (mut r ProviderRuntimeAdapter) start(mut ctx provider.RuntimeContext) ! {
	r.provider.start(mut r.ctx)!
	return
}

pub fn (mut r ProviderRuntimeAdapter) stop(mut ctx provider.RuntimeContext) ! {
	r.provider.stop(mut r.ctx)!
	return
}

pub fn (mut r ProviderRuntimeAdapter) snapshot(mut ctx provider.RuntimeContext) string {
	return r.provider.snapshot(mut r.ctx)
}
