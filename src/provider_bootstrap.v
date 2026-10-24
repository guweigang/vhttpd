module main

import provider

// Provider bootstrap is intentionally isolated from transport/runtime startup
// to keep HTTP/WebSocket/stream + workerpool orchestration independent from
// application-level adapters.

fn (mut app App) bootstrap_providers() {
	// Feishu
	$if !no_feishu_routes ? {
		if app.provider_bootstrap_enabled('feishu') {
			mut p := FeishuProvider{}
			h := FeishuCommandHandler.new(mut app)
			mut spec := ProviderSpec{
				name:             'feishu'
				enabled:          true
				has_handler:      true
				has_runtime:      true
				runtime_driver:   app.providers.provider_runtime_driver('feishu')
				command_matchers: [
					provider.CommandMatcher{
						kind:  provider.CommandMatcherKind.prefix
						value: 'feishu.message.'
					},
				]
				route_kind:       provider.ProviderRouteKind.feishu
				provider:         p
				handler:          h
				runtime:          ProviderRuntimeAdapter{
					provider: p
				}
				lifecycle_ctx:    app.build_provider_context('feishu')
			}
			app.register_and_start_provider(mut spec)
		}
	}

	// Codex
	$if !no_codex_routes ? {
		if app.provider_bootstrap_enabled('codex') {
			mut p := CodexProvider{}
			h := CodexCommandHandler.new(mut app)
			mut spec := ProviderSpec{
				name:             'codex'
				enabled:          true
				has_handler:      true
				has_runtime:      true
				runtime_driver:   app.providers.provider_runtime_driver('codex')
				command_matchers: [
					provider.CommandMatcher{
						kind:  provider.CommandMatcherKind.prefix
						value: 'codex.'
					},
				]
				route_kind:       provider.ProviderRouteKind.codex
				provider:         p
				handler:          h
				runtime:          ProviderRuntimeAdapter{
					provider: p
				}
				lifecycle_ctx:    app.build_provider_context('codex')
			}
			app.register_and_start_provider(mut spec)
		}
	}

	// Database upstream (runtime skeleton)
	if app.provider_bootstrap_enabled('db') {
		mut p := DbProvider{}
		mut spec := ProviderSpec{
			name:             'db'
			enabled:          true
			has_handler:      false
			has_runtime:      true
			runtime_driver:   app.providers.provider_runtime_driver('db')
			command_matchers: []provider.CommandMatcher{}
			route_kind:       provider.ProviderRouteKind.generic
			provider:         p
			handler:          provider.NoopProviderCommandHandler{}
			runtime:          ProviderRuntimeAdapter{
				provider: p
			}
			lifecycle_ctx:    app.build_provider_context('db')
		}
		app.register_and_start_provider(mut spec)
	}

	// Ollama (currently skeleton adapter)
	$if !no_ollama_routes ? {
		if app.provider_bootstrap_enabled('ollama') {
			mut p := OllamaProvider{}
			h := GenericUpstreamCommandHandler.new(mut app)
			mut spec := ProviderSpec{
				name:             'ollama'
				enabled:          true
				has_handler:      true
				has_runtime:      true
				runtime_driver:   app.providers.provider_runtime_driver('ollama')
				command_matchers: [
					provider.CommandMatcher{
						kind:  provider.CommandMatcherKind.prefix
						value: 'ollama.message.'
					},
				]
				route_kind:       provider.ProviderRouteKind.ollama
				provider:         p
				handler:          h
				runtime:          ProviderRuntimeAdapter{
					provider: p
				}
				lifecycle_ctx:    app.build_provider_context('ollama')
			}
			app.register_and_start_provider(mut spec)
		}
	}
}

// Register before init so callbacks can find the complete spec. Completion
// publishes only into its captured registration; callbacks run outside App.mu.
fn (mut app App) register_and_start_provider(mut spec ProviderSpec) {
	if !app.lifecycle.shutdown.begin_start() { return }
	defer { app.lifecycle.shutdown.end_start() }
	app.mu.@lock()
	app.providers.register_provider_spec(spec)
	mut registration := app.providers.registry.registrations[spec.name] or { panic('provider_registration_missing') }
	registration.bootstrapping = true
	app.mu.unlock()
	defer { app.finish_provider_start(mut spec, registration) }
	spec.provider.init(mut spec.lifecycle_ctx) or {
		app.emit('provider.init_failed', {
			'name':  spec.name
			'error': err.msg()
		})
		return
	}
	app.mu.@lock()
	admitted := app.publish_provider_start_unlocked(spec, registration)
	app.mu.unlock()
	if !admitted { return }
	// Admission permits this callback to complete on its captured runtime. A
	// later replacement/revocation retains cleanup with this completion owner.
	spec.start_runtime() or {
		app.emit('provider.start_failed', {
			'name':  spec.name
			'error': err.msg()
		})
	}
}

// Caller holds App.mu. Configuration may have refreshed while callbacks ran;
// retain current metadata and publish only this owner's mutable lifecycle state.
fn (mut app App) publish_provider_start_unlocked(spec ProviderSpec, expected &ProviderRegistration) bool {
	current := app.providers.registry.registrations[spec.name] or { return false }
	if voidptr(current) != voidptr(expected) || current.retired { return false }
	published := app.providers.registry.specs[spec.name] or { return false }
	app.providers.registry.publish_spec(ProviderSpec{
		...published
		provider:      spec.provider
		handler:       spec.handler
		runtime:       spec.runtime
		lifecycle_ctx: spec.lifecycle_ctx
	})
	return true
}

fn (mut app App) finish_provider_start(mut spec ProviderSpec, registration &ProviderRegistration) {
	app.mu.@lock()
	mut owned := unsafe { registration }
	owned.bootstrapping = false
	published := app.publish_provider_start_unlocked(spec, registration)
	app.mu.unlock()
	if published { return }
	// Retired callbacks own final cleanup exactly once, after their last mutation.
	// Shutdown joins this completion through the existing startup admission gate.
	spec.stop_retired_runtime() or {
		app.emit('provider.stop_failed', {
			'name':   spec.name
			'error':  err.msg()
			'reason': 'retired_start'
		})
	}
}
