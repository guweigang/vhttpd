module main

import provider

// Minimal provider registry to enable pluggable upstream providers.
// Non-breaking: adapters delegate to existing provider code (eg feishu_runtime.*).

pub interface Provider {
mut:
	init(mut ctx provider.RuntimeContext) !
	start(mut ctx provider.RuntimeContext) !
	stop(mut ctx provider.RuntimeContext) !
	// Return a JSON string snapshot for admin visibility.
	snapshot(mut ctx provider.RuntimeContext) string
}

// Global registry (kept minimal and simple).
// The registry is now owned by App to avoid top-level mutable globals which
// can be problematic across V versions. Helper functions below remain for
// convenience but are thin wrappers around App methods when called with an
// App reference.

// NOTE: App now exposes methods to register and query providers via
// ProviderHost on App, instead of top-level mutable globals.
// The old global helpers (register_provider, get_provider, provider_names)
// have been removed to eliminate unrecoverable panics in production code.

// Provider registry helpers. Registry access is protected by App.mu at callers
// that share the hub across request handlers.
fn (mut host ProviderHost) ensure_maps() {
	if host.registry.len == 0 {
		host.registry = map[string]Provider{}
	}
	if host.specs.len == 0 {
		host.specs = map[string]ProviderSpec{}
	}
}

fn (mut host ProviderHost) register_provider(name string, p Provider, ctx provider.RuntimeContext) {
	host.ensure_maps()
	host.registry[name] = p
	host.specs[name] = ProviderSpec{
		name:             name
		enabled:          true
		has_handler:      false
		has_runtime:      true
		command_matchers: []provider.CommandMatcher{}
		route_kind:       .generic
		provider:         p
		handler:          provider.NoopProviderCommandHandler{}
		runtime:          ProviderRuntimeAdapter{
			provider: p
			ctx:      ctx
		}
		lifecycle_ctx:    ctx
	}
}

fn (mut host ProviderHost) register_spec(spec ProviderSpec) {
	host.ensure_maps()
	host.specs[spec.name] = spec
}

fn (host ProviderHost) spec(name string) ?ProviderSpec {
	return host.specs[name] or { return none }
}

fn (host ProviderHost) provider(name string) ?Provider {
	if spec := host.specs[name] {
		return spec.provider
	}
	return host.registry[name] or { return none }
}

fn (host ProviderHost) enabled(name string, bootstrap_enabled bool) bool {
	if spec := host.specs[name] {
		return spec.enabled
	}
	return bootstrap_enabled
}

fn (host ProviderHost) runtime(name string) ?ProviderRuntime {
	if spec := host.specs[name] {
		return spec.runtime
	}
	return none
}

fn (host ProviderHost) names() []string {
	mut keys := host.specs.keys()
	keys.sort()
	return keys
}

fn (host ProviderHost) runtimes_with_contexts() ([]ProviderRuntime, []provider.RuntimeContext) {
	mut runtimes := []ProviderRuntime{}
	mut contexts := []provider.RuntimeContext{}
	for _, spec in host.specs {
		runtimes << spec.runtime
		contexts << spec.lifecycle_ctx
	}
	return runtimes, contexts
}

fn (mut hub ProviderRuntimeHub) register_provider(name string, p Provider, ctx provider.RuntimeContext) {
	hub.registry.register_provider(name, p, ctx)
}

fn (mut hub ProviderRuntimeHub) register_provider_spec(spec ProviderSpec) {
	hub.registry.register_spec(spec)
}

fn (hub ProviderRuntimeHub) get_provider_spec(name string) ?ProviderSpec {
	return hub.registry.spec(name)
}

fn (hub ProviderRuntimeHub) get_provider(name string) ?Provider {
	return hub.registry.provider(name)
}

fn (hub ProviderRuntimeHub) provider_enabled(name string, bootstrap_enabled bool) bool {
	return hub.registry.enabled(name, bootstrap_enabled)
}

fn (hub ProviderRuntimeHub) get_provider_runtime(name string) ?ProviderRuntime {
	return hub.registry.runtime(name)
}

fn (hub ProviderRuntimeHub) provider_names() []string {
	return hub.registry.names()
}

fn (hub ProviderRuntimeHub) provider_runtimes_with_contexts() ([]ProviderRuntime, []provider.RuntimeContext) {
	return hub.registry.runtimes_with_contexts()
}

pub fn (mut app App) register_provider(name string, p Provider) {
	mut generic_ctx := app.build_provider_context(name)
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.providers.register_provider(name, p, generic_ctx)
}

pub fn (mut app App) register_provider_spec(spec ProviderSpec) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.providers.register_provider_spec(spec)
}

pub fn (mut app App) get_provider_spec(name string) ?ProviderSpec {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.get_provider_spec(name)
}

pub fn (mut app App) get_provider(name string) ?Provider {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.get_provider(name)
}

pub fn (mut app App) provider_enabled(name string) bool {
	bootstrap_enabled := app.provider_bootstrap_enabled(name)
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.provider_enabled(name, bootstrap_enabled)
}

pub fn (mut app App) get_provider_runtime(name string) ?ProviderRuntime {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.get_provider_runtime(name)
}

pub fn (mut app App) provider_names() []string {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.provider_names()
}

// Helpers to run provider lifecycle across registered providers.
pub fn (mut app App) stop_all_providers() {
	app.mu.@lock()
	mut runtimes, mut contexts := app.providers.provider_runtimes_with_contexts()
	app.mu.unlock()
	for i, mut runtime in runtimes {
		runtime.stop(mut contexts[i]) or {
			app.emit('provider.stop_failed', {
				'error': err.msg()
			})
		}
	}
}

// Simple Feishu adapter implementing Provider by delegating to context closures.
pub struct FeishuProvider {}

pub fn (mut p FeishuProvider) init(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p FeishuProvider) start(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p FeishuProvider) stop(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p FeishuProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}

// Codex adapter: thin delegator to context closures.
pub struct CodexProvider {}

pub fn (mut p CodexProvider) init(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p CodexProvider) start(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p CodexProvider) stop(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p CodexProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}

// Ollama adapter skeleton — thin delegator for Ollama upstreams (NDJSON style).
pub struct OllamaProvider {}

pub fn (mut p OllamaProvider) init(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p OllamaProvider) start(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p OllamaProvider) stop(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p OllamaProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}

// Db adapter skeleton — runtime-owned unix socket upstream for database access.
pub struct DbProvider {}

pub fn (mut p DbProvider) init(mut ctx provider.RuntimeContext) ! {
	return
}

pub fn (mut p DbProvider) start(mut ctx provider.RuntimeContext) ! {
	ctx.start()!
	return
}

pub fn (mut p DbProvider) stop(mut ctx provider.RuntimeContext) ! {
	ctx.stop()!
	return
}

pub fn (mut p DbProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}
