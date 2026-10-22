module main

import provider
import command

// ProviderLifecycleRuntime represents optional provider-owned runtime lifecycle hooks.
pub interface ProviderLifecycleRuntime {
mut:
	start(mut ctx provider.RuntimeContext) !
	stop(mut ctx provider.RuntimeContext) !
	snapshot(mut ctx provider.RuntimeContext) string
}

// App.mu guards registration identity and callback completion ownership.
@[heap]
struct ProviderRegistration {
mut:
	bootstrapping bool
	retired       bool
}

pub struct ProviderHost {
mut:
	registrations map[string]&ProviderRegistration
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
	runtime       ProviderLifecycleRuntime
	lifecycle_ctx provider.RuntimeContext @[required]
}

// ProviderSpec owns the lifecycle context; adapters only forward it.
fn (mut spec ProviderSpec) start_runtime() ! {
	spec.runtime.start(mut spec.lifecycle_ctx)!
}

fn (mut spec ProviderSpec) stop_runtime() ! {
	spec.runtime.stop(mut spec.lifecycle_ctx)!
}

// Retire the captured provider without borrowing a broader global stop right.
fn (mut spec ProviderSpec) stop_retired_runtime() ! {
	if stop := spec.lifecycle_ctx.retired_stop {
		mut ctx := provider.RuntimeContext{ ...spec.lifecycle_ctx, stop: stop }
		spec.runtime.stop(mut ctx)!
		return
	}
	spec.stop_runtime()!
}

fn (mut spec ProviderSpec) runtime_snapshot() string {
	return spec.runtime.snapshot(mut spec.lifecycle_ctx)
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

// Capture configuration and selected callback owners together, then call outside
// the publication lock. Custom snapshot hooks may re-enter runtime publication.
struct ProviderAdminProjection {
	row  provider.AdminProviderRuntimeSnapshot
	spec ?ProviderSpec
}

fn (hub ProviderRuntimeHub) provider_admin_projections() []ProviderAdminProjection {
	specs := hub.provider_specs_copy()
	names := hub.configured_provider_runtime_names()
	mut projections := []ProviderAdminProjection{cap: specs.len + names.len}
	mut seen := map[string]bool{}
	for spec in specs {
		seen[spec.name] = true
		projections << ProviderAdminProjection{ row: hub.provider_admin_row(spec.name, spec.enabled), spec: spec }
	}
	for name in names {
		if seen[name] { continue }
		projections << ProviderAdminProjection{ row: hub.provider_admin_row(name, true) }
	}
	return projections
}

fn (hub ProviderRuntimeHub) provider_admin_row(name string, enabled bool) provider.AdminProviderRuntimeSnapshot {
	return provider.AdminProviderRuntimeSnapshot{
		name:           name
		enabled:        enabled
		runtime_driver: hub.provider_runtime_driver(name)
		protocol:       hub.provider_runtime_protocol(name)
		plugin:         hub.provider_runtime_plugin(name)
		capabilities:   (hub.runtime_capabilities[name] or { map[string]string{} }).clone()
		hooks:          (hub.runtime_hooks[name] or { map[string]string{} }).clone()
		snapshot:       '{}'
	}
}

pub fn (mut app App) admin_provider_runtimes_snapshot() []provider.AdminProviderRuntimeSnapshot {
	app.mu.@lock()
	projections := app.providers.provider_admin_projections()
	app.mu.unlock()
	mut rows := []provider.AdminProviderRuntimeSnapshot{cap: projections.len}
	for projection in projections {
		mut payload := '{}'
		if mut spec := projection.spec {
			if spec.has_runtime { payload = spec.runtime_snapshot() }
		}
		rows << provider.AdminProviderRuntimeSnapshot{ ...projection.row, snapshot: payload }
	}
	return rows
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
	provider Provider @[required]
}

pub fn (mut r ProviderRuntimeAdapter) start(mut ctx provider.RuntimeContext) ! {
	r.provider.start(mut ctx)!
	return
}

pub fn (mut r ProviderRuntimeAdapter) stop(mut ctx provider.RuntimeContext) ! {
	r.provider.stop(mut ctx)!
	return
}

pub fn (mut r ProviderRuntimeAdapter) snapshot(mut ctx provider.RuntimeContext) string {
	return r.provider.snapshot(mut ctx)
}
