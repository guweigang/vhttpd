module main

pub enum ProviderRouteKind {
	codex
	feishu
	ollama
	generic
}

pub enum CommandMatcherKind {
	prefix
	exact
}

pub struct CommandMatcher {
pub:
	kind  CommandMatcherKind
	value string
}

pub fn (m CommandMatcher) matches(command_type string) bool {
	if m.value.trim_space() == '' {
		return false
	}
	return match m.kind {
		.prefix { command_type.starts_with(m.value) }
		.exact { command_type == m.value }
	}
}

// ProviderCommandHandler bridges provider-specific command execution.
pub interface ProviderCommandHandler {
	execute(command WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string)
}

// ProviderRuntime represents optional provider-owned runtime lifecycle hooks.
pub interface ProviderRuntime {
	start(mut app App) !
	stop(mut app App) !
	snapshot(mut app App) string
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
	command_matchers []CommandMatcher
	route_kind       ProviderRouteKind
pub mut:
	provider Provider
	handler  ProviderCommandHandler
	runtime  ProviderRuntime
}

pub struct AdminProviderSpecSnapshot {
pub:
	name             string
	enabled          bool
	has_handler      bool     @[json: 'has_handler']
	has_runtime      bool     @[json: 'has_runtime']
	command_matchers []string @[json: 'command_matchers']
	route_kind       string   @[json: 'route_kind']
}

pub struct AdminProviderRuntimeSnapshot {
pub:
	name     string
	enabled  bool
	snapshot string
}

pub fn (mut app App) admin_provider_specs_snapshot() []AdminProviderSpecSnapshot {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	mut names := app.providers.specs.keys()
	names.sort()
	mut out := []AdminProviderSpecSnapshot{cap: names.len}
	for name in names {
		spec := app.providers.specs[name] or { continue }
		mut matcher_rows := []string{}
		for matcher in spec.command_matchers {
			matcher_rows << '${matcher.kind.str()}:${matcher.value}'
		}
		out << AdminProviderSpecSnapshot{
			name:             spec.name
			enabled:          spec.enabled
			has_handler:      spec.has_handler
			has_runtime:      spec.has_runtime
			command_matchers: matcher_rows
			route_kind:       spec.route_kind.str()
		}
	}
	return out
}

pub fn (mut app App) provider_specs_copy() []ProviderSpec {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	mut names := app.providers.specs.keys()
	names.sort()
	mut specs := []ProviderSpec{cap: names.len}
	for name in names {
		spec := app.providers.specs[name] or { continue }
		specs << ProviderSpec{
			name:             spec.name
			enabled:          spec.enabled
			has_handler:      spec.has_handler
			has_runtime:      spec.has_runtime
			command_matchers: spec.command_matchers.clone()
			route_kind:       spec.route_kind
			provider:         spec.provider
			handler:          spec.handler
			runtime:          spec.runtime
		}
	}
	return specs
}

pub fn (mut app App) admin_provider_runtimes_snapshot() []AdminProviderRuntimeSnapshot {
	specs := app.provider_specs_copy()
	mut snapshots := []AdminProviderRuntimeSnapshot{cap: specs.len}
	for spec in specs {
		mut snapshot := '{}'
		if spec.has_runtime {
			snapshot = spec.runtime.snapshot(mut app)
		}
		snapshots << AdminProviderRuntimeSnapshot{
			name:     spec.name
			enabled:  spec.enabled
			snapshot: snapshot
		}
	}
	return snapshots
}

// No-op defaults let specs be constructed safely while keeping behavior stable.
pub struct NoopProviderCommandHandler {}

pub fn (h NoopProviderCommandHandler) execute(command WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	_ = command
	_ = normalized
	_ = snapshot
	return false, ''
}

pub struct NoopProviderRuntime {}

pub fn (r NoopProviderRuntime) start(mut app App) ! {
	_ = app
	return
}

pub fn (r NoopProviderRuntime) stop(mut app App) ! {
	_ = app
	return
}

pub fn (r NoopProviderRuntime) snapshot(mut app App) string {
	_ = app
	return '{}'
}

// Adapter for existing Provider interface so runtime hooks can remain optional.
pub struct ProviderRuntimeAdapter {
pub:
	provider Provider
}

pub fn (r ProviderRuntimeAdapter) start(mut app App) ! {
	r.provider.start(mut app)!
	return
}

pub fn (r ProviderRuntimeAdapter) stop(mut app App) ! {
	r.provider.stop(mut app)!
	return
}

pub fn (r ProviderRuntimeAdapter) snapshot(mut app App) string {
	return r.provider.snapshot(mut app)
}
